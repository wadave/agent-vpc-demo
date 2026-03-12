# Software Design Document: agent-starter-adk-cr

**Version:** 1.0
**Date:** 2026-03-09
**Status:** Draft

---

## Table of Contents

1. [Overview](#1-overview)
2. [Goals and Non-Goals](#2-goals-and-non-goals)
3. [System Architecture](#3-system-architecture)
4. [Component Design](#4-component-design)
5. [Network and Security Architecture](#5-network-and-security-architecture)
6. [Data Flow](#6-data-flow)
7. [Infrastructure and Deployment](#7-infrastructure-and-deployment)
8. [Observability](#8-observability)
9. [Testing Strategy](#9-testing-strategy)
10. [CI/CD Pipeline](#10-cicd-pipeline)

---

## 1. Overview

**agent-starter-adk-cr** is a conversational AI agent built on the Google Agent Development Kit (ADK) and deployed to Google Cloud Run. The system exposes a chatbot interface (frontend) in a public-facing subnet that communicates with a FastAPI backend hosting the ADK agent in a private subnet. The architecture follows zero-trust security principles with VPC-based network segmentation, private endpoints, and defense-in-depth controls.

### 1.1 Context

The project is generated from [`GoogleCloudPlatform/agent-starter-pack`](https://github.com/GoogleCloudPlatform/agent-starter-pack) v0.39.0 using the `adk` base template with Cloud Run as the deployment target. It implements a ReAct-pattern agent powered by Gemini 3 Flash Preview, with tool-calling capabilities for weather and time lookups.

---

## 2. Goals and Non-Goals

### 2.1 Goals

- Provide a simple, secure chatbot interface accessible over the public internet.
- Host the ADK agent backend in a private network segment, inaccessible directly from the internet.
- Enforce zero-trust networking between the frontend and backend.
- Support streaming (SSE) responses for real-time conversational UX.
- Provide production-grade CI/CD with staging validation and manual production approval.
- Export telemetry to Cloud Trace, BigQuery, and Cloud Logging for full observability.

### 2.2 Non-Goals

- Multi-agent orchestration or A2A protocol support.
- Persistent session storage (sessions are in-memory by design).
- Custom fine-tuned models; the system uses Gemini via Vertex AI.
- Data ingestion pipelines or RAG datastores.

---

## 3. System Architecture

### 3.1 High-Level Architecture

```
                         Internet
                            |
                    +-------+-------+
                    |  Cloud Load   |
                    |  Balancer     |
                    | (HTTPS + WAF) |
                    +-------+-------+
                            |
                    +-------+-------+
                    |   Frontend    |         frontend-subnet (10.0.1.0/24)
                    |  (Cloud Run)  |         Direct VPC Egress
                    |  Chatbot UI   |         Egress: PRIVATE_RANGES_ONLY
                    +-------+-------+
                            |
               VPC internal (10.0.1.x --> 10.0.2.x)
               HTTPS + OIDC identity token
                            |
                    +-------+-------+
                    |   Backend     |         backend-subnet (10.0.2.0/24)
                    |  (Cloud Run)  |         Direct VPC Egress
                    |  FastAPI +    |         Egress: ALL_TRAFFIC
                    |  ADK Agent    |         Ingress: INTERNAL_ONLY
                    +-------+-------+
                         |      |
              +----------+      +----------+
              |                            |
    +---------+--------+     +-------------+----------+
    | Vertex AI API    |     | Cloud Logging /        |
    | (Gemini Model)   |     | Cloud Trace / BigQuery |
    | Private Google   |     | GCS Artifacts Bucket   |
    | Access           |     |                        |
    | 199.36.153.8/30  |     | (Private Google Access)|
    +------------------+     +------------------------+

    Note: Cloud Run is serverless -- containers run on Google's managed
    infrastructure. Direct VPC Egress gives each instance a real IP from
    the subnet, making it subject to VPC firewall rules and Private
    Google Access. See docs/network_security.md for full detail.
```

### 3.2 Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Cloud Run for both tiers | Serverless scaling, managed TLS, built-in IAM authentication |
| Direct VPC Egress (not VPC Connector) | Each Cloud Run instance gets a real subnet IP; firewall rules and Private Google Access apply directly without proxy VMs |
| SSE streaming over REST | Simpler than WebSockets; native ADK support via `run_sse` endpoint |
| In-memory sessions | Simplicity for stateless workloads; no external DB dependency |
| Terraform for IaC | Reproducible, auditable infrastructure across environments |
| Separate CI/CD project | Isolates build credentials from runtime credentials |

---

## 4. Component Design

### 4.1 Frontend - Chatbot Interface

The frontend is a lightweight vanilla HTML/JS chatbot UI with a FastAPI proxy server, deployed as a separate Cloud Run service in the public subnet.

**Implementation:** `frontend/`
- `server.py` -- FastAPI proxy that forwards API calls to the backend with OIDC identity token authentication.
- `static/index.html` -- Single-page chat UI shell.
- `static/style.css` -- Clean, responsive styling (720px centered container).
- `static/app.js` -- Chat logic: session management, SSE streaming, feedback buttons.
- `Dockerfile` -- Standalone container image for Cloud Run deployment.

**Responsibilities:**
- Render the chat interface for end users.
- Proxy user messages to the backend `/run_sse` endpoint via `/api/chat`.
- Stream SSE responses back to the user in real-time (token-by-token rendering).
- Collect user feedback (thumbs up/down) and proxy to the backend `/feedback` endpoint via `/api/feedback`.
- Authenticate to the backend using an OIDC identity token (service-to-service auth via `google.oauth2.id_token`).
- Manage sessions via `/api/sessions` (auto-creates ADK sessions, persists `user_id` in localStorage).

**Network posture:** Publicly accessible via Cloud Load Balancer with HTTPS termination. Ingress set to `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` (direct `run.app` URL access blocked).

### 4.2 Backend - FastAPI + ADK Agent

The backend is the core application, defined in `backend/`.

#### 4.2.1 FastAPI Server (`backend/fast_api_app.py`)

- Uses `google.adk.cli.fast_api.get_fast_api_app()` to mount the ADK agent as a web application.
- Configures CORS origins via the `ALLOW_ORIGINS` environment variable.
- Exposes the following endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/run_sse` | POST | Streams agent responses via SSE |
| `/apps/{app}/users/{user_id}/sessions` | POST | Creates a new session |
| `/feedback` | POST | Logs user feedback to Cloud Logging |
| `/docs` | GET | OpenAPI documentation (health check) |

- Configures OpenTelemetry export to Cloud Trace.
- Stores artifacts (completions) to a GCS bucket when `LOGS_BUCKET_NAME` is set.

#### 4.2.2 Agent Definition (`backend/agent.py`)

- Defines a single `root_agent` using the ADK `Agent` class.
- Model: `gemini-3-flash-preview` via Vertex AI with 3 retry attempts.
- Instruction: General-purpose helpful assistant.
- **Context & Safety:** Explicitly define Vertex AI safety settings block thresholds inside the ADK agent definition to prevent malicious or abusive content generation.
- Tools:

| Tool | Description |
|------|-------------|
| `get_weather(query)` | Returns simulated weather for a location |
| `get_current_time(query)` | Returns current time for recognized cities |

- Wraps the agent in an ADK `App` instance named `"app"`.

#### 4.2.3 Utility Modules

- **`backend/app_utils/telemetry.py`** - Configures OpenTelemetry GenAI instrumentation. Controls whether prompt/response content is captured (defaults to `NO_CONTENT` metadata-only mode). Uploads completion telemetry as JSONL to GCS.
- **`backend/app_utils/typing.py`** - Pydantic models for `Request` and `Feedback` payloads with auto-generated UUIDs for user/session tracking.

### 4.3 Dependency Summary

| Package | Purpose |
|---------|---------|
| `google-adk >=1.15.0` | Agent Development Kit (agent, runner, sessions) |
| `fastapi >=0.115.8` | Web framework |
| `uvicorn ~=0.34.0` | ASGI server |
| `google-cloud-logging >=3.12.0` | Structured logging to Cloud Logging |
| `google-cloud-aiplatform[evaluation]` | Vertex AI SDK for eval |
| `opentelemetry-instrumentation-google-genai` | GenAI telemetry |
| `httpx >=0.28.0` | Async HTTP client (frontend proxy for backend calls) |
| `gcsfs` | GCS filesystem access for artifact storage |

---

## 5. Network and Security Architecture

> For implementation-level detail including Terraform code, `gcloud` commands, and a security audit checklist, see [`docs/network_security.md`](network_security.md).

### 5.1 VPC Design

```
+--------------------------------------------------------------------------+
|                           agent-adk-vpc                                  |
|                                                                          |
|  +-------------------------------+  +----------------------------------+ |
|  |  frontend-subnet              |  |  backend-subnet                  | |
|  |  10.0.1.0/24                  |  |  10.0.2.0/24                     | |
|  |                               |  |                                  | |
|  |  Frontend Cloud Run           |  |  Backend Cloud Run               | |
|  |  (Direct VPC Egress --        |  |  (Direct VPC Egress --           | |
|  |   instances get 10.0.1.x IPs) |  |   instances get 10.0.2.x IPs)   | |
|  |                               |  |                                  | |
|  |  - External LB + WAF ingress  |  |  - INTERNAL_ONLY ingress         | |
|  |  - Egress: PRIVATE_RANGES     |  |  - Egress: ALL_TRAFFIC via VPC   | |
|  +-------------------------------+  +----------------------------------+ |
|                                                                          |
|  +--------------------------------------------------------------------+  |
|  |  Private Google Access (enabled on both subnets)                   |  |
|  |  DNS: *.googleapis.com --> 199.36.153.8/30 (private.googleapis.com)|  |
|  |  - aiplatform.googleapis.com    - logging.googleapis.com           |  |
|  |  - storage.googleapis.com       - bigquery.googleapis.com          |  |
|  +--------------------------------------------------------------------+  |
+--------------------------------------------------------------------------+
```

### 5.2 Network Segmentation

| Layer | Configuration |
|-------|---------------|
| **Frontend subnet** (10.0.1.0/24) | Public-facing via LB. Cloud Run ingress: `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`. Direct VPC Egress with `PRIVATE_RANGES_ONLY` -- only backend calls route through the VPC. Instances get 10.0.1.x IPs. |
| **Backend subnet** (10.0.2.0/24) | Private. Cloud Run ingress: `INGRESS_TRAFFIC_INTERNAL_ONLY`. Direct VPC Egress with `ALL_TRAFFIC` -- all outbound goes through the VPC. Instances get 10.0.2.x IPs. Firewall denies internet egress. |
| **Google APIs** | Accessed via Private Google Access on backend subnet. DNS resolves `*.googleapis.com` to `199.36.153.8/30`. No API traffic traverses the public internet. |

### 5.3 Zero-Trust Architecture

The system implements zero-trust principles at every layer:

1. **Identity-based access (no network trust):**
   - The backend Cloud Run service is deployed with `--no-allow-unauthenticated`.
   - The frontend must present a valid Google-signed identity token to invoke the backend.
   - Service-to-service authentication uses IAM-based `roles/run.invoker` bindings.

2. **Least-privilege IAM:**
   - **Application SA** (`{project-name}-app`): Granted only `aiplatform.user`, `logging.logWriter`, `cloudtrace.agent`, `storage.admin`, and `serviceusage.serviceUsageConsumer`.
   - **CI/CD SA** (`{project-name}-cb`): Scoped to build, deploy, and test operations. Cannot access production data.
   - No use of primitive roles (Owner/Editor).

3. **No implicit trust between services:**
   - Every API call from the backend to Google services is authenticated via the application service account.
   - Cloud Run service identity is bound to a dedicated SA, not the default compute SA.

### 5.4 VPC Service Controls (Service Perimeter)

To prevent data exfiltration, a VPC Service Controls perimeter should be configured around the project:

```
Service Perimeter: agent-starter-adk-cr-perimeter
  Protected Services:
    - aiplatform.googleapis.com
    - storage.googleapis.com
    - bigquery.googleapis.com
    - logging.googleapis.com
  Access Levels:
    - Allow CI/CD project service account (for deployments)
    - Allow frontend Cloud Run service identity (for backend invocation)
  Ingress Policy:
    - Allow Cloud Build from CI/CD project
  Egress Policy:
    - Deny all (no data can leave the perimeter)
```

### 5.5 Firewall Policies

| # | Rule | Direction | Source | Destination | Action | Priority |
|---|------|-----------|--------|-------------|--------|----------|
| 1 | Allow HTTPS to frontend | Ingress | `0.0.0.0/0` | `10.0.1.0/24`, port 443 | Allow | 1000 |
| 2 | Allow frontend to backend | Ingress | `10.0.1.0/24` | `10.0.2.0/24`, port 443/8080 | Allow | 1100 |
| 3 | Deny all ingress to backend | Ingress | `0.0.0.0/0` | `10.0.2.0/24` | Deny | 2000 |
| 4 | Allow backend to Google APIs | Egress | Backend SA | `199.36.153.8/30`, port 443 | Allow | 1000 |
| 5 | Allow backend to frontend (return) | Egress | Backend SA | `10.0.1.0/24` | Allow | 1100 |
| 6 | Allow backend HTTPS egress (NAT) | Egress | Backend SA | `0.0.0.0/0`, port 443 | Allow | 1500 |
| 7 | Deny all other backend egress | Egress | Backend SA | `0.0.0.0/0` | Deny | 2000 |

### 5.6 Additional Security Controls

- **Input Validation:** Strict input validation and sanitization must be enforced on the `/run_sse` endpoint to prevent prompt injection and enforce maximum payload sizes. All external inputs must be treated as untrustworthy.
- **Data Protection:** Ensure sensitive data and PII are scrubbed before payloads are routed to Cloud Logging or BigQuery.
- **Cloud Armor (WAF):** Attach a Cloud Armor security policy to the frontend load balancer with OWASP ModSecurity Core Rule Set to mitigate injection attacks, XSS, and L7 DDoS.
- **TLS everywhere:** Cloud Run enforces TLS termination. Internal traffic between frontend and backend also uses HTTPS (Cloud Run-to-Cloud Run).
- **Secret management:** GitHub PAT and other secrets are stored in Secret Manager, referenced by resource ID in Terraform, never in code.
- **Container security:** Images are built in CI/CD, stored in Artifact Registry with vulnerability scanning enabled, and deployed via image digest.

---

## 6. Data Flow

### 6.1 Chat Request Flow

```
User --> [HTTPS] --> Cloud LB --> Frontend (Cloud Run, public)
  |      [Graceful Fallbacks: Frontend displays 
  |       "temporarily unavailable" on 429/5xx errors]
  |
  +--> [HTTPS + ID Token] --> Direct VPC Egress --> Backend (Cloud Run, private)
         |
         +--> ADK Agent processes message
         |      |
         |      +--> [Tool call] get_weather() or get_current_time()
         |      |
         |      +--> [gRPC/HTTPS] Vertex AI Gemini API (Private Google Access)
         |
         +--> SSE stream response back to frontend
               |
               +--> Frontend renders streamed tokens to user
```

### 6.2 Feedback Flow

```
User clicks thumbs-up/down --> Frontend POST /feedback
  --> Backend logs to Cloud Logging (structured JSON)
    --> Log sink routes to dedicated Cloud Logging bucket (10-year retention)
      --> Linked BigQuery dataset for analytics
```

### 6.3 Telemetry Flow

```
Backend ADK Agent invokes Gemini
  --> OpenTelemetry GenAI instrumentation captures metadata
    --> Completion data (JSONL) uploaded to GCS bucket
    --> Traces exported to Cloud Trace
    --> Logs exported to Cloud Logging
      --> Log sink routes GenAI logs to dedicated logging bucket
        --> BigQuery external table over GCS data
        --> BigQuery linked dataset over Cloud Logging bucket
          --> Completions view joins both for full observability
```

---

## 7. Infrastructure and Deployment

### 7.1 Environment Strategy

The system uses three GCP projects for isolation:

| Environment | Project | Purpose |
|-------------|---------|---------|
| **CI/CD** | `cicd_runner_project_id` | Cloud Build pipelines, Artifact Registry, build logs |
| **Staging** | `staging_project_id` | Pre-production validation, load testing |
| **Production** | `prod_project_id` | Live user traffic |

### 7.2 Terraform-Managed Resources

All infrastructure is defined in `deployment/terraform/`:

| Resource | File | Description |
|----------|------|-------------|
| Cloud Run services | `service.tf` | Backend (4 vCPU, 8Gi, INTERNAL_ONLY) + Frontend (1 vCPU, 512Mi, INTERNAL_LOAD_BALANCER) with Direct VPC Egress |
| VPC + Subnets | `network.tf` | Custom VPC, frontend subnet (10.0.1.0/24), backend subnet (10.0.2.0/24), Private DNS, Cloud Router, Cloud NAT |
| Firewall rules | `firewall.tf` | 7 rules: ingress controls, egress allow/deny, Google API access |
| Load balancer | `loadbalancer.tf` | Global HTTPS LB, Cloud Armor WAF, managed SSL cert, HTTP redirect |
| Service accounts | `service_accounts.tf` | App SA, Frontend SA (per-env), and CI/CD SA |
| IAM bindings | `iam.tf` | Least-privilege roles for app, frontend, and CI/CD SAs; frontend->backend invoker |
| GCS buckets | `storage.tf` | Logs/artifacts bucket per project; Artifact Registry for Docker images |
| BigQuery | `telemetry.tf` | Telemetry dataset, GCS connection, external tables, completions view |
| Cloud Logging | `telemetry.tf` | Dedicated logging bucket (10yr retention), log sinks, linked datasets |
| Cloud Build triggers | `build_triggers.tf` | PR checks, CD pipeline, production deploy triggers |
| GitHub connection | `github.tf` | Cloud Build V2 GitHub connection and repository link |
| Google APIs | `apis.tf` | Enables required APIs per project |

### 7.3 Cloud Run Configuration

```
Backend Service:
  CPU:           4 vCPU (always-on, no CPU throttling)
  Memory:        8 Gi
  Concurrency:   40 requests per instance
  Min instances: 1 (avoid cold starts)
  Max instances: 10
  Ingress:       INGRESS_TRAFFIC_INTERNAL_ONLY
  VPC Egress:    ALL_TRAFFIC via backend-subnet (10.0.2.0/24)
  Auth:          --no-allow-unauthenticated
  Session:       Affinity enabled

Frontend Service:
  CPU:           1 vCPU
  Memory:        512 Mi
  Ingress:       INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER
  VPC Egress:    PRIVATE_RANGES_ONLY via frontend-subnet (10.0.1.0/24)
  Auth:          allUsers (public via LB only)
```

### 7.4 Deployment Commands

| Command | Description |
|---------|-------------|
| `make deploy` | Deploy backend to Cloud Run (dev project) via `gcloud run deploy` |
| `make deploy-frontend` | Deploy frontend to Cloud Run (dev project) |
| `make local-backend` | Launch local backend server with hot-reload |
| `make local-frontend` | Launch local frontend chatbot UI (connects to local backend) |
| `make setup-dev-env` | Apply dev Terraform configuration |
| `uvx agent-starter-pack setup-cicd` | Full CI/CD pipeline + infrastructure setup |

---

## 8. Observability

### 8.1 Telemetry Stack

| Signal | Destination | Retention |
|--------|-------------|-----------|
| Traces | Cloud Trace | Default (30 days) |
| GenAI completions (JSONL) | GCS bucket (`{project}-{name}-logs/completions/`) | Bucket lifecycle policy |
| GenAI inference logs | Cloud Logging dedicated bucket | 10 years |
| Feedback logs | Cloud Logging dedicated bucket | 10 years |
| Structured logs | Cloud Logging (default) | 30 days |

### 8.2 BigQuery Analytics

Two queryable surfaces are provisioned per environment:

1. **`completions` external table** - Direct query over GCS-stored JSONL completion data (messages, parts, roles).
2. **`completions_view`** - Joins Cloud Logging inference metadata with GCS completion data for full request tracing.

### 8.3 Content Capture Policy

By default, prompt/response content capture is set to `NO_CONTENT` (metadata only). This ensures no user prompts or model responses are stored in telemetry, balancing observability with data privacy. To enable full content capture, set `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` to `true`.

### 8.4 Alerting & Incident Response

To ensure Operational Excellence, the following Cloud Monitoring Alert Policies must be configured:
- **High Error Rates:** Trigger severity alerts when backend Cloud Run 5xx error rates exceed threshold boundaries.
- **Latency Spikes:** Trigger alerts when P99 Latency > 2s to track degraded agent performance.
- **Quota Warnings:** Trigger proactive alerts upon approaching Vertex AI Quota exhaustion limits (Tokens Per Minute / Requests Per Minute).

---

## 9. Testing Strategy

### 9.1 Test Layers

| Layer | Location | Runner | Description |
|-------|----------|--------|-------------|
| Unit tests | `tests/unit/` | `pytest` | Isolated component tests |
| Integration tests (agent) | `tests/integration/test_agent.py` | `pytest` | Tests agent streaming via ADK `Runner` with in-memory sessions |
| Integration tests (server) | `tests/integration/test_server_e2e.py` | `pytest` | Spins up full FastAPI server, tests `/run_sse`, error handling, and `/feedback` |
| Load tests | `tests/load_test/load_test.py` | `locust` | Simulates concurrent users hitting `/run_sse` with session creation |
| Evaluation | `tests/eval/` | `adk eval` | LLM-as-judge evaluation against `evalsets/*.evalset.json` |

### 9.2 Key Test Cases

- **`test_agent_stream`** - Verifies the agent returns at least one SSE event with text content for a freeform question.
- **`test_chat_stream`** - End-to-end: creates a session, sends a message via `/run_sse`, asserts SSE events contain text.
- **`test_chat_stream_error_handling`** - Sends malformed input, expects HTTP 422.
- **`test_collect_feedback`** - Posts feedback, expects HTTP 200.
- **Load test** - 10 concurrent users over 30s with 0.5 users/sec ramp-up. Monitors for 429 rate limits and error codes in SSE payloads.

---

## 10. CI/CD Pipeline

### 10.1 Pipeline Overview

```
  PR Created/Updated                Push to main                   Manual Approval
        |                               |                               |
        v                               v                               v
+----------------+          +-----------------------------+       +---------------------+
| PR Checks      |          | CD Pipeline                 |       | Deploy to Prod      |
| (pr_checks.yaml)|         | (staging.yaml)              |       | (deploy-to-prod)    |
+----------------+          +-----------------------------+       +---------------------+
| 1. Install deps|          | 1. Docker build + push      |       | 1. Deploy backend   |
| 2. Unit tests  |          |    (backend + frontend)     |       |    image to Prod CR |
| 3. Integration |          | 2. Deploy backend to Staging|       | 2. Deploy frontend  |
|    tests       |          | 3. Deploy frontend to       |       |    image to Prod CR |
+----------------+          |    Staging                  |       +---------------------+
                            | 4. Load test (Locust)       |
                            | 5. Export results to GCS    |
                            | 6. Trigger prod deploy      |
                            +-----------------------------+
```

### 10.2 Trigger Configuration

| Trigger | Event | Branch | Files | Approval |
|---------|-------|--------|-------|----------|
| `pr-{name}` | Pull request | `main` | `backend/`, `frontend/`, `tests/`, `deployment/`, `uv.lock` | No |
| `cd-{name}` | Push | `main` | `backend/`, `frontend/`, `tests/`, `deployment/`, `uv.lock` | No |
| `deploy-{name}` | Manual (triggered by CD) | Any | All | Yes (required) |

### 10.3 Security in CI/CD

- Build and deploy use a dedicated CI/CD service account (`{name}-cb`) with narrowly scoped IAM roles.
- CI/CD SA can deploy to staging and production but cannot access application data.
- Production deployment requires explicit human approval via Cloud Build approval config.
- Build logs are stored in a project-owned GCS bucket (not the default Cloud Build bucket).
- Container images are pushed to a private Artifact Registry repository.
- **Stale Artifact Cleanup:** Implement lifecycle policies to clean up stale artifacts in Artifact Registry and old inactive Cloud Run revisions to minimize attack surfaces and reduce costs.

---

## Appendix A: Environment Variables

| Variable | Description | Set By |
|----------|-------------|--------|
| `LOGS_BUCKET_NAME` | GCS bucket for telemetry/artifacts | Terraform (env var on Cloud Run) |
| `ALLOW_ORIGINS` | Comma-separated CORS origins | Deployment config |
| `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` | Content capture mode (`NO_CONTENT` / `true`) | Terraform |
| `COMMIT_SHA` | Git commit SHA for tracing | Cloud Build substitution |
| `GOOGLE_CLOUD_PROJECT` | GCP project ID | Auto-detected via `google.auth.default()` |
| `GOOGLE_CLOUD_LOCATION` | API location (`global`) | Set in `agent.py` |
| `GOOGLE_GENAI_USE_VERTEXAI` | Route GenAI calls through Vertex AI | Set in `agent.py` |
| `BACKEND_URL` | Backend Cloud Run service URL (frontend only) | Terraform (env var on frontend Cloud Run) |

## Appendix B: File Structure

```
agent-starter-adk-cr/
|-- backend/
|   |-- __init__.py
|   |-- agent.py                  # ADK agent definition (root_agent + tools)
|   |-- fast_api_app.py           # FastAPI server with SSE + feedback endpoints
|   +-- app_utils/
|       |-- telemetry.py          # OpenTelemetry GenAI configuration
|       +-- typing.py             # Pydantic models (Request, Feedback)
|-- frontend/
|   |-- server.py                 # FastAPI proxy with OIDC auth for backend calls
|   |-- Dockerfile                # Frontend container image
|   +-- static/
|       |-- index.html            # Chat UI shell
|       |-- style.css             # Responsive chat styling
|       +-- app.js                # SSE streaming, session mgmt, feedback
|-- .cloudbuild/
|   |-- pr_checks.yaml            # PR validation pipeline
|   |-- staging.yaml              # Build, deploy to staging, load test
|   +-- deploy-to-prod.yaml       # Production deployment (approval-gated)
|-- deployment/
|   +-- terraform/
|       |-- service.tf            # Cloud Run services (backend + frontend)
|       |-- network.tf            # VPC, subnets, DNS, Cloud Router, Cloud NAT
|       |-- firewall.tf           # 7 firewall rules (ingress/egress controls)
|       |-- loadbalancer.tf       # HTTPS LB, Cloud Armor WAF, SSL cert, NEG
|       |-- service_accounts.tf   # App SA, Frontend SA, CI/CD SA
|       |-- iam.tf                # IAM role bindings (app, frontend, CI/CD)
|       |-- storage.tf            # GCS buckets + Artifact Registry
|       |-- telemetry.tf          # BigQuery + Cloud Logging telemetry infra
|       |-- build_triggers.tf     # Cloud Build trigger definitions
|       |-- github.tf             # GitHub connection for Cloud Build
|       |-- apis.tf               # Google API enablement
|       |-- locals.tf             # Shared locals (project IDs, service lists)
|       |-- variables.tf          # Input variables
|       |-- providers.tf          # Provider configuration
|       +-- dev/                  # Dev environment Terraform config
|-- tests/
|   |-- unit/                     # Unit tests
|   |-- integration/              # Integration + E2E server tests
|   |-- load_test/                # Locust load tests
|   +-- eval/                     # ADK evaluation framework
|-- pyproject.toml                # Dependencies, tooling config
|-- Makefile                      # Developer commands
|-- GEMINI.md                     # AI-assisted development guide
+-- docs/
    |-- sdd.md                    # This document
    |-- network.md                # Network architecture overview
    +-- network_security.md       # Implementation-level security detail (Terraform snippets)
```
