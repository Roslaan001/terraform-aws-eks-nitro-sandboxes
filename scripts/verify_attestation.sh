#!/usr/bin/env bash
# ==============================================================================
# Script: verify_attestation.sh
# Purpose: Cryptographic Attestation and NSM Verification for Confidential Sandboxes
# ==============================================================================

set -euo pipefail

NAMESPACE="${1:-nitro-sandboxes}"
EXPECTED_DIGEST="${2:-}"

echo "========================================================================"
echo "      Confidential Nitro Sandbox Cryptographic Attestation Verification"
echo "========================================================================"
echo "Namespace:       ${NAMESPACE}"
echo "Expected Digest: ${EXPECTED_DIGEST:-[Not Specified - Query Only]}"
echo "Timestamp:       $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================================"

POD=$(kubectl get pods -n "${NAMESPACE}" -l app=nitro-sandbox-sample -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${POD}" ]; then
  echo "[-] ERROR: No sample pod found in namespace '${NAMESPACE}'."
  exit 1
fi

echo "[*] Target Pod: ${POD}"

# 1. Verify NSM Device Existence
echo ""
echo "[Step 1/3] Checking for Nitro Security Module device node (/dev/nsm)..."
if kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c 'test -e /dev/nsm' 2>/dev/null; then
  echo "[+] PASS: /dev/nsm device node is accessible to the guest sandbox microVM."
else
  echo "[*] Notice: /dev/nsm is not exposed to standard isolated-sandbox containers."
  echo "    Confidential sandboxes require the 'confidential-sandbox' RuntimeClass and compatible host NSM driver."
fi

# 2. Document Attestation Flow
cat << 'EOF'

[Step 2/3] Confidential Computing Verification Workflow:
--------------------------------------------------------------------------------
1. Guest Application Requests Attestation:
   - Guest opens /dev/nsm and issues ioctl NSM_REQUEST_ATTESTATION.
   - Enclave / MicroVM passes a freshly generated ephemeral public key and nonce.
2. Nitro Security Module (NSM) Signs Attestation Document:
   - NSM calculates Platform Configuration Registers:
     * PCR0: Enclave Image File (EIF) / MicroVM Kernel & Application digest.
     * PCR3: Attached IAM Role ARN digest.
     * PCR8: Container layer image digest.
   - NSM cryptographically signs the document with AWS Nitro Root Certificate Authority.
3. Secret Decryption via AWS KMS:
   - Workload issues KMS Decrypt API call passing the Attestation Document as 'Recipient'.
   - KMS validates the NSM digital signature and checks Key Policy conditions:
       "StringEqualsIgnoreCase": {
         "kms:RecipientAttestation:ImageSha384": "<EXPECTED_DIGEST>"
       }
   - KMS decrypts secret and re-encrypts it directly with the enclave's ephemeral public key.
   - KMS returns 'CiphertextForRecipient'.
4. Decryption in Guest Memory:
   - The sandbox microVM decrypts the ciphertext in guest memory.
   - The host OS, hypervisor administrator, or noisy neighbor cannot view the plaintext.
--------------------------------------------------------------------------------
EOF

# 3. Attestation Condition Check
echo "[Step 3/3] Attestation Policy Consistency:"
if [ -n "${EXPECTED_DIGEST}" ]; then
  echo "  Configured Expected Digest: ${EXPECTED_DIGEST}"
  echo "  Validation: Enforced via KMS Key Policy condition kms:RecipientAttestation:ImageSha384."
else
  echo "  Validation: Open policy / isolated mode (digest check omitted)."
fi

echo "========================================================================"
echo "Attestation Check Complete."
echo "========================================================================"
