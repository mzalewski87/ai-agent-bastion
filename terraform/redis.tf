resource "google_redis_instance" "airs_gw_cache" {
  name               = "${var.cluster_name}-redis"
  tier               = "BASIC"
  memory_size_gb     = var.redis_memory_size_gb
  region             = var.region
  location_id        = var.zone
  authorized_network = google_compute_network.vpc.id
  redis_version      = "REDIS_7_0"
  display_name       = "Prisma AIRS AI Gateway State & Guardrail Cache"

  depends_on = [google_project_service.enabled_apis]
}
