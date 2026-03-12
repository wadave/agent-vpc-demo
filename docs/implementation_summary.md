# Implementation Summary: agent-vpc-demo

**Date:** 2026-03-11

---

## System Overview

**agent-vpc-demo** is a conversational AI chatbot built on the Google Agent Development Kit (ADK) and deployed to Google Cloud Run. It uses a two-tier architecture: a public-facing **frontend** chatbot UI communicates with a private **backend** FastAPI server hosting a ReAct agent powered by Gemini 3 Flash Preview via Vertex AI.

---

## System Architecture Diagram

```
                             Internet
                                |
                        +-------+-------+
                        |  Cloud Load   |
                        |  Balancer     |
                        | (HTTPS + WAF) |
                        +-------+-------+
                                |
   +====================================================================+
   |                      agent-adk-vpc                                  |
   |                                                                     |
   |  +-------------------------------+                                  |
   |  |  frontend-subnet              |                                  |
   |  |  10.0.1.0/24                  |                                  |
   |  |                               |                                  |
   |  |  Frontend Cloud Run           |                                  |
   |  |  - Chatbot UI (HTML/JS)       |                                  |
   |  |  - FastAPI proxy + OIDC auth  |                                  |
   |  |  - Ingress: via LB only       |                                  |
   |  |  - Egress: PRIVATE_RANGES     |                                  |
   |  |  - 1 vCPU / 512 Mi            |                                  |
   |  +-------+--+--------------------+                                  |
   |           |                                                         |
   |     VPC internal (HTTPS + OIDC identity token)                      |
   |     10.0.1.x --> 10.0.2.x                                          |
   |           |                                                         |
   |  +--------+-----------------------+                                 |
   |  |  backend-subnet                |                                 |
   |  |  10.0.2.0/24                   |                                 |
   |  |                                |                                 |
   |  |  Backend Cloud Run             |                                 |
   |  |  - FastAPI + ADK Agent         |                                 |
   |  |  - Ingress: INTERNAL_ONLY      |                                 |
   |  |  - Egress: ALL_TRAFFIC via VPC |                                 |
   |  |  - 4 vCPU / 8 Gi              |                                 |
   |  +------+------+-----------------+                                  |
   |         |      |                                                    |
   |  +------+--+ +-+------------------------------+                     |
   |  | Private | | Cloud Router + Cloud NAT        |                    |
   |  | Google  | | (backend subnet only)           |                    |
   |  | Access  | | External HTTPS/443 via NAT      |                    |
   |  +---------+ +--------------------------------+                     |
   |                                                                     |
   |  +---------------------------------------------------------------+ |
   |  |  Private DNS: *.googleapis.com --> 199.36.153.8/30             | |
   |  |  (private.googleapis.com -- never leaves Google's network)     | |
   |  +---------------------------------------------------------------+ |
   +=====================================================================+
              |                                  |
   +----------+----------+          +------------+------------+
   | Vertex AI API       |          | Observability Stack     |
   | (Gemini 3 Flash)    |          | - Cloud Trace           |
   | via Private Google  |          | - Cloud Logging (10yr)  |
   | Access              |          | - BigQuery Analytics    |
   +---------------------+          | - GCS Artifacts Bucket  |
                                    +-------------------------+
```

---

## Network / VPC Details

### VPC Configuration

| Resource | Value |
|----------|-------|
| **VPC Name** | `{project_name}-vpc` |
| **Routing Mode** | `REGIONAL` |
| **Auto-create Subnets** | `false` (custom subnets) |
| **Private Google Access** | Enabled on both subnets |

### Subnet Layout

| Subnet | CIDR | Purpose | Cloud Run Egress Mode |
|--------|------|---------|-----------------------|
| `{name}-frontend` | `10.0.1.0/24` | Public-facing chatbot UI | `PRIVATE_RANGES_ONLY` -- can only reach internal (RFC 1918) addresses |
| `{name}-backend` | `10.0.2.0/24` | Private ADK agent backend | `ALL_TRAFFIC` -- all outbound routed through VPC, controlled by firewall |

Both subnets use **Direct VPC Egress** (not VPC Connector), meaning each Cloud Run instance gets a real IP from the subnet and is directly subject to VPC firewall rules and Private Google Access.

### Private Google Access & DNS

API traffic to Google Cloud services never traverses the public internet:

- A **private DNS zone** resolves `*.googleapis.com` via CNAME to `private.googleapis.com`
- `private.googleapis.com` resolves to A records: `199.36.153.8/30` (4 IPs)
- Protected services: `aiplatform.googleapis.com`, `storage.googleapis.com`, `bigquery.googleapis.com`, `logging.googleapis.com`

### Cloud Router & Cloud NAT

| Setting | Value |
|---------|-------|
| **Scope** | Backend subnet only (frontend is not NATed) |
| **NAT IP Allocation** | `AUTO_ONLY` |
| **Purpose** | Gives backend controlled outbound HTTPS access to external APIs |
| **Logging** | Enabled, `ERRORS_ONLY` filter |

### Firewall Rules

7 firewall rules control all ingress/egress traffic:

| # | Priority | Name | Direction | Source | Destination | Protocol | Action |
|---|----------|------|-----------|--------|-------------|----------|--------|
| 1 | 1000 | `allow-https-to-frontend` | Ingress | `0.0.0.0/0` | `10.0.1.0/24` | TCP/443 | Allow (logged) |
| 2 | 1100 | `allow-frontend-to-backend` | Ingress | `10.0.1.0/24` | `10.0.2.0/24` | TCP/443,8080 | Allow (logged) |
| 3 | 2000 | `deny-all-ingress-to-backend` | Ingress | `0.0.0.0/0` | `10.0.2.0/24` | All | Deny (logged) |
| 4 | 1000 | `allow-backend-to-google-apis` | Egress | Backend SA | `199.36.153.8/30` | TCP/443 | Allow |
| 5 | 1100 | `allow-backend-to-frontend-return` | Egress | Backend SA | `10.0.1.0/24` | TCP | Allow |
| 6 | 1500 | `allow-backend-https-egress` | Egress | Backend SA | `0.0.0.0/0` | TCP/443 | Allow |
| 7 | 2000 | `deny-internet-egress-from-backend` | Egress | Backend SA | `0.0.0.0/0` | All | Deny (logged) |

**Evaluation order:** Rules are evaluated by priority (lowest number first). For backend egress: Rule 4 matches Google API IPs, Rule 6 allows HTTPS/443 to any destination (NATed), Rule 7 blocks everything else.

### Internet Access Summary

| Service | Outbound to Internet | Mechanism |
|---------|---------------------|-----------|
| **Frontend** | No | `PRIVATE_RANGES_ONLY` -- trapped in VPC, can only reach backend |
| **Backend** | HTTPS only (port 443) | Via Cloud NAT; non-443 traffic denied by firewall |

---

## External Load Balancer

```
Internet User --> Global Static IP + Managed SSL Certificate
                      |
                  HTTPS Forwarding Rule (port 443)
                      |
                  Target HTTPS Proxy
                      |
                  URL Map --> Backend Service (with Cloud Armor WAF)
                      |
                  Serverless NEG --> Frontend Cloud Run
```

- **Managed SSL certificate** -- auto-provisioned for `var.frontend_domain`
- **HTTP-to-HTTPS redirect** -- port 80 returns 301 to port 443
- **Request logging** -- `sample_rate = 1.0` (100% of requests logged)
- Direct `run.app` URL access blocked (`INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`)

---

## Cloud Armor (WAF) Rules

| Priority | Rule | Action |
|----------|------|--------|
| 1000 | Rate limiting: 100 req/min per IP, 5-min ban | `rate_based_ban` |
| 2000 | SQL injection (`sqli-v33-stable`) | `deny(403)` |
| 2001 | Cross-site scripting (`xss-v33-stable`) | `deny(403)` |
| 2147483647 | Default allow | `allow` |

---

## Zero-Trust Security

1. **Identity-based access:** Backend Cloud Run deployed with `--no-allow-unauthenticated`. Frontend must present a valid Google-signed OIDC identity token.
2. **Least-privilege IAM:** Dedicated service accounts per tier (app SA, frontend SA, CI/CD SA) with narrowly scoped roles. No primitive roles.
3. **Service-to-service auth:** Frontend SA granted `roles/run.invoker` on the backend service (not project-wide).
4. **VPC Service Controls:** Perimeter around the project protects `aiplatform`, `storage`, `bigquery`, and `logging` APIs. Egress denied -- prevents data exfiltration.

---

## Cloud Run Service Configuration

| Setting | Backend | Frontend |
|---------|---------|----------|
| **CPU** | 4 vCPU (always-on) | 1 vCPU |
| **Memory** | 8 Gi | 512 Mi |
| **Concurrency** | 40 req/instance | Default |
| **Min Instances** | 1 | Default |
| **Max Instances** | 10 | Default |
| **Ingress** | `INTERNAL_ONLY` | `INTERNAL_LOAD_BALANCER` |
| **VPC Egress** | `ALL_TRAFFIC` via backend-subnet | `PRIVATE_RANGES_ONLY` via frontend-subnet |
| **Auth** | `--no-allow-unauthenticated` | `allUsers` (public via LB only) |
| **Session Affinity** | Enabled | -- |

---

## Data Flow

### Chat Request
```
User --> HTTPS --> Cloud LB --> Cloud Armor --> Frontend Cloud Run
    --> HTTPS + OIDC token --> Direct VPC Egress --> Backend Cloud Run
        --> ADK Agent --> Tool calls (weather/time)
        --> Vertex AI Gemini API (Private Google Access)
        --> SSE stream response back to frontend --> User
```

### Observability
- **Traces** --> Cloud Trace (30-day retention)
- **GenAI completions** --> GCS bucket as JSONL
- **Inference + feedback logs** --> Cloud Logging dedicated bucket (10-year retention)
- **Analytics** --> BigQuery external tables + completions view

---

## CI/CD Pipeline (3-Project Isolation)

| Environment | Purpose |
|-------------|---------|
| **CI/CD Project** | Cloud Build pipelines, Artifact Registry, build logs |
| **Staging Project** | Pre-production validation, load testing |
| **Production Project** | Live user traffic (manual approval required) |

```
PR --> PR Checks (unit + integration tests)
Push to main --> CD Pipeline (build, deploy to staging, load test)
Manual Approval --> Deploy to Production
```

---

## Terraform File Reference

| File | Resources |
|------|-----------|
| `network.tf` | VPC, subnets, Private DNS zone, Cloud Router, Cloud NAT |
| `firewall.tf` | 7 firewall rules (ingress/egress controls) |
| `loadbalancer.tf` | Global HTTPS LB, Cloud Armor WAF, SSL cert, NEG, HTTP redirect |
| `service.tf` | Backend + Frontend Cloud Run services with VPC egress |
| `service_accounts.tf` | App SA, Frontend SA, CI/CD SA |
| `iam.tf` | Least-privilege IAM bindings |
| `storage.tf` | GCS buckets, Artifact Registry |
| `telemetry.tf` | BigQuery dataset, Cloud Logging buckets, log sinks |
| `build_triggers.tf` | Cloud Build triggers (PR, CD, production) |
