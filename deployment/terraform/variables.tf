# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

variable "project_name" {
  type        = string
  description = "Project name used as a base for resource naming"
  default     = "agent-starter-adk-cr"
}

variable "prod_project_id" {
  type        = string
  description = "**Production** Google Cloud Project ID for resource deployment."
}

variable "staging_project_id" {
  type        = string
  description = "**Staging** Google Cloud Project ID for resource deployment."
}

variable "cicd_runner_project_id" {
  type        = string
  description = "Google Cloud Project ID where CI/CD pipelines will execute."
}

variable "region" {
  type        = string
  description = "Google Cloud region for resource deployment."
  default     = "us-central1"
}

variable "host_connection_name" {
  description = "Name of the host connection to create in Cloud Build"
  type        = string
  default     = "agent-starter-adk-cr-github-connection"
}

variable "repository_name" {
  description = "Name of the repository you'd like to connect to Cloud Build"
  type        = string
}

variable "app_sa_roles" {
  description = "List of roles to assign to the application service account"
  type        = list(string)
  default = [

    "roles/aiplatform.user",
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
    "roles/storage.admin",
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

variable "cicd_roles" {
  description = "List of roles to assign to the CICD runner service account in the CICD project"
  type        = list(string)
  default = [
    "roles/run.invoker",
    "roles/storage.admin",
    "roles/aiplatform.user",
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
    "roles/artifactregistry.writer",
    "roles/cloudbuild.builds.builder"
  ]
}

variable "cicd_sa_deployment_required_roles" {
  description = "List of roles to assign to the CICD runner service account for the Staging and Prod projects."
  type        = list(string)
  default = [
    "roles/run.developer",
    "roles/iam.serviceAccountUser",
    "roles/aiplatform.user",
    "roles/storage.admin"
  ]
}

variable "repository_owner" {
  description = "Owner of the Git repository - username or organization"
  type        = string
}


variable "github_app_installation_id" {
  description = "GitHub App Installation ID for Cloud Build"
  type        = string
  default     = null
}


variable "github_pat_secret_id" {
  description = "GitHub PAT Secret ID created by gcloud CLI"
  type        = string
  default     = null
}

variable "create_cb_connection" {
  description = "Flag indicating if a Cloud Build connection already exists"
  type        = bool
  default     = false
}

variable "create_repository" {
  description = "Flag indicating whether to create a new Git repository"
  type        = bool
  default     = false
}


variable "frontend_sa_roles" {
  description = "Roles for the frontend service account"
  type        = list(string)
  default = [
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
  ]
}

variable "frontend_subnet_cidr" {
  description = "CIDR range for the frontend subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "backend_subnet_cidr" {
  description = "CIDR range for the backend subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "backend_cpu" {
  description = "CPU limit for backend Cloud Run instances"
  type        = string
  default     = "4"
}

variable "backend_memory" {
  description = "Memory limit for backend Cloud Run instances"
  type        = string
  default     = "8Gi"
}

variable "backend_min_instances" {
  description = "Minimum number of backend Cloud Run instances"
  type        = number
  default     = 1
}

variable "backend_max_instances" {
  description = "Maximum number of backend Cloud Run instances"
  type        = number
  default     = 10
}

variable "backend_concurrency" {
  description = "Maximum concurrent requests per backend instance"
  type        = number
  default     = 40
}

variable "default_branch" {
  description = "Default branch name for build triggers"
  type        = string
  default     = "main"
}

variable "frontend_domain" {
  description = "Domain name for the frontend HTTPS load balancer (per environment)"
  type        = map(string)
  # Example: { prod = "agent.example.com", staging = "agent-staging.example.com" }
}

variable "feedback_logs_filter" {
  type        = string
  description = "Log Sink filter for capturing feedback data. Captures logs where the `log_type` field is `feedback`."
  default     = "jsonPayload.log_type=\"feedback\" jsonPayload.service_name=\"agent-starter-adk-cr\""
}

