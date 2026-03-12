# Network and Security Architecture


This document details the network design, segmentation, and security perimeter configurations for the `agent-vpc-demo` application.

## 1. VPC Design

The application utilizes a Virtual Private Cloud (VPC) to isolate the backend agent from direct public access. The architecture includes a public subnet for the frontend Chatbot UI and a private subnet for the FastAPI ADK backend.

```text
+------------------------------------------------------------------+
|                      Project VPC                                 |
|                                                                  |
|  +---------------------------+  +-----------------------------+  |
|  |   Public Subnet           |  |   Private Subnet            |  |
|  |   10.0.1.0/24             |  |   10.0.2.0/24               |  |
|  |                           |  |                             |  |
|  |   - Frontend (Cloud Run)  |  |   - Backend (Cloud Run)     |  |
|  |   - External LB Ingress   |  |   - Internal-only ingress   |  |
|  |   - Direct VPC Egress     |  |   - Direct VPC Egress       |  |
|  +---------------------------+  +-----------------------------+  |
|                                                                  |
|  +------------------------------------------------------------+  |
|  |   Cloud Router + Cloud NAT (backend subnet only)           |  |
|  +------------------------------------------------------------+  |
|                                                                  |
|  +------------------------------------------------------------+  |
|  |   Private Service Connect / Private Google Access          |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

## 2. Network Segmentation

Network traffic is segmented between the public frontend and the private backend.

### Frontend (Public Subnet)

| Aspect | Detail |
|---|---|
| **Inbound** | External users → Global HTTPS Load Balancer → Cloud Armor WAF → Serverless NEG → Cloud Run. Direct `run.app` URL access is blocked (`INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`). |
| **Outbound** | `ALL_TRAFFIC` through the VPC — firewall rules block non-HTTPS internet egress. Can reach the backend and Google APIs via Private Google Access. |
| **External API calls** | No. The frontend can only talk to the backend Cloud Run service. |

### Backend (Private Subnet)

| Aspect | Detail |
|---|---|
| **Inbound** | `INGRESS_TRAFFIC_INTERNAL_ONLY` — only reachable from within the VPC (i.e., the frontend). No public access. |
| **Outbound** | `ALL_TRAFFIC` routed through the VPC. Firewall rules control what is allowed. |
| **External API calls** | Yes, HTTPS only (port 443) via Cloud NAT. |

## 3. Private Endpoints

To securely access Google Cloud APIs (like Vertex AI, Cloud Storage, and BigQuery) without traversing the public internet, the VPC uses Private Google Access and Private Service Connect (PSC).

* Traffic destined for `*.googleapis.com` is resolved via a private DNS zone to `private.googleapis.com` (`199.36.153.8/30`) and stays on Google's internal backbone.
* Private Google Access is enabled on both subnets (`private_ip_google_access = true`).

## 4. Zero-Trust Architecture

The system implements zero-trust principles, meaning there is no implicit trust even within the private network. Every request between the frontend and backend must be authenticated using Identity and Access Management (IAM).

* The frontend service account is granted `roles/run.invoker` on the backend service (not project-wide).
* The backend rejects requests that do not present a trusted OIDC identity token.
* The frontend allows unauthenticated access (`allUsers` → `roles/run.invoker`), but only through the load balancer — direct `run.app` URL access is blocked by the ingress setting.

## 5. Cloud Router and Cloud NAT

A Cloud Router and Cloud NAT are provisioned on the backend subnet to give backend Cloud Run instances controlled outbound internet access.

| Aspect | Detail |
|---|---|
| **Scope** | Backend subnet only. The frontend subnet is not NATed. |
| **IP allocation** | `AUTO_ONLY` — Google automatically allocates external IPs. |
| **Purpose** | Allows the backend to call external HTTPS APIs (e.g., third-party REST services) without exposing it to inbound internet traffic. |
| **Logging** | Enabled with `ERRORS_ONLY` filter. |

**How it works:** Backend Cloud Run instances get internal IPs from the backend subnet via Direct VPC Egress. When they make outbound HTTPS calls, the firewall allows TCP/443 egress (priority 1500), and Cloud NAT translates the private IP to a public IP before the request leaves Google's network.

## 6. External HTTPS Load Balancer

The frontend is fronted by a Global External Application Load Balancer with Cloud Armor WAF.

```text
Internet User
    │
    ▼
Global Static IP + Managed SSL Certificate
    │
    ▼
HTTPS Forwarding Rule (port 443)
    │
    ▼
Target HTTPS Proxy
    │
    ▼
URL Map → Backend Service (with Cloud Armor)
    │
    ▼
Serverless NEG → Frontend Cloud Run
```

**Features:**
- **Managed SSL certificate** — auto-provisioned and auto-renewed for `var.frontend_domain`
- **HTTP→HTTPS redirect** — port 80 automatically redirects to port 443
- **Full request logging** — `sample_rate = 1.0` on the backend service

## 7. Cloud Armor (WAF)

A Cloud Armor security policy is attached to the load balancer's backend service.

| Priority | Rule | Action |
|---|---|---|
| 1000 | Rate limiting (100 req/min per IP, 5-min ban) | `rate_based_ban` |
| 2000 | SQL injection (`sqli-v33-stable`) | `deny(403)` |
| 2001 | Cross-site scripting (`xss-v33-stable`) | `deny(403)` |
| 2147483647 | Default allow | `allow` |

## 8. Firewall Rules

Firewall rules govern the allowed communication paths. With Direct VPC Egress, these rules apply directly to Cloud Run instances.

| # | Priority | Rule | Direction | Source/Target | Destination | Protocol | Action |
|---|---|---|---|---|---|---|---|
| 1 | 1000 | Allow HTTPS to frontend | Ingress | `0.0.0.0/0` | `10.0.1.0/24` | TCP/443 | Allow (logged) |
| 2 | 1100 | Allow frontend to backend | Ingress | `10.0.1.0/24` | `10.0.2.0/24` | TCP/443,8080 | Allow (logged) |
| 3 | 2000 | Deny all ingress to backend | Ingress | `0.0.0.0/0` | `10.0.2.0/24` | All | Deny (logged) |
| 4 | 1000 | Allow backend to Google APIs | Egress | Backend SA | `199.36.153.8/30` | TCP/443 | Allow |
| 5 | 1100 | Allow backend to frontend (return) | Egress | Backend SA | `10.0.1.0/24` | TCP | Allow |
| 6 | 1500 | Allow backend HTTPS egress (NAT) | Egress | Backend SA | `0.0.0.0/0` | TCP/443 | Allow |
| 7 | 2000 | Deny all other backend egress | Egress | Backend SA | `0.0.0.0/0` | All | Deny (logged) |

**Evaluation order:** When the backend calls an external API, the firewall evaluates rules by priority. Rule 4 matches Google API IPs first. Rule 6 allows HTTPS to any other destination (NATed by Cloud NAT). Rule 7 blocks everything else (non-HTTPS protocols, non-443 ports). Ingress rules 1-3 ensure only the frontend subnet can reach the backend.

## 9. Service Perimeters (VPC Service Controls)

A VPC Service Controls perimeter forms a defense-in-depth shield around the GCP project to prevent data exfiltration.

**Perimeter Blueprint:**
* Protected APIs: `aiplatform.googleapis.com`, `storage.googleapis.com`, `bigquery.googleapis.com`, `logging.googleapis.com`.
* Ingress Rules: Allow cross-project Cloud Build deployments.
* Egress Rules: Deny all (prevents any data from being sent outside the perimeter).

## 10. End-to-End Traffic Flow

```text
Internet User
    │
    ▼
Global HTTPS LB (static IP, managed SSL cert)
    │
    ▼
Cloud Armor WAF (rate limit, SQLi/XSS block)
    │
    ▼
Frontend Cloud Run ── frontend-subnet (10.0.1.0/24)
    │  (ALL_TRAFFIC egress through VPC)
    ▼
Backend Cloud Run ─── backend-subnet (10.0.2.0/24)
    │
    ├──► Google APIs ─── via Private Google Access (199.36.153.8/30, never leaves Google's network)
    │
    └──► External APIs ── via Cloud NAT (HTTPS/443 only, auto-allocated public IP)
```

### Can each service reach the public internet?

| Service | Outbound to Internet | How |
|---|---|---|
| **Frontend** | No | `ALL_TRAFFIC` egress through VPC — firewall blocks non-HTTPS internet egress |
| **Backend** | HTTPS only (port 443) | Via Cloud NAT through the private subnet. All non-443 traffic is denied by firewall. |

### Can each service call external APIs?

| Service | External API calls | Reason |
|---|---|---|
| **Frontend** | No | It can only reach the backend (private ranges). Any external data fetching must be delegated to the backend. |
| **Backend** | Yes (HTTPS only) | Firewall allows 443 egress → Cloud NAT translates the private IP to a public IP → request reaches the external API. |
