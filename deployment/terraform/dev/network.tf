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
  private_google_access_cidrs = ["199.36.153.8/30"]
  private_google_access_ips   = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}

# ==============================================================================
# VPC
# ==============================================================================
resource "google_compute_network" "vpc" {
  name                    = "${var.project_name}-vpc"
  project                 = var.dev_project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.services]
}

# --- Public subnet (frontend) ---
resource "google_compute_subnetwork" "frontend" {
  name                     = "${var.project_name}-frontend"
  project                  = var.dev_project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.frontend_subnet_cidr
  private_ip_google_access = true
}

# --- Private subnet (backend) ---
resource "google_compute_subnetwork" "backend" {
  name                     = "${var.project_name}-backend"
  project                  = var.dev_project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.backend_subnet_cidr
  private_ip_google_access = true
}

# ==============================================================================
# Private DNS for Google APIs
# ==============================================================================
resource "google_dns_managed_zone" "googleapis" {
  name        = "googleapis-private"
  project     = var.dev_project_id
  dns_name    = "googleapis.com."
  description = "Private DNS zone for Google APIs"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }

  depends_on = [google_project_service.services]
}

resource "google_dns_record_set" "googleapis_cname" {
  name         = "*.googleapis.com."
  project      = var.dev_project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["private.googleapis.com."]
}

resource "google_dns_record_set" "private_googleapis_a" {
  name         = "private.googleapis.com."
  project      = var.dev_project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  type         = "A"
  ttl          = 300
  rrdatas      = local.private_google_access_ips
}

# ==============================================================================
# Cloud Router + Cloud NAT (backend subnet only)
# ==============================================================================
resource "google_compute_router" "router" {
  name    = "${var.project_name}-router"
  project = var.dev_project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.project_name}-nat"
  project                            = var.dev_project_id
  region                             = var.region
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.backend.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
