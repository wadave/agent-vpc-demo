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
# Backend Cloud Run Service
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "backend" {
  for_each = local.deploy_project_ids

  name                = "${var.project_name}-backend"
  location            = var.region
  project             = each.value
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  labels              = local.common_labels

  template {
    containers {
      image = local.placeholder_image
      resources {
        limits   = { cpu = var.backend_cpu, memory = var.backend_memory }
        cpu_idle = false
      }
      env {
        name  = "LOGS_BUCKET_NAME"
        value = google_storage_bucket.logs_data_bucket[each.value].name
      }
      env {
        name  = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"
        value = "NO_CONTENT"
      }
    }

    service_account                  = google_service_account.app_sa[each.key].email
    max_instance_request_concurrency = var.backend_concurrency

    scaling {
      min_instance_count = var.backend_min_instances
      max_instance_count = var.backend_max_instances
    }

    # Direct VPC Egress
    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        network    = google_compute_network.vpc[each.key].name
        subnetwork = google_compute_subnetwork.backend[each.key].name
      }
    }

    session_affinity = true
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.deploy_project_services,
    google_compute_subnetwork.backend,
  ]
}

# ------------------------------------------------------------------------------
# Frontend Cloud Run Service
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "frontend" {
  for_each = local.deploy_project_ids

  name                = "${var.project_name}-frontend"
  location            = var.region
  project             = each.value
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  labels              = local.common_labels

  template {
    containers {
      image = local.placeholder_image
      resources {
        limits = { cpu = "1", memory = "512Mi" }
      }
      env {
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.backend[each.key].uri
      }
    }

    service_account = google_service_account.frontend_sa[each.key].email

    # Direct VPC Egress
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = google_compute_network.vpc[each.key].name
        subnetwork = google_compute_subnetwork.frontend[each.key].name
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.deploy_project_services,
    google_compute_subnetwork.frontend,
  ]
}
