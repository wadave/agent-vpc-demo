# Network & Security Architecture: agent-vpc-demo

This document provides implementation-level detail for the network and security controls described in the [Software Design Document](sdd.md). Each section includes Terraform code, `gcloud` commands, or configuration snippets ready for integration into `deployment/terraform/`.

---

## Table of Contents

0. [How Serverless Networking Works on GCP](#0-how-serverless-networking-works-on-gcp)
1. [VPC Design](#1-vpc-design)
2. [Network Segmentation](#2-network-segmentation)
3. [Private Endpoints (Private Google Access & Private Service Connect)](#3-private-endpoints)
4. [Zero-Trust Architecture](#4-zero-trust-architecture)
5. [VPC Service Controls (Service Perimeters)](#5-vpc-service-controls-service-perimeters)
6. [Firewall Policies](#6-firewall-policies)
7. [Additional Security Controls](#7-additional-security-controls)

---

## 0. How Serverless Networking Works on GCP

Before diving into implementation, it's important to understand how Cloud Run relates to VPC subnets. This is a common point of confusion.

### 0.1 The Default: Google-Managed Networking

When you deploy a Cloud Run service **without** VPC configuration (which is what the starter-pack does out of the box), your container runs on Google's shared, managed infrastructure:

```
Internet --> Google Front End --> Cloud Run (Google-managed network) --> Google APIs
                                      |
                                 No VPC involved.
                                 No subnet, no firewall rules,
                                 no Private Google Access.
                                 Google handles everything.
```

In this default mode:
- Cloud Run has **no access** to your VPC. It can only see the public internet and Google APIs.
- Outbound traffic to Google APIs (Vertex AI, GCS, etc.) travels over Google's internal backbone automatically.
- There are no subnets, no firewall rules, and no NAT to configure.

**This is the current state of the starter-pack code.** It works because Cloud Run abstracts the networking away.

### 0.2 The Bridge: Connecting Cloud Run to Your VPC

To enforce enterprise security controls (firewall rules, Private Google Access, VPC Service Controls), you must build a **bridge** from Cloud Run into your VPC. There are two mechanisms:

| Mechanism | How It Works | Cloud Run Gets Subnet IP? | Firewall Rules Apply? |
|-----------|-------------|---------------------------|----------------------|
| **Serverless VPC Access Connector** (Legacy) | Creates a pool of small VMs (`e2-micro`) that proxy traffic between Cloud Run and your VPC | No (connector VMs have subnet IPs) | To connector VMs only |
| **Direct VPC Egress** (Modern, recommended) | Each Cloud Run instance gets an internal IP directly from your subnet | **Yes** -- each instance gets a `10.x.x.x` IP | **Yes** -- instance is subject to all subnet firewall rules |

### 0.3 Direct VPC Egress: Cloud Run Becomes a VPC Citizen

With Direct VPC Egress, Cloud Run instances behave like VMs for all outbound traffic:

```
Cloud Run instance (container)
  |
  +-- Gets IP 10.0.2.5 from backend-subnet
  |
  +-- Subject to firewall rules on backend-subnet
  |
  +-- If subnet has Private Google Access --> uses it
  |
  +-- If subnet has Cloud NAT --> uses it
  |
  +-- If subnet has no internet route --> no internet access
```

**Analogy:** Think of Cloud Run like a remote worker. By default they work from home (Google's network). Direct VPC Egress gives them a **VPN into your office** -- they get an office IP address and must follow all the office's security rules (firewall, no-internet, private API access).

### 0.4 What's Real vs. What's Managed

| Component | Managed by Google? | Visible in Your VPC? |
|-----------|-------------------|---------------------|
| Compute (container runtime) | Yes | No |
| IP addresses | Yes, but assigned from **your** subnet | **Yes** -- you see them in your subnet range |
| Firewall rules | No -- **you manage** | **Yes** -- applied to subnet traffic |
| Internet access | No -- **you manage** | **Yes** -- via Cloud NAT on subnet, or blocked |
| Google API access | No -- **you manage** | **Yes** -- via Private Google Access on subnet |
| Ingress (who can call the service) | Cloud Run controls via `ingress` setting + IAM | N/A (ingress is at Google's edge, not in your VPC) |

**This document describes the target architecture using Direct VPC Egress** -- where Cloud Run instances are real VPC citizens with subnet IPs, subject to your firewall rules and Private Google Access configuration.

---

## 1. VPC Design

The system uses a single VPC with two subnets. Cloud Run services use **Direct VPC Egress** to place their instances directly into these subnets.

### 1.1 Network Topology

```
+--------------------------------------------------------------------------+
|                           agent-adk-vpc                                  |
|                                                                          |
|  +-------------------------------+  +----------------------------------+ |
|  |  frontend-subnet              |  |  backend-subnet                  | |
|  |  10.0.1.0/24                  |  |  10.0.2.0/24                     | |
|  |  us-central1                  |  |  us-central1                     | |
|  |                               |  |                                  | |
|  |  Frontend Cloud Run           |  |  Backend Cloud Run               | |
|  |  instances get IPs from       |  |  instances get IPs from          | |
|  |  this range (Direct VPC       |  |  this range (Direct VPC          | |
|  |  Egress)                      |  |  Egress)                         | |
|  |                               |  |                                  | |
|  |  - External HTTPS LB ingress  |  |  - INTERNAL_ONLY ingress         | |
|  |  - Cloud Armor WAF            |  |  - Private Google Access         | |
|  |  - Egress: PRIVATE_RANGES     |  |  - Egress: ALL_TRAFFIC via VPC   | |
|  |    (only to backend subnet)   |  |  - HTTPS internet via Cloud NAT  | |
|  +-------------------------------+  +----------------------------------+ |
|                                                                          |
|  +--------------------------------------------------------------------+  |
|  |  Cloud Router + Cloud NAT (backend subnet only)                   |  |
|  |  - AUTO_ONLY IP allocation                                        |  |
|  |  - Enables HTTPS egress to external APIs                          |  |
|  +--------------------------------------------------------------------+  |
|                                                                          |
|  +--------------------------------------------------------------------+  |
|  |  Private Google Access (enabled on both subnets)                   |  |
|  |  DNS: *.googleapis.com --> private.googleapis.com (199.36.153.8/30)|  |
|  |                                                                    |  |
|  |  - aiplatform.googleapis.com     - logging.googleapis.com          |  |
|  |  - storage.googleapis.com        - bigquery.googleapis.com         |  |
|  |  - cloudtrace.googleapis.com     - run.googleapis.com              |  |
|  +--------------------------------------------------------------------+  |
+--------------------------------------------------------------------------+
```

### 1.2 Terraform: VPC and Subnets

```hcl
# ============================================================
# network.tf - VPC and subnets (Direct VPC Egress, no connector)
# ============================================================

resource "google_compute_network" "vpc" {
  for_each = local.deploy_project_ids

  name                    = "agent-adk-vpc"
  project                 = each.value
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.deploy_project_services]
}

# --- Frontend subnet ---
# Cloud Run frontend instances get IPs from this range via Direct VPC Egress.
# Used for outbound calls to the private backend.
resource "google_compute_subnetwork" "frontend" {
  for_each = local.deploy_project_ids

  name                     = "frontend-subnet"
  project                  = each.value
  region                   = var.region
  network                  = google_compute_network.vpc[each.key].id
  ip_cidr_range            = "10.0.1.0/24"
  private_ip_google_access = true
}

# --- Backend subnet ---
# Cloud Run backend instances get IPs from this range via Direct VPC Egress.
# Private Google Access enabled -- all Google API calls stay internal.
# No internet route -- egress to 0.0.0.0/0 is denied by firewall.
resource "google_compute_subnetwork" "backend" {
  for_each = local.deploy_project_ids

  name                     = "backend-subnet"
  project                  = each.value
  region                   = var.region
  network                  = google_compute_network.vpc[each.key].id
  ip_cidr_range            = "10.0.2.0/24"
  private_ip_google_access = true
}
```

### 1.4 Cloud Router and Cloud NAT

A Cloud Router and Cloud NAT are provisioned on the backend subnet to give backend Cloud Run instances controlled outbound internet access (HTTPS only). The frontend subnet is not NATed.

```hcl
# Cloud Router (required for Cloud NAT)
resource "google_compute_router" "router" {
  for_each = local.deploy_project_ids

  name    = "agent-adk-router"
  project = each.value
  region  = var.region
  network = google_compute_network.vpc[each.key].id
}

# Cloud NAT — gives the backend subnet controlled outbound internet access
resource "google_compute_router_nat" "nat" {
  for_each = local.deploy_project_ids

  name                               = "agent-adk-nat"
  project                            = each.value
  region                             = var.region
  router                             = google_compute_router.router[each.key].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.backend[each.key].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

**How it works with Direct VPC Egress:**

```
Backend Cloud Run instance (IP: 10.0.2.5 in backend-subnet)
  |
  +--> Calls https://api.external-service.com
  |
  +--> Firewall rule "allow-backend-https-egress" allows TCP/443 to 0.0.0.0/0 (priority 1500)
  |
  +--> Cloud NAT translates 10.0.2.5 --> auto-allocated public IP
  |
  +--> Request reaches external API via Google's network edge
```

> **No VPC Access Connector needed.** Direct VPC Egress replaces the legacy `google_vpc_access_connector` resource. Each Cloud Run instance gets a real IP from the subnet, eliminating the proxy VMs and their associated cost, latency, and throughput limits.

### 1.3 DNS Configuration for Private Access

```hcl
# Private DNS zone for googleapis.com to route API traffic internally.
# Without this, Cloud Run instances using Direct VPC Egress would resolve
# googleapis.com to public IPs and hit the firewall's deny-internet-egress rule.
resource "google_dns_managed_zone" "googleapis" {
  for_each = local.deploy_project_ids

  name        = "googleapis-private"
  project     = each.value
  dns_name    = "googleapis.com."
  description = "Private DNS zone for Google APIs"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc[each.key].id
    }
  }
}

resource "google_dns_record_set" "googleapis_cname" {
  for_each = local.deploy_project_ids

  name         = "*.googleapis.com."
  project      = each.value
  managed_zone = google_dns_managed_zone.googleapis[each.key].name
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["private.googleapis.com."]
}

resource "google_dns_record_set" "private_googleapis_a" {
  for_each = local.deploy_project_ids

  name         = "private.googleapis.com."
  project      = each.value
  managed_zone = google_dns_managed_zone.googleapis[each.key].name
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}
```

---

## 2. Network Segmentation

### 2.1 Cloud Run with Direct VPC Egress

With Direct VPC Egress, each Cloud Run instance gets an internal IP from the specified subnet. This makes them first-class VPC citizens subject to all subnet-level controls.

**Frontend** -- public ingress, VPC egress only for private backend calls:

```hcl
resource "google_cloud_run_v2_service" "frontend" {
  for_each = local.deploy_project_ids

  name                = "${var.project_name}-frontend"
  location            = var.region
  project             = each.value
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"  # Only via LB

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"  # Placeholder
      resources {
        limits = { cpu = "1", memory = "512Mi" }
      }
      env {
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.backend[each.key].uri
      }
    }
    service_account = google_service_account.frontend_sa[each.key].email

    # Direct VPC Egress: instances get IPs from frontend-subnet.
    # PRIVATE_RANGES_ONLY: only traffic to RFC 1918 ranges (i.e., the backend)
    # goes through the VPC. All other egress uses Google's managed network.
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc[each.key].id
        subnetwork = google_compute_subnetwork.frontend[each.key].id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }
  }

  depends_on = [google_project_service.deploy_project_services]
}
```

**Backend** -- internal-only ingress, all egress through VPC:

```hcl
resource "google_cloud_run_v2_service" "backend" {
  for_each = local.deploy_project_ids

  name                = "${var.project_name}-backend"
  location            = var.region
  project             = each.value
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"  # Private: no internet access

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"  # Replaced by CI/CD
      resources {
        limits = { cpu = "4", memory = "8Gi" }
        cpu_idle = false
      }
      env {
        name  = "LOGS_BUCKET_NAME"
        value = google_storage_bucket.logs_data_bucket[each.value].name
      }
      env {
        name  = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"
        value = "NO_CONTENT"
      }
    }

    service_account                  = google_service_account.app_sa[each.key].email
    max_instance_request_concurrency = 40

    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    # Direct VPC Egress: instances get IPs from backend-subnet.
    # ALL_TRAFFIC: every outbound connection goes through the VPC.
    # Combined with firewall rules and Cloud NAT, this means:
    #   - Google APIs: allowed via Private Google Access (199.36.153.8/30)
    #   - External HTTPS APIs: allowed via Cloud NAT (port 443 only)
    #   - All other internet: blocked by deny-internet-egress firewall rule
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc[each.key].id
        subnetwork = google_compute_subnetwork.backend[each.key].id
      }
      egress = "ALL_TRAFFIC"
    }

    session_affinity = true
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [google_project_service.deploy_project_services]
}
```

### 2.2 How Direct VPC Egress Changes the Network Model

```
BEFORE (Default / VPC Connector):              AFTER (Direct VPC Egress):

Cloud Run container                            Cloud Run container
  |                                              |
  +-- Runs on Google's managed network           +-- Gets IP 10.0.2.5 from backend-subnet
  |                                              |
  +-- (optional) Proxy through connector         +-- IS a VPC citizen
  |   VMs at 10.0.3.x                           |
  |                                              +-- Firewall rules apply directly
  +-- Firewall rules apply to                   |
      connector VMs, not container               +-- Private Google Access works natively
                                                 |
                                                 +-- Cloud NAT applies (if configured)
                                                 |
                                                 +-- No internet route = truly private
```

### 2.3 Segmentation Summary

| Property | Frontend | Backend |
|----------|----------|---------|
| Cloud Run ingress | `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` | `INGRESS_TRAFFIC_INTERNAL_ONLY` |
| Direct VPC Egress subnet | `frontend-subnet` (10.0.1.0/24) | `backend-subnet` (10.0.2.0/24) |
| VPC egress mode | `PRIVATE_RANGES_ONLY` (only backend calls via VPC) | `ALL_TRAFFIC` (everything through VPC) |
| Instance gets subnet IP | Yes | Yes |
| Firewall rules apply | Yes | Yes |
| Internet reachable (inbound) | Yes (via LB) | No |
| Internet reachable (outbound) | No (`PRIVATE_RANGES_ONLY` -- trapped in VPC) | HTTPS only (port 443, via Cloud NAT) |
| Google API access | Google-managed (not through VPC) | Private Google Access (through VPC) |
| Service account | `{name}-frontend` | `{name}-app` |
| Authenticates callers | No (`allUsers` via LB only) | Yes (`--no-allow-unauthenticated`) |

### 2.4 Why Two Different Egress Modes?

- **Frontend (`PRIVATE_RANGES_ONLY`):** The frontend only needs VPC routing to reach the private backend. All other outbound traffic (e.g., loading external JS libraries, health checks) can use Google's default managed networking. This avoids the need to set up Cloud NAT for the frontend.

- **Backend (`ALL_TRAFFIC`):** The backend must route *all* egress through the VPC so that firewall rules and Private Google Access are enforced. This ensures API calls to Vertex AI go through Private Google Access and that no data can leak to the internet.

---

## 3. Private Endpoints

### 3.1 Private Google Access

Private Google Access is enabled on both subnets (see `private_ip_google_access = true` in section 1.2). When the backend's Direct VPC Egress routes `ALL_TRAFFIC` through the VPC, API calls to `*.googleapis.com` resolve to `199.36.153.8/30` (via the private DNS zone in section 1.3) and travel over Google's internal network.

**How it works with Direct VPC Egress:**

```
Backend Cloud Run instance (IP: 10.0.2.5 in backend-subnet)
  |
  +--> Calls aiplatform.googleapis.com
  |
  +--> DNS resolves to 199.36.153.8 (private.googleapis.com)
  |       (via private DNS zone on agent-adk-vpc)
  |
  +--> Firewall rule "allow-backend-to-google-apis" allows TCP/443 to 199.36.153.8/30
  |
  +--> Traffic stays on Google's internal backbone (never touches the internet)
  |
  +--> Firewall rule "deny-internet-egress" blocks everything else to 0.0.0.0/0
```

**APIs accessed via Private Google Access:**

| API | Used By | Purpose |
|-----|---------|---------|
| `aiplatform.googleapis.com` | Backend | Gemini model inference via Vertex AI |
| `storage.googleapis.com` | Backend | GCS artifact/telemetry uploads |
| `logging.googleapis.com` | Backend | Cloud Logging structured logs |
| `cloudtrace.googleapis.com` | Backend | Distributed tracing |
| `bigquery.googleapis.com` | Backend | Telemetry external tables |
| `run.googleapis.com` | Frontend | Service-to-service invocation (via VPC to internal backend URL) |

### 3.2 Private Service Connect (Optional, Enhanced Isolation)

For environments requiring dedicated private endpoints with their own internal IP addresses:

```hcl
# Private Service Connect endpoint for Vertex AI
resource "google_compute_global_address" "psc_vertex_ai" {
  for_each = local.deploy_project_ids

  name         = "psc-vertex-ai"
  project      = each.value
  address_type = "INTERNAL"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  network      = google_compute_network.vpc[each.key].id
  address      = "10.0.4.1"
}

resource "google_compute_global_forwarding_rule" "psc_vertex_ai" {
  for_each = local.deploy_project_ids

  name                  = "psc-vertex-ai"
  project               = each.value
  network               = google_compute_network.vpc[each.key].id
  ip_address            = google_compute_global_address.psc_vertex_ai[each.key].id
  target                = "all-apis"
  load_balancing_scheme = ""
}
```

### 3.3 Verification

```bash
# From a test VM in backend-subnet, verify DNS resolution
nslookup aiplatform.googleapis.com
# Should resolve to private.googleapis.com IPs (199.36.153.8/9/10/11)

# Verify Cloud Run instances are getting subnet IPs
gcloud run services describe agent-starter-adk-cr-backend \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID \
  --format="yaml(spec.template.spec.containers,spec.template.metadata.annotations)"

# Check VPC flow logs to confirm backend traffic routes through the subnet
gcloud logging read \
  'resource.type="gce_subnetwork" AND
   resource.labels.subnetwork_name="backend-subnet"' \
  --project=YOUR_PROJECT_ID \
  --limit=10 \
  --format=json
```

---

## 4. Zero-Trust Architecture

The system implements zero-trust at three layers: identity, network, and data.

### 4.1 Service Identity and Authentication

Every component runs under a dedicated service account with narrowly scoped permissions. No component uses the default compute service account.

**Service accounts (existing in `service_accounts.tf`):**

| Service Account | ID | Scope |
|----------------|----|-------|
| Backend app SA | `{name}-app` | Runs the ADK agent; accesses Vertex AI, GCS, Logging |
| CI/CD runner SA | `{name}-cb` | Builds, deploys, runs tests; cannot access runtime data |
| Frontend SA | `{name}-frontend` | Serves UI; can only invoke the backend Cloud Run service |

**Frontend service account (add to `service_accounts.tf`):**

```hcl
resource "google_service_account" "frontend_sa" {
  for_each = local.deploy_project_ids

  account_id   = "${var.project_name}-frontend"
  display_name = "${var.project_name} Frontend Service Account"
  project      = each.value
  depends_on   = [google_project_service.deploy_project_services]
}
```

### 4.2 Service-to-Service Authentication (Frontend -> Backend)

The backend Cloud Run service requires authentication. The frontend must present a valid Google-signed OIDC identity token.

**IAM binding -- grant the frontend SA permission to invoke the backend:**

```hcl
resource "google_cloud_run_v2_service_iam_member" "frontend_invokes_backend" {
  for_each = local.deploy_project_ids

  project  = each.value
  location = var.region
  name     = google_cloud_run_v2_service.backend[each.key].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.frontend_sa[each.key].email}"
}
```

**Frontend code -- acquiring and sending the identity token (Python):**

```python
import google.auth.transport.requests
import google.oauth2.id_token
import requests


def call_backend(backend_url: str, payload: dict) -> requests.Response:
    """Invoke the private backend with an auto-refreshed identity token."""
    auth_req = google.auth.transport.requests.Request()
    id_token = google.oauth2.id_token.fetch_id_token(auth_req, backend_url)

    headers = {
        "Authorization": f"Bearer {id_token}",
        "Content-Type": "application/json",
    }
    return requests.post(
        f"{backend_url}/run_sse",
        json=payload,
        headers=headers,
        stream=True,
    )
```

### 4.3 Least-Privilege IAM Roles

**Application SA roles (existing in `variables.tf`):**

```hcl
variable "app_sa_roles" {
  default = [
    "roles/aiplatform.user",              # Invoke Gemini models
    "roles/logging.logWriter",            # Write structured logs
    "roles/cloudtrace.agent",             # Export traces
    "roles/storage.admin",                # Read/write GCS telemetry bucket
    "roles/serviceusage.serviceUsageConsumer",  # Consume enabled APIs
  ]
}
```

**Frontend SA roles (minimal):**

```hcl
variable "frontend_sa_roles" {
  description = "Roles for the frontend service account"
  type        = list(string)
  default = [
    "roles/logging.logWriter",            # Write access logs
    "roles/cloudtrace.agent",             # Export frontend traces
  ]
  # roles/run.invoker is granted directly on the backend service, not at project level
}
```

**CI/CD SA roles (existing in `variables.tf`):**

```hcl
variable "cicd_roles" {
  default = [
    "roles/run.invoker",                  # Invoke Cloud Run for testing
    "roles/storage.admin",                # Push build artifacts
    "roles/aiplatform.user",              # Run evals
    "roles/logging.logWriter",            # Build logs
    "roles/cloudtrace.agent",             # Build traces
    "roles/artifactregistry.writer",      # Push container images
    "roles/cloudbuild.builds.builder",    # Execute builds
  ]
}

variable "cicd_sa_deployment_required_roles" {
  default = [
    "roles/run.developer",                # Deploy to Cloud Run
    "roles/iam.serviceAccountUser",       # Attach SAs to services
    "roles/aiplatform.user",              # Run post-deploy evals
    "roles/storage.admin",               # Write load test results
  ]
}
```

### 4.4 No Implicit Trust Checklist

| Principle | Implementation |
|-----------|---------------|
| No default SA | All Cloud Run services use dedicated SAs |
| No `allUsers` on backend | Backend uses `--no-allow-unauthenticated`; frontend allows `allUsers` but only via LB (`INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`) |
| No project-level `run.invoker` | Invoker role granted per-service, not project-wide |
| No primitive roles | No `roles/owner`, `roles/editor`, or `roles/viewer` used |
| Token-based auth | Frontend acquires OIDC token per-request to call backend |
| SA key-free | All auth uses workload identity / attached SA, no exported keys |

---

## 5. VPC Service Controls (Service Perimeters)

VPC Service Controls create a security boundary around GCP resources to prevent data exfiltration, even by authorized principals.

### 5.1 Access Policy and Perimeter (Terraform)

```hcl
# ============================================================
# vpc_sc.tf - VPC Service Controls perimeter
# ============================================================

# Access policy (typically one per organization)
# If your org already has one, reference it with a data source instead
resource "google_access_context_manager_access_policy" "policy" {
  parent = "organizations/${var.org_id}"
  title  = "agent-starter-adk-cr-policy"
}

# Access level: allow CI/CD service account for deployments
resource "google_access_context_manager_access_level" "cicd_access" {
  parent = "accessPolicies/${google_access_context_manager_access_policy.policy.name}"
  name   = "accessPolicies/${google_access_context_manager_access_policy.policy.name}/accessLevels/cicd_deployer"
  title  = "CI/CD Deployer Access"

  basic {
    conditions {
      members = [
        "serviceAccount:${google_service_account.cicd_runner_sa.email}",
      ]
    }
  }
}

# Service perimeter protecting staging and production projects
resource "google_access_context_manager_service_perimeter" "perimeter" {
  parent = "accessPolicies/${google_access_context_manager_access_policy.policy.name}"
  name   = "accessPolicies/${google_access_context_manager_access_policy.policy.name}/servicePerimeters/agent_adk_perimeter"
  title  = "agent-starter-adk-cr Perimeter"

  status {
    resources = [
      "projects/${data.google_project.projects["prod"].number}",
      "projects/${data.google_project.projects["staging"].number}",
    ]

    restricted_services = [
      "aiplatform.googleapis.com",
      "storage.googleapis.com",
      "bigquery.googleapis.com",
      "logging.googleapis.com",
      "run.googleapis.com",
      "artifactregistry.googleapis.com",
    ]

    access_levels = [
      google_access_context_manager_access_level.cicd_access.name,
    ]

    # Ingress: allow Cloud Build from CI/CD project to deploy
    ingress_policies {
      ingress_from {
        sources {
          resource = "projects/${var.cicd_runner_project_id}"
        }
        identity_type = "ANY_SERVICE_ACCOUNT"
      }
      ingress_to {
        resources = ["*"]
        operations {
          service_name = "run.googleapis.com"
          method_selectors { method = "*" }
        }
        operations {
          service_name = "artifactregistry.googleapis.com"
          method_selectors { method = "*" }
        }
      }
    }

    # Ingress: allow frontend to invoke backend within the perimeter
    ingress_policies {
      ingress_from {
        identity_type = "ANY_SERVICE_ACCOUNT"
        sources {
          resource = "projects/${data.google_project.projects["prod"].number}"
        }
      }
      ingress_to {
        resources = ["*"]
        operations {
          service_name = "run.googleapis.com"
          method_selectors { method = "*" }
        }
      }
    }

    # Egress: deny all by default (no data leaves the perimeter)
  }
}
```

### 5.2 Perimeter Variables

```hcl
variable "org_id" {
  type        = string
  description = "Google Cloud organization ID for VPC Service Controls"
}

variable "enable_vpc_sc" {
  type        = bool
  description = "Whether to create VPC Service Controls perimeter"
  default     = false
}
```

### 5.3 Dry-Run Mode

Before enforcing a perimeter, test it in dry-run mode to identify violations without blocking traffic:

```bash
# Create perimeter in dry-run mode
gcloud access-context-manager perimeters dry-run create agent_adk_perimeter \
  --title="agent-starter-adk-cr Perimeter" \
  --resources="projects/PROD_PROJECT_NUMBER,projects/STAGING_PROJECT_NUMBER" \
  --restricted-services="aiplatform.googleapis.com,storage.googleapis.com,bigquery.googleapis.com,logging.googleapis.com" \
  --policy=POLICY_ID

# Check for violations
gcloud access-context-manager perimeters dry-run list \
  --policy=POLICY_ID

# Promote to enforced after validating no false positives
gcloud access-context-manager perimeters dry-run enforce agent_adk_perimeter \
  --policy=POLICY_ID
```

---

## 6. Firewall Policies

With Direct VPC Egress, firewall rules apply **directly to Cloud Run instances** because each instance has a real IP from the subnet. This is the key difference from the VPC Connector approach.

### 6.1 VPC Firewall Rules (Terraform)

```hcl
# ============================================================
# firewall.tf - VPC firewall rules
# ============================================================
# With Direct VPC Egress, Cloud Run instances have IPs from the subnet.
# Firewall rules target these IPs via subnet CIDR ranges.
# (Network tags don't apply to Cloud Run -- use source/destination ranges.)

# --- Rule 1: Allow HTTPS ingress to frontend subnet ---
# (For the Load Balancer health checks and external traffic)
resource "google_compute_firewall" "allow_https_to_frontend" {
  for_each = local.deploy_project_ids

  name    = "allow-https-to-frontend"
  project = each.value
  network = google_compute_network.vpc[each.key].id

  priority  = 1000
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]

  # Target: frontend subnet instances
  destination_ranges = ["10.0.1.0/24"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# --- Rule 2: Allow frontend subnet to reach backend subnet ---
# Frontend Cloud Run instances (10.0.1.x) call backend (10.0.2.x) over HTTPS.
resource "google_compute_firewall" "allow_frontend_to_backend" {
  for_each = local.deploy_project_ids

  name    = "allow-frontend-to-backend"
  project = each.value
  network = google_compute_network.vpc[each.key].id

  priority  = 1100
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443", "8080"]
  }

  # Source: frontend subnet (Cloud Run instances with Direct VPC Egress)
  source_ranges = ["10.0.1.0/24"]

  # Destination: backend subnet
  destination_ranges = ["10.0.2.0/24"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# --- Rule 3: Deny all other ingress to backend subnet ---
resource "google_compute_firewall" "deny_all_ingress_to_backend" {
  for_each = local.deploy_project_ids

  name    = "deny-all-ingress-to-backend"
  project = each.value
  network = google_compute_network.vpc[each.key].id

  priority  = 2000
  direction = "INGRESS"

  deny {
    protocol = "all"
  }

  source_ranges      = ["0.0.0.0/0"]
  destination_ranges = ["10.0.2.0/24"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# --- Rule 4: Allow backend egress to Google APIs (Private Google Access) ---
resource "google_compute_firewall" "allow_backend_to_google_apis" {
  for_each = local.deploy_project_ids

  name    = "allow-backend-to-google-apis"
  project = each.value
  network = google_compute_network.vpc[each.key].id

  priority  = 1000
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  # Private Google Access IP ranges
  destination_ranges = ["199.36.153.8/30"]

  # Source: backend subnet instances only
  source_ranges = ["10.0.2.0/24"]
}

# --- Rule 5: Allow backend egress to frontend subnet (return traffic) ---
resource "google_compute_firewall" "allow_backend_to_frontend" {
  for_each = local.deploy_project_ids

  name    = "allow-backend-to-frontend-return"
  project = each.value
  network = google_compute_network.vpc[each.key].id

  priority  = 1100
  direction = "EGRESS"

  allow {
    protocol = "tcp"
  }

  destination_ranges = ["10.0.1.0/24"]
  source_ranges      = ["10.0.2.0/24"]
}

# --- Rule 6: Allow HTTPS egress to internet via Cloud NAT ---
# Allows backend to call external HTTPS APIs. Cloud NAT translates the
# private IP to a public IP. Only port 443 is permitted.
resource "google_compute_firewall" "allow_backend_https_egress" {
  for_each = local.deploy_project_ids

  name    = "allow-backend-https-egress"
  project = each.value
  network = google_compute_network.vpc[each.key].id

  priority  = 1500
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.app_sa[each.key].email]
}

# --- Rule 7: Deny all other internet egress from backend ---
# Catches everything not matched above (non-HTTPS protocols, non-443 ports).
resource "google_compute_firewall" "deny_internet_egress_from_backend" {
  for_each = local.deploy_project_ids

  name    = "deny-internet-egress-from-backend"
  project = each.value
  network = google_compute_network.vpc[each.key].id

  priority  = 2000
  direction = "EGRESS"

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  source_ranges      = ["10.0.2.0/24"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
```

### 6.2 Firewall Rule Summary

| # | Rule | Dir | Source | Destination | Proto | Action | Priority |
|---|------|-----|--------|-------------|-------|--------|----------|
| 1 | Allow HTTPS to frontend | Ingress | `0.0.0.0/0` | `10.0.1.0/24` | TCP/443 | Allow | 1000 |
| 2 | Allow frontend to backend | Ingress | `10.0.1.0/24` | `10.0.2.0/24` | TCP/443,8080 | Allow | 1100 |
| 3 | Deny all ingress to backend | Ingress | `0.0.0.0/0` | `10.0.2.0/24` | All | Deny | 2000 |
| 4 | Allow backend to Google APIs | Egress | Backend SA | `199.36.153.8/30` | TCP/443 | Allow | 1000 |
| 5 | Allow backend to frontend (return) | Egress | `10.0.2.0/24` | `10.0.1.0/24` | TCP | Allow | 1100 |
| 6 | Allow backend HTTPS egress (NAT) | Egress | Backend SA | `0.0.0.0/0` | TCP/443 | Allow | 1500 |
| 7 | Deny all other backend egress | Egress | Backend SA | `0.0.0.0/0` | All | Deny | 2000 |

### 6.3 How Firewall Rules Apply to Cloud Run with Direct VPC Egress

```
Backend Cloud Run instance (IP: 10.0.2.5)
  |
  +--> Outbound to aiplatform.googleapis.com (199.36.153.8)
  |       Rule 4: ALLOW (priority 1000) -- matches 199.36.153.8/30
  |
  +--> Outbound to https://api.external-service.com (203.0.113.50:443)
  |       Rule 4: no match (not 199.36.153.8/30)
  |       Rule 5: no match (not 10.0.1.0/24)
  |       Rule 6: ALLOW (priority 1500) -- matches TCP/443 to 0.0.0.0/0
  |               Cloud NAT translates 10.0.2.5 --> public IP  <-- ALLOWED
  |
  +--> Outbound to http://evil.com (203.0.113.50:80)
  |       Rule 4-6: no match (port 80, not TCP/443)
  |       Rule 7: DENY (priority 2000) -- matches 0.0.0.0/0  <-- BLOCKED
  |
  +--> Inbound from frontend (10.0.1.15)
  |       Rule 2: ALLOW (priority 1100) -- source 10.0.1.0/24, dest 10.0.2.0/24
  |
  +--> Inbound from internet (1.2.3.4)
          Rule 2: no match (source not 10.0.1.0/24)
          Rule 3: DENY (priority 2000) -- matches 0.0.0.0/0 to 10.0.2.0/24  <-- BLOCKED
```

### 6.4 Verification

```bash
# List all firewall rules for the VPC
gcloud compute firewall-rules list \
  --filter="network:agent-adk-vpc" \
  --project=YOUR_PROJECT_ID \
  --sort-by=priority \
  --format="table(name, direction, priority, sourceRanges, destinationRanges, allowed, denied)"

# Check firewall logs for denied traffic (indicates misconfig or attack)
gcloud logging read \
  'resource.type="gce_subnetwork" AND
   jsonPayload.disposition="DENIED"' \
  --project=YOUR_PROJECT_ID \
  --limit=20 \
  --format=json

# Verify Cloud Run instance has a subnet IP (Direct VPC Egress)
gcloud run revisions describe REVISION_NAME \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID \
  --format="yaml(spec.template.metadata.annotations['run.googleapis.com/network-interfaces'])"
```

---

## 7. Additional Security Controls

### 7.1 Cloud Armor (WAF)

Attach a Cloud Armor security policy to the frontend load balancer to protect against OWASP Top 10, L7 DDoS, and bot traffic.

```hcl
# ============================================================
# cloud_armor.tf - WAF security policy
# ============================================================

resource "google_compute_security_policy" "frontend_waf" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-waf"
  project = each.value

  # Rule 1: Block OWASP SQL injection
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection attempts"
  }

  # Rule 2: Block OWASP XSS
  rule {
    action   = "deny(403)"
    priority = 1100
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
    description = "Block cross-site scripting attempts"
  }

  # Rule 3: Block OWASP Local File Inclusion
  rule {
    action   = "deny(403)"
    priority = 1200
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('lfi-v33-stable')"
      }
    }
    description = "Block local file inclusion attempts"
  }

  # Rule 4: Block OWASP Remote Code Execution
  rule {
    action   = "deny(403)"
    priority = 1300
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('rce-v33-stable')"
      }
    }
    description = "Block remote code execution attempts"
  }

  # Rule 5: Rate limiting per client IP
  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
      enforce_on_key = "IP"
    }
    description = "Rate limit: 100 requests per minute per IP"
  }

  # Default rule: allow
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow rule"
  }
}
```

### 7.2 HTTPS Load Balancer for Frontend

```hcl
# ============================================================
# load_balancer.tf - External HTTPS LB with Cloud Armor
# ============================================================

resource "google_compute_region_network_endpoint_group" "frontend_neg" {
  for_each = local.deploy_project_ids

  name                  = "${var.project_name}-frontend-neg"
  project               = each.value
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.frontend[each.key].name
  }
}

resource "google_compute_backend_service" "frontend_backend" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-frontend-backend"
  project = each.value

  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.frontend_waf[each.key].id

  backend {
    group = google_compute_region_network_endpoint_group.frontend_neg[each.key].id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}
```

### 7.3 Secret Management

```hcl
data "google_secret_manager_secret_version" "github_pat" {
  count   = var.github_pat_secret_id != null ? 1 : 0
  project = var.cicd_runner_project_id
  secret  = var.github_pat_secret_id
}

resource "google_secret_manager_secret_iam_member" "cicd_secret_access" {
  count     = var.github_pat_secret_id != null ? 1 : 0
  project   = var.cicd_runner_project_id
  secret_id = var.github_pat_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cicd_runner_sa.email}"
}
```

```bash
# Create a secret via gcloud (one-time setup)
echo -n "ghp_YOUR_TOKEN" | gcloud secrets create github-pat \
  --project=YOUR_CICD_PROJECT \
  --replication-policy="user-managed" \
  --locations="us-central1" \
  --data-file=-

# Verify access
gcloud secrets versions access latest \
  --secret=github-pat \
  --project=YOUR_CICD_PROJECT
```

### 7.4 Container Security

```hcl
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "${var.project_name}-repo"
  format        = "DOCKER"
  project       = var.cicd_runner_project_id

  docker_config {
    immutable_tags = true
  }

  cleanup_policies {
    id     = "delete-old-images"
    action = "DELETE"
    condition {
      older_than = "2592000s"  # 30 days
      tag_state  = "UNTAGGED"
    }
  }

  depends_on = [google_project_service.cicd_services]
}
```

```bash
# Enable automatic vulnerability scanning (on-push)
gcloud artifacts repositories update agent-starter-adk-cr-repo \
  --project=YOUR_CICD_PROJECT \
  --location=us-central1 \
  --enable-vulnerability-scanning

# Scan an existing image manually
gcloud artifacts docker images scan \
  us-central1-docker.pkg.dev/YOUR_CICD_PROJECT/agent-starter-adk-cr-repo/agent-starter-adk-cr \
  --project=YOUR_CICD_PROJECT
```

### 7.5 Cloud Run Authentication Enforcement

```bash
# Verify no public access on the backend service
gcloud run services get-iam-policy agent-starter-adk-cr-backend \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID \
  --format=json | \
  jq '.bindings[] | select(.members[] | contains("allUsers") or contains("allAuthenticatedUsers"))'

# Expected output: empty (no matches)
```

### 7.6 TLS Configuration

Cloud Run enforces TLS 1.2+ termination by default. No additional configuration is needed for:
- Internet -> Frontend (HTTPS via Cloud Load Balancer with Google-managed certificate)
- Frontend -> Backend (HTTPS via Cloud Run internal URL over Direct VPC Egress)
- Backend -> Google APIs (HTTPS/gRPC over Private Google Access)

```hcl
resource "google_compute_managed_ssl_certificate" "frontend_cert" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-frontend-cert"
  project = each.value

  managed {
    domains = [var.frontend_domain]
  }
}
```

```hcl
variable "frontend_domain" {
  type        = string
  description = "Custom domain for the frontend (e.g., chat.example.com)"
  default     = ""
}
```

---

## Appendix A: Current State vs. Target Architecture

| Layer | Starter-pack (current code) | Target (this document) |
|-------|----------------------------|----------------------|
| VPC | None | Custom VPC with 2 subnets |
| Cloud Run -> VPC bridge | None | Direct VPC Egress (instances get subnet IPs) |
| Backend ingress | `INGRESS_TRAFFIC_ALL` | `INGRESS_TRAFFIC_INTERNAL_ONLY` (backend), `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` (frontend) |
| Backend auth | `--no-allow-unauthenticated` | Same + VPC-level isolation |
| Firewall rules | None | 7 rules (ingress/egress on subnet CIDRs + SA targeting) |
| Google API access | Google-managed (automatic) | Private Google Access (explicit, via subnet) |
| Cloud Armor | None | WAF with OWASP rules + rate limiting |
| VPC-SC perimeter | None | Service perimeter around staging/prod |
| VPC Connector | None | **Not needed** -- Direct VPC Egress replaces it |
| Cloud Router/NAT | None | Cloud Router + Cloud NAT on backend subnet (HTTPS egress via auto-allocated IPs) |

## Appendix B: Security Audit Checklist

Use this checklist before promoting to production:

- [ ] Backend Cloud Run ingress is `INGRESS_TRAFFIC_INTERNAL_ONLY`
- [ ] Backend uses Direct VPC Egress with `ALL_TRAFFIC` into `backend-subnet`
- [ ] Frontend uses Direct VPC Egress with `PRIVATE_RANGES_ONLY` into `frontend-subnet`
- [ ] Backend has no `allUsers` or `allAuthenticatedUsers` IAM bindings
- [ ] Frontend SA has `roles/run.invoker` only on the backend service (not project-wide)
- [ ] No service uses the default compute service account
- [ ] No primitive roles (`owner`/`editor`) are assigned
- [ ] No exported service account keys exist
- [ ] VPC firewall denies all non-HTTPS internet egress from backend (priority 2000)
- [ ] Firewall allows backend HTTPS egress to Google APIs (`199.36.153.8/30`, priority 1000) and to internet via Cloud NAT (port 443, priority 1500)
- [ ] Cloud Router and Cloud NAT are provisioned on backend subnet only
- [ ] Frontend ingress is `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` (no direct `run.app` access)
- [ ] Frontend has `allUsers` → `roles/run.invoker` (unauthenticated access via LB only)
- [ ] Private Google Access is enabled on all subnets
- [ ] Private DNS zone resolves `*.googleapis.com` to `private.googleapis.com`
- [ ] Cloud Armor WAF policy is attached to the frontend load balancer
- [ ] Artifact Registry has vulnerability scanning enabled
- [ ] Secrets are in Secret Manager, not in env vars or code
- [ ] VPC Service Controls dry-run shows no violations (if enabled)
- [ ] Firewall logs are flowing to Cloud Logging
- [ ] `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` is set to `NO_CONTENT`
