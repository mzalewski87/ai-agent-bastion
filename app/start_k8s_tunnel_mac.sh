#!/usr/bin/env bash
# =============================================================================
# AI Agent Bastion – Isolated GKE Port-Forward Tunnel Launcher (macOS / Linux)
# - Isolates GCP project (CLOUDSDK_CORE_PROJECT) and KUBECONFIG to this session
# - Automatically verifies Google Cloud login and launches browser if expired
# - Supports networks with SSL/TLS inspection (Corporate VPN)
# - Automatically opens http://127.0.0.1:5050 in the default browser once live
# =============================================================================
set -euo pipefail

export CLOUDSDK_CORE_DISABLE_SSL_VALIDATION="1"

echo "[1/4] Checking Google Cloud authentication status..."
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "      No active Google Cloud session or token expired."
  echo "      Launching default browser for 'gcloud auth login'..."
  gcloud auth login
else
  ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
  echo "      Authenticated as: ${ACTIVE_ACCOUNT:-active-user}"
fi

# Resolve GCP Project ID from environment variable or active gcloud config
DEFAULT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
export CLOUDSDK_CORE_PROJECT="${GCP_PROJECT_ID:-${CLOUDSDK_CORE_PROJECT:-${DEFAULT_PROJECT}}}"
if [ -z "${CLOUDSDK_CORE_PROJECT}" ] || [ "${CLOUDSDK_CORE_PROJECT}" = "(unset)" ]; then
  echo "ERROR: GCP_PROJECT_ID is not set. Run: export GCP_PROJECT_ID='your-gcp-project-id'"
  exit 1
fi

export KUBECONFIG="${HOME}/.kube/config-agent-bastion-gke"
export GKE_CLUSTER="${GKE_CLUSTER:-agent-bastion-gke}"
export GKE_ZONE="${GKE_ZONE:-us-central1-a}"
export GKE_CONTEXT="gke_${CLOUDSDK_CORE_PROJECT}_${GKE_ZONE}_${GKE_CLUSTER}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-ai-agent-bastion}"
export K8S_SERVICE="${K8S_SERVICE:-ai-agent-bastion-svc}"
export LOCAL_PORT="${LOCAL_PORT:-5050}"
export TARGET_URL="http://127.0.0.1:${LOCAL_PORT}"

mkdir -p "${HOME}/.kube"

echo "[2/4] Fetching GKE cluster credentials (${GKE_CLUSTER} in ${CLOUDSDK_CORE_PROJECT}) into isolated KUBECONFIG=${KUBECONFIG}..."
if ! gcloud container clusters get-credentials "${GKE_CLUSTER}" \
  --zone "${GKE_ZONE}" \
  --project "${CLOUDSDK_CORE_PROJECT}"; then
  echo "      Reauthentication required. Launching default browser for 'gcloud auth login'..."
  gcloud auth login
  gcloud container clusters get-credentials "${GKE_CLUSTER}" \
    --zone "${GKE_ZONE}" \
    --project "${CLOUDSDK_CORE_PROJECT}"
fi

echo "[3/4] Configuring TLS bypass (--insecure-skip-tls-verify=true) for VPN SSL inspection..."
kubectl --kubeconfig="${KUBECONFIG}" config unset "clusters.${GKE_CONTEXT}.certificate-authority-data" >/dev/null 2>&1 || true
kubectl --kubeconfig="${KUBECONFIG}" config set "clusters.${GKE_CONTEXT}.insecure-skip-tls-verify" true >/dev/null

# Terminate any stale port-forward process already bound to LOCAL_PORT
if command -v lsof >/dev/null 2>&1; then
  STALE_PIDS="$(lsof -ti tcp:"${LOCAL_PORT}" 2>/dev/null || true)"
  if [ -n "${STALE_PIDS}" ]; then
    echo "      Closing previous tunnel process on port ${LOCAL_PORT}..."
    kill -9 ${STALE_PIDS} >/dev/null 2>&1 || true
    sleep 1
  fi
fi

# Background watcher: waits until the tunnel responds on /health and opens default browser
(
  for _ in $(seq 1 30); do
    if curl -fsS "${TARGET_URL}/health" >/dev/null 2>&1; then
      echo ""
      echo "[READY] Tunnel connected successfully! Opening ${TARGET_URL} in default browser..."
      if command -v open >/dev/null 2>&1; then
        open "${TARGET_URL}" >/dev/null 2>&1 || true
      elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${TARGET_URL}" >/dev/null 2>&1 || true
      fi
      exit 0
    fi
    sleep 0.5
  done
) &
WATCHER_PID=$!
trap 'kill "${WATCHER_PID}" >/dev/null 2>&1 || true' EXIT

echo "[4/4] Starting Kubernetes port-forward tunnel: ${TARGET_URL} -> svc/${K8S_SERVICE}:80 (namespace: ${K8S_NAMESPACE})..."
echo "      Press Ctrl+C to stop the tunnel."
kubectl --kubeconfig="${KUBECONFIG}" --context="${GKE_CONTEXT}" --insecure-skip-tls-verify=true \
  port-forward -n "${K8S_NAMESPACE}" "svc/${K8S_SERVICE}" "${LOCAL_PORT}:80" --address 127.0.0.1
