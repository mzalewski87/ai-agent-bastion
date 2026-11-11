# 1. Namespaces
resource "kubernetes_namespace" "demo_ns" {
  metadata {
    name = "ai-agent-bastion"
    labels = {
      "app.kubernetes.io/part-of"            = "panw-airs-gcp-k8s"
      "security.paloaltonetworks.com/mode" = "api-gateway-live"
    }
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

resource "kubernetes_namespace" "airs_gw_ns" {
  metadata {
    name = "airs-gw"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

resource "kubernetes_namespace" "airs_redteam_ns" {
  metadata {
    name = "airs-redteam"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

# 2. Workload Identity Kubernetes ServiceAccount
resource "kubernetes_service_account" "agent_sa" {
  metadata {
    name      = "agent-bastion-sa"
    namespace = kubernetes_namespace.demo_ns.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.agent_workload_sa.email
    }
  }
}

# 3. ConfigMap with non-sensitive runtime configuration
resource "kubernetes_config_map" "demo_env" {
  metadata {
    name      = "agent-bastion-env"
    namespace = kubernetes_namespace.demo_ns.metadata[0].name
  }

  data = {
    GCP_PROJECT_ID             = var.project_id
    GCP_LOCATION               = "global"
    VERTEX_AI_MODEL            = var.vertex_ai_model
    AIRS_API_ENDPOINT          = "https://service.api.aisecurity.paloaltonetworks.com"
    AIRS_SECURITY_PROFILE_NAME = var.airs_security_profile_name
    PORTKEY_GATEWAY_URL_LOCAL  = "http://airs-gw.airs-gw.svc.cluster.local/v1"
    PORTKEY_GATEWAY_URL_CLOUD  = "https://aigw.portkey.ai/v1"
    PORTKEY_GATEWAY_URL        = "http://airs-gw.airs-gw.svc.cluster.local/v1"
    PORTKEY_CONFIG             = ""
    PORTKEY_PROVIDER           = var.portkey_provider
    GW_MODEL                   = var.gw_model
    REDIS_HOST                 = google_redis_instance.airs_gw_cache.host
    REDIS_PORT                 = tostring(google_redis_instance.airs_gw_cache.port)
    REDTEAM_CHANNEL_UUID       = var.redteam_channel_uuid
    REDTEAM_TARGET_1_UUID      = var.redteam_target_1_uuid
    REDTEAM_TARGET_2_UUID      = var.redteam_target_2_uuid
    REDTEAM_TARGET_3_UUID      = var.redteam_target_3_uuid
    DOCUMENTS_DIR              = "/app/documents"
    SEED_DOCUMENTS_DIR         = "/app/seed-documents"
  }
}

# 4. Kubernetes Secret with API keys and SCM OAuth2 credentials
resource "kubernetes_secret" "airs_credentials" {
  metadata {
    name      = "prisma-airs-credentials"
    namespace = kubernetes_namespace.demo_ns.metadata[0].name
  }

  type = "Opaque"

  data = {
    AIRS_API_KEY               = var.airs_api_key
    AIRS_SECURITY_PROFILE_NAME = var.airs_security_profile_name
    PORTKEY_API_KEY            = var.portkey_api_key
    REDTEAM_CLIENT_ID          = var.redteam_client_id
    REDTEAM_CLIENT_SECRET      = var.redteam_client_secret
    REDTEAM_TSG_ID             = var.redteam_tsg_id
  }
}

# 5. AI Agent Bastion Deployment
resource "kubernetes_deployment" "live_range" {
  metadata {
    name      = "ai-agent-bastion"
    namespace = kubernetes_namespace.demo_ns.metadata[0].name
    labels = {
      app = "ai-agent-bastion"
    }
  }

  wait_for_rollout = false

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "ai-agent-bastion"
      }
    }

    template {
      metadata {
        labels = {
          app = "ai-agent-bastion"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.agent_sa.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
        }

        container {
          name              = "live-range"
          image             = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/ai-agent-bastion:${var.app_image_tag}"
          image_pull_policy = "Always"

          port {
            name           = "http"
            container_port = 5050
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.demo_env.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.airs_credentials.metadata[0].name
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 5050
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 5050
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

# 6. Internal ClusterIP Service (Zero External Exposure)
resource "kubernetes_service" "live_range_svc" {
  metadata {
    name      = "ai-agent-bastion-svc"
    namespace = kubernetes_namespace.demo_ns.metadata[0].name
    labels = {
      app = "ai-agent-bastion"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "ai-agent-bastion"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 5050
      protocol    = "TCP"
    }
  }
}

# 7. Optional Helm Release: Palo Alto Networks AI Red Teaming Network Broker (panw-network-client)
resource "helm_release" "panw_network_client" {
  count      = var.deploy_helm_redteam_broker ? 1 : 0
  name       = "panw-network-client"
  namespace  = kubernetes_namespace.airs_redteam_ns.metadata[0].name
  repository = "oci://us-docker.pkg.dev/palo-alto-networks-ai-sec-pub/ai-red-teaming-helm"
  chart      = "panw-network-client"
  version    = "1.10.0"

  set {
    name  = "replicaCount"
    value = "2"
  }

  set {
    name  = "config.channelId"
    value = var.redteam_channel_uuid
  }

  set {
    name  = "config.tsgId"
    value = var.redteam_tsg_id
  }

  set {
    name  = "config.authUrl"
    value = "https://auth.apps.paloaltonetworks.com/oauth2/access_token"
  }

  set {
    name  = "config.serverUrl"
    value = "wss://api.sase.paloaltonetworks.com/ai-red-teaming/data-plane/network-broker/v1/tunnel"
  }

  set_sensitive {
    name  = "credentials.clientId"
    value = var.redteam_client_id
  }

  set_sensitive {
    name  = "credentials.clientSecret"
    value = var.redteam_client_secret
  }
}

# 8. Optional Helm Release: Local Prisma AIRS AI Gateway (Portkey Enterprise)
resource "helm_release" "airs_gateway" {
  count      = var.deploy_helm_airs_gateway ? 1 : 0
  name       = "airs-gw"
  namespace  = kubernetes_namespace.airs_gw_ns.metadata[0].name
  repository = "https://portkey-ai.github.io/helm"
  chart      = "enterprise"

  values = [
    yamlencode({
      imageCredentials = [
        {
          name     = "airsgatewayregistrycredentials"
          create   = true
          registry = "https://registry.portkey.ai"
          username = var.redteam_tsg_id
          password = var.portkey_registry_password
          email    = ""
        }
      ]
      environment = {
        create = true
        secret = true
        data = {
          PORTKEY_CLIENT_AUTH   = var.portkey_client_auth
          ORGANISATIONS_TO_SYNC = var.portkey_organisation_id
          PORT                  = "8787"
        }
      }
      service = {
        type          = "ClusterIP"
        port          = 80
        containerPort = 8787
      }
      redis = {
        external = {
          enabled       = true
          connectionUrl = "redis://${google_redis_instance.airs_gw_cache.host}:${google_redis_instance.airs_gw_cache.port}"
          tlsEnabled    = "false"
          mode          = "standalone"
          store         = "redis"
        }
      }
    })
  ]
}
