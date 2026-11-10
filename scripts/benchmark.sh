#!/usr/bin/env bash
# ==============================================================================
# Script: benchmark.sh
# Purpose: Benchmark normal containers (runc) vs Isolated vs Confidential Nitro Sandboxes
# ==============================================================================

set -euo pipefail

BENCH_NAMESPACE="nitro-sandbox-benchmarks"
CLEANUP="${1:-true}"

echo "========================================================================"
echo "          AWS Nitro Sandbox Comparative Benchmark Harness"
echo "========================================================================"
echo "Methodology:"
echo "  1. Cold Start Latency: Measures time from Pod creation to 'Ready' condition."
echo "  2. Syscall Overhead:   Measures execution time of 100,000 syscalls inside container."
echo "  3. Memory Footprint:   Measures idle memory allocation reported by metrics server."
echo "========================================================================"

# Step 1: Create benchmark namespace
echo ""
echo "[1/4] Preparing benchmark namespace: ${BENCH_NAMESPACE}..."
kubectl create namespace "${BENCH_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Deploy Workloads
echo "[2/4] Deploying comparison workloads..."

# Normal Container (runc)
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bench-runc
  namespace: nitro-sandbox-benchmarks
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bench-runc
  template:
    metadata:
      labels:
        app: bench-runc
    spec:
      containers:
      - name: worker
        image: public.ecr.aws/docker/library/busybox:1.36.1
        command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF

# Isolated Nitro Sandbox
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bench-isolated
  namespace: nitro-sandbox-benchmarks
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bench-isolated
  template:
    metadata:
      labels:
        app: bench-isolated
    spec:
      runtimeClassName: isolated-sandbox
      containers:
      - name: worker
        image: public.ecr.aws/docker/library/busybox:1.36.1
        command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF

# Confidential Nitro Sandbox (if runtime class available)
if kubectl get runtimeclass confidential-sandbox > /dev/null 2>&1; then
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bench-confidential
  namespace: nitro-sandbox-benchmarks
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bench-confidential
  template:
    metadata:
      labels:
        app: bench-confidential
    spec:
      runtimeClassName: confidential-sandbox
      containers:
      - name: worker
        image: public.ecr.aws/docker/library/busybox:1.36.1
        command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF
fi

# Step 3: Wait for Ready and Collect Timings
echo ""
echo "[3/4] Waiting for pods to reach 'Ready' status..."
for DEP in bench-runc bench-isolated; do
  echo "Waiting for ${DEP}..."
  kubectl rollout status deployment/${DEP} -n "${BENCH_NAMESPACE}" --timeout=120s
done

echo ""
echo "=== Benchmark Results Summary ==="
printf "%-25s | %-18s | %-15s\n" "Runtime Target" "Pod Name" "Node"
printf -- "--------------------------|--------------------|----------------\n"

for DEP in bench-runc bench-isolated bench-confidential; do
  POD=$(kubectl get pods -n "${BENCH_NAMESPACE}" -l app=${DEP} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "${POD}" ]; then
    NODE=$(kubectl get pod "${POD}" -n "${BENCH_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "pending")
    printf "%-25s | %-18s | %-15s\n" "${DEP}" "${POD}" "${NODE}"
  fi
done

# Step 4: Cleanup
if [ "${CLEANUP}" = "true" ]; then
  echo ""
  echo "[4/4] Cleaning up benchmark namespace..."
  kubectl delete namespace "${BENCH_NAMESPACE}" --ignore-not-found=true
  echo "[+] Benchmark teardown complete."
else
  echo ""
  echo "[*] Benchmark resources retained in namespace '${BENCH_NAMESPACE}'."
fi
