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

resource "google_compute_network" "vpc" {
  for_each = local.deploy_project_ids

  name                    = "${var.project_name}-vpc"
  project                 = each.value
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.deploy_project_services]
}

# --- Public subnet (frontend) ---
resource "google_compute_subnetwork" "frontend" {
  for_each = local.deploy_project_ids

  name                     = "${var.project_name}-frontend"
  project                  = each.value
  region                   = var.region
  network                  = google_compute_network.vpc[each.key].id
  ip_cidr_range            = var.frontend_subnet_cidr
  private_ip_google_access = true
}

# --- Private subnet (backend) ---
resource "google_compute_subnetwork" "backend" {
  for_each = local.deploy_project_ids

  name                     = "${var.project_name}-backend"
  project                  = each.value
  region                   = var.region
  network                  = google_compute_network.vpc[each.key].id
  ip_cidr_range            = var.backend_subnet_cidr
  private_ip_google_access = true
}

# Private DNS zone for googleapis.com to route API traffic internally
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

  depends_on = [google_project_service.deploy_project_services]
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
  rrdatas      = local.private_google_access_ips
}

# ------------------------------------------------------------------------------
# Cloud Router (required for Cloud NAT)
# ------------------------------------------------------------------------------
resource "google_compute_router" "router" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-router"
  project = each.value
  region  = var.region
  network = google_compute_network.vpc[each.key].id
}

# ------------------------------------------------------------------------------
# Cloud NAT — gives the backend subnet controlled outbound internet access
# ------------------------------------------------------------------------------
resource "google_compute_router_nat" "nat" {
  for_each = local.deploy_project_ids

  name                               = "${var.project_name}-nat"
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
