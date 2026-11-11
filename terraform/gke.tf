# Dedicated GCP Service Account for GKE nodes
resource "google_service_account" "gke_nodes_sa" {
  account_id   = "${var.cluster_name}-nodes-sa"
  display_name = "GKE Worker Nodes Service Account (${var.cluster_name})"
  depends_on   = [google_project_service.enabled_apis]
}

locals {
  node_sa_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ]
}

resource "google_project_iam_member" "gke_nodes_roles" {
  for_each = toset(local.node_sa_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gke_nodes_sa.email}"
}

# Dedicated GCP Service Account for the AI Agent Pod via GKE Workload Identity
resource "google_service_account" "agent_workload_sa" {
  account_id   = "agent-bastion-sa"
  display_name = "AI Agent Bastion AI Agent Workload Identity SA (Vertex AI)"
  depends_on   = [google_project_service.enabled_apis]
}

resource "google_project_iam_member" "agent_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.agent_workload_sa.email}"
}

# Private GKE Cluster (Zero External LoadBalancer Exposure)
resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = var.zone
  network                  = google_compute_network.vpc.id
  subnetwork               = google_compute_subnetwork.gke_subnet.id
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods-range"
    services_secondary_range_name = "gke-services-range"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    http_load_balancing {
      disabled = true
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [
    google_project_service.enabled_apis,
    google_compute_router_nat.nat,
  ]
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = var.gke_node_count

  node_config {
    machine_type    = var.gke_machine_type
    disk_size_gb    = 50
    disk_type       = "pd-balanced"
    service_account = google_service_account.gke_nodes_sa.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = {
      environment = "ai-agent-bastion"
    }
  }
}

# Bind Kubernetes ServiceAccount (ai-agent-bastion/agent-bastion-sa) to GCP Service Account
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.agent_workload_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[ai-agent-bastion/agent-bastion-sa]"

  depends_on = [google_container_cluster.primary]
}
