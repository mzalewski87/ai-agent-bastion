# End-to-End Deployment Guide (GCP + Terraform + GKE + Prisma AIRS)

This guide walks through deploying the complete **AI Agent Bastion** environment from scratch on **Google Cloud Platform (GCP)** using **Terraform**, **Google Kubernetes Engine (GKE)**, **Google Vertex AI**, **Palo Alto Networks Prisma AIRS**, and **Strata Cloud Manager (SCM) – AI Red Teaming**.

---

## 1. Prerequisites

Ensure the following CLI tools are installed on your workstation:
- **Google Cloud SDK (`gcloud`)**
- **Kubernetes CLI (`kubectl`)** and **`gke-gcloud-auth-plugin`** (`gcloud components install gke-gcloud-auth-plugin`)
- **Terraform (`>= 1.5.0`)**
- **Helm (`>= 3.12`)**

You will also need:
1. A **Google Cloud Project** with billing enabled and Owner/Editor permissions.
2. Access to **Palo Alto Networks Strata Cloud Manager (SCM)** with **Prisma AIRS** (Runtime Security API Key + AI Red Teaming enabled).

---

## 2. Phase 1: Prepare Prisma AIRS & Strata Cloud Manager Credentials

Before running Terraform, gather the following parameters from Strata Cloud Manager:

1. **Prisma AIRS Runtime Security Profile & API Key (for Mode 2 & Mode 3):**
   - In Strata Cloud Manager, create an AI Runtime Security Profile named **`agent-bastion-airs`** with:
     - *Prompt Injection & Jailbreak*: `BLOCK`
     - *Malicious Code Detection*: `BLOCK`
     - *Malicious URL Detection*: `BLOCK`
     - *Sensitive Data Protection (DLP)*: `BLOCK` (with masking enabled)
   - Generate an **AIRS API Key** (`x-pan-token`).

2. **AI Gateway Credentials (for Mode 3 – Local K8s Gateway):**
   - Retrieve your AI Gateway API Key (`portkey_api_key`), virtual provider slug pointing to Vertex AI (`portkey_provider`, e.g., `@vertex-ai-provider`), and (if deploying the self-hosted gateway chart) registry credentials (`portkey_registry_password`, `portkey_client_auth`, `portkey_organisation_id`).

3. **AI Red Teaming Network Broker Channel & Service Account (for Automated Red Teaming):**
   - In Strata Cloud Manager under **AI Red Teaming -> Network Broker**, create a new Network Broker channel and note its **Channel UUID** (`redteam_channel_uuid`).
   - Create an IAM Service Account in SCM with AI Red Teaming permissions and note its **Client ID** (`redteam_client_id`), **Client Secret** (`redteam_client_secret`), and **TSG ID** (`redteam_tsg_id`).

---

## 3. Phase 2: Provision GCP Infrastructure with Terraform

All GCP networking, Memorystore Redis, Artifact Registry, IAM Workload Identity, and Private GKE resources are defined in `./terraform`.

### Step 2.1: Authenticate with GCP

```bash
gcloud auth login
gcloud auth application-default login
```

### Step 2.2: Configure `terraform.tfvars`

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in your `project_id` and credentials:

```hcl
project_id                 = "your-gcp-project-id"
region                     = "us-central1"
zone                       = "us-central1-a"
cluster_name               = "agent-bastion-gke"
airs_security_profile_name = "agent-bastion-airs"
airs_api_key               = "YOUR_PRISMA_AIRS_API_KEY"
portkey_api_key            = "YOUR_AI_GATEWAY_API_KEY"
portkey_provider           = "@your-vertex-ai-provider-slug"

deploy_helm_redteam_broker = true
redteam_tsg_id             = "YOUR_TSG_ID"
redteam_client_id          = "your-sa@YOUR_TSG_ID.iam.panserviceaccount.com"
redteam_client_secret      = "YOUR_CLIENT_SECRET"
redteam_channel_uuid       = "YOUR_NETWORK_BROKER_CHANNEL_UUID"
```

### Step 2.3: Initialize and Apply Terraform

```bash
terraform init
terraform plan
terraform apply
```

**What Terraform provisions (~10–12 minutes):**
1. Enables required GCP APIs (`compute`, `container`, `artifactregistry`, `cloudbuild`, `aiplatform`, `redis`, `iam`).
2. Creates a dedicated VPC (`agent-bastion-vpc`), subnet (`agent-bastion-subnet`) with secondary CIDR ranges for GKE pods and services, Cloud Router, and Cloud NAT.
3. Provisions a **Google Cloud Memorystore for Redis** instance (`agent-bastion-gke-redis`, Redis 7.0) inside the private VPC.
4. Creates an **Artifact Registry** Docker repository (`agent-bastion-repo`).
5. Provisions a **Private GKE Cluster** (`agent-bastion-gke`) with Workload Identity enabled, Shielded Nodes, HTTP Load Balancing disabled (Zero External Exposure), and binds Kubernetes ServiceAccount `ai-agent-bastion/agent-bastion-sa` to a GCP IAM Service Account with `roles/aiplatform.user` (for passwordless Vertex AI access).
6. Creates Kubernetes namespaces (`ai-agent-bastion`, `airs-gw`, `airs-redteam`), `ConfigMap`, `Secret`, `Deployment`, `ClusterIP Service`, and optional Helm releases for `panw-network-client` and `airs-gw`.

---

## 4. Phase 3: Build & Deploy the Application Container Image

Once `terraform apply` completes, build and push the `ai-agent-bastion` image directly in Google Cloud Build (no local Docker daemon required):

```bash
# Run from the terraform/ directory:
eval "$(terraform output -raw cloud_build_command)"
```

 Or manually from the repository root:

```bash
export GCP_PROJECT_ID="your-gcp-project-id"
gcloud builds submit ./app \
  --tag "us-central1-docker.pkg.dev/${GCP_PROJECT_ID}/agent-bastion-repo/ai-agent-bastion:2026.11" \
  --project "${GCP_PROJECT_ID}"
```

Then fetch cluster credentials and restart the deployment so it pulls the newly built image:

```bash
gcloud container clusters get-credentials agent-bastion-gke \
  --zone us-central1-a \
  --project "${GCP_PROJECT_ID}"

kubectl rollout restart deployment/ai-agent-bastion -n ai-agent-bastion
kubectl rollout status deployment/ai-agent-bastion -n ai-agent-bastion --timeout=90s
```

---

## 5. Phase 4: Verify Helm Releases (AI Gateway & Network Broker)

If you enabled `deploy_helm_airs_gateway = true` and `deploy_helm_redteam_broker = true` in `terraform.tfvars`, Terraform has already deployed both Helm charts. You can verify their status with:

```bash
kubectl get pods -n airs-gw
kubectl get pods -n airs-redteam
```

*(If you prefer to install them manually via Helm instead of Terraform, use the sanitized templates `app/airs-gw-values.yaml` and `app/airs-redteam-values.yaml`).*

---

## 6. Phase 5: Configure the 3 Agent Targets in Strata Cloud Manager (AI Red Teaming)

In **Strata Cloud Manager -> AI Red Teaming -> Targets**, create three targets of type **`AGENT`** routed through your Network Broker channel (`panw-network-client`):

| Target # | Name in SCM | Internal GKE Endpoint (`POST`) | Content Filter (Guardrails) in SCM |
|---|---|---|---|
| **Target 1** | `Bastion-Agent-1-Unprotected` | `http://ai-agent-bastion-svc.ai-agent-bastion.svc.cluster.local/api/chat/unprotected` | **Disabled (`OFF`)** |
| **Target 2** | `Bastion-Agent-2-AIRS-SDK-Protected` | `http://ai-agent-bastion-svc.ai-agent-bastion.svc.cluster.local/api/chat/runtime` | **Enabled (`HTTP 403`)** |
| **Target 3** | `Bastion-Agent-3-AIRS-Gateway-Protected` | `http://ai-agent-bastion-svc.ai-agent-bastion.svc.cluster.local/api/chat/gateway` | **Enabled (`HTTP 446`)** |

### Request / Response JSON Mapping for All 3 Targets:
- **Request Headers:** `{"Content-Type": "application/json"}`
- **Request Body JSON:** `{"message": "{INPUT}"}`
- **Response Key:** `response` (`{"response": "{RESPONSE}"}`)

### Content Filter Error JSON for Protected Targets:
- **Target 2 (`HTTP 403`):**
  ```json
  {
    "stage": "prompt",
    "blocked": true,
    "message": "Your message was blocked by AIRS for safety reasons.",
    "category": "malicious"
  }
  ```
- **Target 3 (`HTTP 446`):**
  ```json
  {
    "blocked": true,
    "response": "Blocked by the Prisma AIRS guardrail in the AI Gateway (HTTP 446). The request never reached the model.",
    "status": 446
  }
  ```

After creating the three targets in SCM, copy their UUIDs into `terraform.tfvars` (`redteam_target_1_uuid`, `redteam_target_2_uuid`, `redteam_target_3_uuid`) and run `terraform apply` (or patch `ConfigMap/agent-bastion-env`).

---

## 7. Phase 6: Connect via the Local Tunnel & Run the Live Demo

Because the GKE cluster has zero public LoadBalancers, use the included launcher script to establish an isolated local tunnel (`http://127.0.0.1:5050`). The script automatically checks your `gcloud` session (opening a browser login if expired), configures VPN SSL-inspection compatibility, starts `kubectl port-forward`, and opens **`http://127.0.0.1:5050`** in your default browser:

### macOS / Linux:
```bash
export GCP_PROJECT_ID="your-gcp-project-id"
chmod +x ./app/start_k8s_tunnel_mac.sh
./app/start_k8s_tunnel_mac.sh
```

### Windows PowerShell:
```powershell
$env:GCP_PROJECT_ID = "your-gcp-project-id"
powershell -ExecutionPolicy Bypass -File ".\demo\start_k8s_tunnel.ps1"
```

### Offline / Local Fallback Mode (Without GKE):
For offline testing without a Kubernetes cluster, you can run the application directly on your laptop:
```bash
cd demo
pip install -r ../requirements.txt  # or: pip install flask requests google-auth pan-aisecurity
python app.py
# Open http://127.0.0.1:5050
```
