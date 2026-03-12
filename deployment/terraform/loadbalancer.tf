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

# ------------------------------------------------------------------------------
# Cloud Armor Security Policy (WAF)
# ------------------------------------------------------------------------------
resource "google_compute_security_policy" "frontend_waf" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-waf"
  project = each.value

  # Default rule: allow traffic
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

  # Rate limiting rule
  rule {
    action   = "rate_based_ban"
    priority = 1000
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
      ban_duration_sec = 300
    }
    description = "Rate limit: 100 requests/min per IP"
  }

  # OWASP ModSecurity Core Rule Set
  rule {
    action   = "deny(403)"
    priority = 2000
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection attacks"
  }

  rule {
    action   = "deny(403)"
    priority = 2001
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
    description = "Block XSS attacks"
  }
}

# ------------------------------------------------------------------------------
# Serverless NEG — points to the frontend Cloud Run service
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Backend Service (LB backend, not to be confused with the backend Cloud Run)
# ------------------------------------------------------------------------------
resource "google_compute_backend_service" "frontend_backend" {
  for_each = local.deploy_project_ids

  name                  = "${var.project_name}-frontend-backend"
  project               = each.value
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

# ------------------------------------------------------------------------------
# URL Map
# ------------------------------------------------------------------------------
resource "google_compute_url_map" "frontend" {
  for_each = local.deploy_project_ids

  name            = "${var.project_name}-url-map"
  project         = each.value
  default_service = google_compute_backend_service.frontend_backend[each.key].id
}

# ------------------------------------------------------------------------------
# Managed SSL Certificate
# ------------------------------------------------------------------------------
resource "google_compute_managed_ssl_certificate" "frontend" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-cert"
  project = each.value

  managed {
    domains = [var.frontend_domain[each.key]]
  }
}

# ------------------------------------------------------------------------------
# HTTPS Proxy
# ------------------------------------------------------------------------------
resource "google_compute_target_https_proxy" "frontend" {
  for_each = local.deploy_project_ids

  name             = "${var.project_name}-https-proxy"
  project          = each.value
  url_map          = google_compute_url_map.frontend[each.key].id
  ssl_certificates = [google_compute_managed_ssl_certificate.frontend[each.key].id]
}

# ------------------------------------------------------------------------------
# Global Static IP
# ------------------------------------------------------------------------------
resource "google_compute_global_address" "frontend" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-lb-ip"
  project = each.value
}

# ------------------------------------------------------------------------------
# Global Forwarding Rule (entry point)
# ------------------------------------------------------------------------------
resource "google_compute_global_forwarding_rule" "frontend_https" {
  for_each = local.deploy_project_ids

  name                  = "${var.project_name}-https-rule"
  project               = each.value
  target                = google_compute_target_https_proxy.frontend[each.key].id
  port_range            = "443"
  ip_address            = google_compute_global_address.frontend[each.key].id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# ------------------------------------------------------------------------------
# HTTP-to-HTTPS redirect
# ------------------------------------------------------------------------------
resource "google_compute_url_map" "frontend_redirect" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-http-redirect"
  project = each.value

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "frontend_redirect" {
  for_each = local.deploy_project_ids

  name    = "${var.project_name}-http-proxy"
  project = each.value
  url_map = google_compute_url_map.frontend_redirect[each.key].id
}

resource "google_compute_global_forwarding_rule" "frontend_http_redirect" {
  for_each = local.deploy_project_ids

  name                  = "${var.project_name}-http-redirect-rule"
  project               = each.value
  target                = google_compute_target_http_proxy.frontend_redirect[each.key].id
  port_range            = "80"
  ip_address            = google_compute_global_address.frontend[each.key].id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
