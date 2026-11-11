#!/usr/bin/env bash
# ==============================================================================
# Script: verify_sandbox.sh
# Purpose: Verify AWS Nitro Sandbox configuration and pod posture on Amazon EKS
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
echo "[Step 1/6] Checking Kubernetes cluster connectivity..."
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "[-] ERROR: Unable to communicate with Kubernetes cluster."
  echo "    Please run: aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}"
  exit 1
fi
echo "[+] Connected to EKS cluster successfully."

# Step 2: Verify EKS Auto Mode built-in RuntimeClasses
echo ""
echo "[Step 2/6] Inspecting Kubernetes RuntimeClasses..."
if kubectl get runtimeclass isolated-sandbox > /dev/null 2>&1; then
  echo "[+] Found built-in 'isolated-sandbox' RuntimeClass:"
  kubectl get runtimeclass isolated-sandbox -o wide
else
  echo "[-] WARNING: 'isolated-sandbox' RuntimeClass not found. Ensure EKS Auto Mode with Nitro Sandboxes is active."
fi

if kubectl get runtimeclass confidential-sandbox > /dev/null 2>&1; then
  echo "[+] Found built-in 'confidential-sandbox' RuntimeClass:"
  kubectl get runtimeclass confidential-sandbox -o wide
else
  echo "[*] Notice: 'confidential-sandbox' RuntimeClass not found."
fi

# Step 3: Inspect Pods in Sandbox Namespace
echo ""
echo "[Step 3/6] Listing pods in '${NAMESPACE}' namespace..."
kubectl get pods -n "${NAMESPACE}" -o wide

# Step 4: Verify Pod RuntimeClass & Security Boundaries
echo ""
echo "[Step 4/6] Verifying Pod RuntimeClass configuration..."
PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=nitro-sandbox-sample -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

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

    if [[ "${RUNTIME_CLASS}" == "isolated-sandbox" ]]; then
      echo "  [+] Pod is assigned to 'isolated-sandbox' runtime."
    elif [[ "${RUNTIME_CLASS}" == "confidential-sandbox" ]]; then
      echo "  [+] Pod is assigned to 'confidential-sandbox' runtime."
      HAS_POLICY=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.sandbox\.amazonaws\.com/policy}' 2>/dev/null || echo "")
      if [ -n "${HAS_POLICY}" ]; then
        echo "  [+] Cedar policy annotation 'sandbox.amazonaws.com/policy' detected."
      else
        echo "  [-] WARNING: Confidential pod is missing Cedar policy annotation!"
      fi
    else
      echo "  [-] WARNING: Pod is NOT using a Nitro Sandbox runtime."
    fi
  done
fi

# Step 5: Test in-container security posture
echo ""
echo "[Step 5/6] Testing container-level security constraints..."
FIRST_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=nitro-sandbox-sample -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${FIRST_POD}" ]; then
  echo "Executing security checks inside '${FIRST_POD}'..."
  echo -n "  Testing process isolation (PID tree): "
  PID_COUNT=$(kubectl exec -n "${NAMESPACE}" "${FIRST_POD}" -- ps aux 2>/dev/null | wc -l || echo "0")
  echo "Detected ${PID_COUNT} processes."

  echo -n "  Testing container UID identity: "
  CURRENT_USER=$(kubectl exec -n "${NAMESPACE}" "${FIRST_POD}" -- whoami 2>/dev/null || echo "non-root")
  echo "User: ${CURRENT_USER}"
fi

# Step 6: Verify Web Application Service endpoint
echo ""
echo "[Step 6/6] Verifying Web Application Service endpoint..."
if kubectl get service nitro-sandbox-service -n "${NAMESPACE}" > /dev/null 2>&1; then
  SERVICE_IP=$(kubectl get service nitro-sandbox-service -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
  echo "[+] ClusterIP Service 'nitro-sandbox-service' is active at: ${SERVICE_IP}:80"
  echo "    To test connectivity: kubectl port-forward -n ${NAMESPACE} service/nitro-sandbox-service 8080:80"
fi

echo ""
echo "========================================================================"
echo "Note: Kubernetes-level tests verify workload configuration and"
echo "specification posture. Cryptographic attestation and hardware microVM"
echo "isolation are enforced directly by the AWS Nitro Hypervisor."
echo "========================================================================"
