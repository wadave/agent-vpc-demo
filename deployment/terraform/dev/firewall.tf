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

# --- Rule 1: Allow HTTPS ingress to frontend subnet ---
resource "google_compute_firewall" "allow_https_to_frontend" {
  name    = "allow-https-to-frontend"
  project = var.dev_project_id
  network = google_compute_network.vpc.id

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
resource "google_compute_firewall" "allow_frontend_to_backend" {
  name    = "allow-frontend-to-backend"
  project = var.dev_project_id
  network = google_compute_network.vpc.id

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
  name    = "deny-all-ingress-to-backend"
  project = var.dev_project_id
  network = google_compute_network.vpc.id

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

# --- Rule 4: Allow backend egress to Google APIs ---
resource "google_compute_firewall" "allow_backend_to_google_apis" {
  name    = "allow-backend-to-google-apis"
  project = var.dev_project_id
  network = google_compute_network.vpc.id

  priority  = 1000
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges      = local.private_google_access_cidrs
  target_service_accounts = [google_service_account.app_sa.email]
}

# --- Rule 5: Allow backend egress to frontend subnet (return traffic) ---
resource "google_compute_firewall" "allow_backend_to_frontend" {
  name    = "allow-backend-to-frontend-return"
  project = var.dev_project_id
  network = google_compute_network.vpc.id

  priority  = 1100
  direction = "EGRESS"

  allow {
    protocol = "tcp"
  }

  destination_ranges      = [var.frontend_subnet_cidr]
  target_service_accounts = [google_service_account.app_sa.email]
}

# --- Rule 6: Allow HTTPS egress to internet via Cloud NAT ---
resource "google_compute_firewall" "allow_backend_https_egress" {
  name    = "allow-backend-https-egress"
  project = var.dev_project_id
  network = google_compute_network.vpc.id

  priority  = 1500
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.app_sa.email]
}

# --- Rule 7: Deny all other internet egress from backend ---
resource "google_compute_firewall" "deny_internet_egress_from_backend" {
  name    = "deny-internet-egress-from-backend"
  project = var.dev_project_id
  network = google_compute_network.vpc.id

  priority  = 2000
  direction = "EGRESS"

  deny {
    protocol = "all"
  }

  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.app_sa.email]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
