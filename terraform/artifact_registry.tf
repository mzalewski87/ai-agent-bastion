resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = var.artifact_repo_name
  description   = "Container registry for AI Agent Bastion and Prisma AIRS demo workloads"
  format        = "DOCKER"

  depends_on = [google_project_service.enabled_apis]
}
