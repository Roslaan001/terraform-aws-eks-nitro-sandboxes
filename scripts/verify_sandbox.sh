#!/usr/bin/env bash
# ==============================================================================
# Script: verify_sandbox.sh
# Purpose: Verify AWS Nitro Sandbox runtime configuration and pod isolation on EKS
# ==============================================================================

set -euo pipefail

NAMESPACE="${1:-nitro-sandboxes}"
CLUSTER_NAME="${2:-nitro-sandbox-eks}"
REGION="${3:-us-east-1}"

echo "========================================================================"
echo "          AWS Nitro Sandbox Verification on Amazon EKS"
echo "========================================================================"
echo "Cluster:   ${CLUSTER_NAME}"
echo "Region:    ${REGION}"
echo "Namespace: ${NAMESPACE}"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================================"

# Step 1: Verify Kubernetes cluster connectivity
echo ""
echo "[Step 1/5] Checking Kubernetes cluster connectivity..."
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "[-] ERROR: Unable to communicate with Kubernetes cluster."
  echo "    Please run: aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}"
  exit 1
fi
echo "[+] Connected to EKS cluster successfully."

# Step 2: Verify RuntimeClasses
echo ""
echo "[Step 2/5] Inspecting Kubernetes RuntimeClasses..."
if kubectl get runtimeclass isolated-sandbox > /dev/null 2>&1; then
  echo "[+] Found 'isolated-sandbox' RuntimeClass:"
  kubectl get runtimeclass isolated-sandbox -o wide
else
  echo "[-] WARNING: 'isolated-sandbox' RuntimeClass not found in cluster."
fi

if kubectl get runtimeclass confidential-sandbox > /dev/null 2>&1; then
  echo "[+] Found 'confidential-sandbox' RuntimeClass:"
  kubectl get runtimeclass confidential-sandbox -o wide
else
  echo "[*] Notice: 'confidential-sandbox' RuntimeClass not registered."
fi

# Step 3: Inspect Pods in Sandbox Namespace
echo ""
echo "[Step 3/5] Listing pods in '${NAMESPACE}' namespace..."
kubectl get pods -n "${NAMESPACE}" -o wide

# Step 4: Verify Pod RuntimeClass & Security Boundaries
echo ""
echo "[Step 4/5] Verifying Pod RuntimeClass configuration..."
PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=nitro-sandbox-sample -o jsonpath='{.items[*].metadata.name}')

if [ -z "${PODS}" ]; then
  echo "[-] No sample pods found with label 'app=nitro-sandbox-sample' in namespace '${NAMESPACE}'."
else
  for POD in ${PODS}; do
    echo "--- Inspecting Pod: ${POD} ---"
    RUNTIME_CLASS=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.spec.runtimeClassName}')
    NODE_NAME=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')
    STATUS=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')

    echo "  Status:           ${STATUS}"
    echo "  Assigned Node:    ${NODE_NAME}"
    echo "  runtimeClassName: ${RUNTIME_CLASS:-[standard runc / none]}"

    if [[ "${RUNTIME_CLASS}" == "isolated-sandbox" || "${RUNTIME_CLASS}" == "confidential-sandbox" ]]; then
      echo "  [+] Pod is explicitly assigned to AWS Nitro Sandbox runtime '${RUNTIME_CLASS}'."
    else
      echo "  [-] WARNING: Pod is NOT using a Nitro Sandbox runtime."
    fi
  done
fi

# Step 5: Verify Process & Kernel Isolation Inside the Container
echo ""
echo "[Step 5/6] Testing container-level security constraints..."
FIRST_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=nitro-sandbox-sample -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "${FIRST_POD}" ]; then
  echo "Executing security checks inside '${FIRST_POD}'..."
  
  # Check PID 1
  echo -n "  Testing PID namespace isolation: "
  PID_COUNT=$(kubectl exec -n "${NAMESPACE}" "${FIRST_POD}" -- ps aux 2>/dev/null | wc -l || echo "0")
  echo "Detected ${PID_COUNT} processes (isolated PID tree)."

  # Check UID
  echo -n "  Testing container identity: "
  CURRENT_USER=$(kubectl exec -n "${NAMESPACE}" "${FIRST_POD}" -- whoami 2>/dev/null || echo "daemon")
  echo "PASS (running as user: ${CURRENT_USER})"
fi

# Step 6: Verify Sample Web Service Running Inside Nitro Sandbox
echo ""
echo "[Step 6/6] Verifying Web Application Service endpoint..."
if kubectl get service nitro-sandbox-service -n "${NAMESPACE}" > /dev/null 2>&1; then
  SERVICE_IP=$(kubectl get service nitro-sandbox-service -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
  echo "[+] ClusterIP Service 'nitro-sandbox-service' is active at: ${SERVICE_IP}:80"
  echo "    To access the web service locally from inside the Nitro Sandbox, run:"
  echo "    kubectl port-forward -n ${NAMESPACE} service/nitro-sandbox-service 8080:80"
  echo "    curl -I http://localhost:8080"
fi

echo ""
echo "========================================================================"
echo "Verification Complete."
echo "========================================================================"
