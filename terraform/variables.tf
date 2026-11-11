variable "project_id" {
  description = "Google Cloud Project ID where GKE, Memorystore Redis, and Artifact Registry will be deployed."
  type        = string
}

variable "region" {
  description = "Google Cloud region for VPC, Memorystore Redis, and Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Google Cloud zone for the zonal GKE cluster."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the private GKE cluster."
  type        = string
  default     = "agent-bastion-gke"
}

variable "vpc_name" {
  description = "Name of the dedicated VPC network."
  type        = string
  default     = "agent-bastion-vpc"
}

variable "subnet_name" {
  description = "Name of the GKE subnet."
  type        = string
  default     = "agent-bastion-subnet"
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the GKE node subnet."
  type        = string
  default     = "10.20.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for GKE pods."
  type        = string
  default     = "10.24.0.0/14"
}

variable "services_cidr" {
  description = "Secondary CIDR range for GKE ClusterIP services."
  type        = string
  default     = "10.28.0.0/20"
}

variable "master_ipv4_cidr_block" {
  description = "CIDR block (/28) for the GKE private control plane."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  description = "List of authorized CIDR blocks allowed to reach the GKE control plane."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "Presenter-And-Conference-Access"
    }
  ]
}

variable "gke_machine_type" {
  description = "Compute Engine machine type for GKE worker nodes."
  type        = string
  default     = "e2-standard-4"
}

variable "gke_node_count" {
  description = "Number of worker nodes in the primary GKE node pool."
  type        = number
  default     = 2
}

variable "redis_memory_size_gb" {
  description = "Memory size (GiB) for Google Cloud Memorystore Redis instance."
  type        = number
  default     = 1
}

variable "artifact_repo_name" {
  description = "Name of the Artifact Registry Docker repository."
  type        = string
  default     = "agent-bastion-repo"
}

variable "app_image_tag" {
  description = "Container image tag for the AI Agent Bastion application."
  type        = string
  default     = "2026.11"
}

variable "vertex_ai_model" {
  description = "Default Vertex AI model used for direct agent calls."
  type        = string
  default     = "gemini-3-flash-preview"
}

variable "gw_model" {
  description = "Default LLM model routed through the Local Prisma AIRS AI Gateway."
  type        = string
  default     = "gemini-2.5-flash-lite"
}

variable "airs_security_profile_name" {
  description = "Prisma AIRS Runtime Security Profile name configured in Strata Cloud Manager."
  type        = string
  default     = "agent-bastion-airs"
}

variable "airs_api_key" {
  description = "Prisma AIRS Runtime API key (x-pan-token)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "portkey_api_key" {
  description = "API key for authenticating with the Prisma AIRS AI Gateway."
  type        = string
  sensitive   = true
  default     = ""
}

variable "portkey_provider" {
  description = "Provider slug configured in the AI Gateway (e.g. @vertex-ai-provider)."
  type        = string
  default     = "@vertex-ai-provider"
}

variable "deploy_helm_airs_gateway" {
  description = "Whether Terraform should automatically deploy the Local Prisma AIRS AI Gateway Helm chart."
  type        = bool
  default     = false
}

variable "portkey_registry_password" {
  description = "Registry password for pulling the AI Gateway container image."
  type        = string
  sensitive   = true
  default     = ""
}

variable "portkey_client_auth" {
  description = "Client authentication token for syncing the Local AI Gateway."
  type        = string
  sensitive   = true
  default     = ""
}

variable "portkey_organisation_id" {
  description = "Organisation UUID for syncing the Local AI Gateway."
  type        = string
  default     = ""
}

variable "deploy_helm_redteam_broker" {
  description = "Whether Terraform should automatically deploy the panw-network-client Helm chart for AI Red Teaming."
  type        = bool
  default     = false
}

variable "redteam_client_id" {
  description = "OAuth2 Service Account Client ID for Strata Cloud Manager AI Red Teaming."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redteam_client_secret" {
  description = "OAuth2 Service Account Client Secret for Strata Cloud Manager AI Red Teaming."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redteam_tsg_id" {
  description = "Strata Cloud Manager Tenant Service Group (TSG) ID."
  type        = string
  default     = ""
}

variable "redteam_channel_uuid" {
  description = "Network Broker Channel UUID created in Strata Cloud Manager AI Red Teaming."
  type        = string
  default     = ""
}

variable "redteam_target_1_uuid" {
  description = "SCM Target UUID for Target 1 (Unprotected Baseline)."
  type        = string
  default     = ""
}

variable "redteam_target_2_uuid" {
  description = "SCM Target UUID for Target 2 (AIRS SDK Protected)."
  type        = string
  default     = ""
}

variable "redteam_target_3_uuid" {
  description = "SCM Target UUID for Target 3 (AIRS AI Gateway Protected)."
  type        = string
  default     = ""
}
