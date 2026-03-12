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

locals {
  cicd_services = [
    "cloudbuild.googleapis.com",
    "aiplatform.googleapis.com",
    "serviceusage.googleapis.com",
    "bigquery.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudtrace.googleapis.com",
    "telemetry.googleapis.com",
  ]

  deploy_project_services = [
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "bigquery.googleapis.com",
    "serviceusage.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
    "telemetry.googleapis.com",
  ]

  deploy_project_ids = {
    prod    = var.prod_project_id
    staging = var.staging_project_id
  }

  all_project_ids = [
    var.cicd_runner_project_id,
    var.prod_project_id,
    var.staging_project_id
  ]

  # Shared constants
  private_google_access_cidrs = ["199.36.153.8/30"]
  private_google_access_ips   = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]

  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello"

  common_labels = {
    "created-by"   = "adk"
    "project-name" = var.project_name
  }

  # Build trigger repository path (used by all 3 triggers)
  cb_repository = "projects/${var.cicd_runner_project_id}/locations/${var.region}/connections/${var.host_connection_name}/repositories/${var.repository_name}"

  # Common included_files for build triggers
  trigger_included_files = [
    "backend/**",
    "frontend/**",
    "data_ingestion/**",
    "tests/**",
    "deployment/**",
    "uv.lock",
  ]

  # Common depends_on for resources that need APIs enabled
  common_depends_on = [
    google_project_service.cicd_services,
    google_project_service.deploy_project_services,
  ]
}

