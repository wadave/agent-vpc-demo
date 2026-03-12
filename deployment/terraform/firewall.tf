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

# ==============================================================================
# Firewall Rules
#
# With Direct VPC Egress, Cloud Run instances have real IPs from their subnets.
# These firewall rules apply directly to those instances.
# ==============================================================================

# --- Rule 1: Allow HTTPS ingress to frontend subnet ---
# For Load Balancer health checks and external traffic
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

  source_ranges      = ["0.0.0.0/0"]
  destination_ranges = [var.frontend_subnet_cidr]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# --- Rule 2: Allow frontend subnet to reach backend subnet ---
# Frontend Cloud Run instances call backend over HTTPS.
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

  source_ranges      = [var.frontend_subnet_cidr]
  destination_ranges = [var.backend_subnet_cidr]

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
  destination_ranges = [var.backend_subnet_cidr]

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

  destination_ranges      = local.private_google_access_cidrs
  target_service_accounts = [google_service_account.app_sa[each.key].email]
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

  destination_ranges      = [var.frontend_subnet_cidr]
  target_service_accounts = [google_service_account.app_sa[each.key].email]
}

# --- Rule 6: Allow HTTPS egress to internet via Cloud NAT ---
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

  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.app_sa[each.key].email]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
