output "gcp_project_id" {
  description = "Google Cloud Project ID"
  value       = var.project_id
}

output "gke_cluster_name" {
  description = "Private GKE cluster name"
  value       = google_container_cluster.primary.name
}

output "gke_cluster_zone" {
  description = "GKE cluster zone"
  value       = google_container_cluster.primary.location
}

output "artifact_registry_image_url" {
  description = "Full Artifact Registry image URL for Cloud Build"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}/ai-agent-bastion:${var.app_image_tag}"
}

output "redis_host" {
  description = "Memorystore for Redis private IP address"
  value       = google_redis_instance.airs_gw_cache.host
}

output "redis_port" {
  description = "Memorystore for Redis port"
  value       = google_redis_instance.airs_gw_cache.port
}

output "agent_workload_identity_sa" {
  description = "GCP IAM Service Account bound to the AI Agent pod via Workload Identity"
  value       = google_service_account.agent_workload_sa.email
}

output "cloud_build_command" {
  description = "Command to build and push the application container image via Google Cloud Build"
  value       = "gcloud builds submit ../app --tag ${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}/ai-agent-bastion:${var.app_image_tag} --project ${var.project_id}"
}

output "tunnel_launch_command_macos_linux" {
  description = "Command to launch the local kubectl port-forward tunnel on macOS/Linux"
  value       = "GCP_PROJECT_ID=${var.project_id} ../app/start_k8s_tunnel_mac.sh"
}
