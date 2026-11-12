#!/usr/bin/env bash
# ==============================================================================
# Script: verify_sandbox.sh
# Purpose: Verification of AWS Nitro Sandboxes on EKS Auto Mode
#
# This script validates observable Kubernetes, IAM, and KMS state, plus two
# live runtime tests (confidential-pod exec denial and fresh-pod Pod Identity
# credentials). It does NOT prove hardware isolation — that is an
# architectural property of the AWS Nitro Hypervisor documented at:
#   https://docs.aws.amazon.com/eks/latest/userguide/sandboxing.html
#
# Usage: verify_sandbox.sh [namespace] [cluster-name] [region]
# Optional environment overrides:
#   EXPECTED_PCR17         Expected PCR17 value (default: Terraform variable)
#   SERVICE_ACCOUNT        Pod Identity service account (default: sandbox-workload-sa)
#   SKIP_FRESH_POD_TEST=1  Skip the fresh-pod Pod Identity credential test
#   FRESH_POD_IMAGE        Image for the fresh-pod test (must contain the AWS CLI)
# ==============================================================================

set -euo pipefail

NAMESPACE="${1:-nitro-sandboxes}"
CLUSTER_NAME="${2:-nitro-sandbox-eks}"
REGION="${3:-us-east-1}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-sandbox-workload-sa}"
FRESH_POD_IMAGE="${FRESH_POD_IMAGE:-public.ecr.aws/aws-cli/aws-cli:2.27.50}"
TF_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FAILURES=0
WARNINGS=0

fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  [WARN] $1"; WARNINGS=$((WARNINGS + 1)); }
pass() { echo "  [PASS] $1"; }
info() { echo "  [INFO] $1"; }

finish() {
  echo ""
  echo "========================================================================"
  echo "                       VERIFICATION SUMMARY"
  echo "========================================================================"
  if [ "${FAILURES}" -gt 0 ]; then
    echo "RESULT: FAILED (${FAILURES} failure(s), ${WARNINGS} warning(s))"
    echo "========================================================================"
    exit 1
  elif [ "${WARNINGS}" -gt 0 ]; then
    echo "RESULT: PASSED WITH WARNINGS (${WARNINGS} warning(s))"
  else
    echo "RESULT: ALL CHECKS PASSED (0 failures, 0 warnings)"
  fi
  cat <<'EOF'

Verification Scope (evidence type in brackets):
  1. Expected values:            Terraform outputs/variables cross-checked with live EKS [config]
  2. RuntimeClass availability:  Kubernetes API [structural]
  3. Node sandbox capacity:      Kubernetes API labels/resources [structural]
  4. Workload posture:           Pod phase, RuntimeClass, replica count vs Deployment [live state]
  5. Cedar runtime_policy:       permit statements parsed for an Exec permit [structural]
     Exec denial:                kubectl exec rejected by the guest agent [runtime]
  6. KMS key policy:             Exact principal/resource/action/operator/values [structural]
  7. IAM policies & KMS grants:  Other authorization paths, reported separately [structural]
  8. IAM trust policy:           Principal, actions, SourceAccount, SourceArn [structural]
  9. Fresh-pod Pod Identity:     New pod obtains workload-role credentials [runtime]

Architectural Boundary Note:
  Hardware isolation is an architectural property of the AWS Nitro Hypervisor and
  cannot be measured from the Kubernetes API or from inside the guest. Guest-level
  observations (e.g. uname) confirm a per-pod kernel; they do not independently
  prove hypervisor-level isolation. This script makes no claim about the specific
  memory-protection technology used by confidential sandboxes.
  KMS recipient-attestation enforcement is verified structurally (policy content).
  End-to-end attested decrypt remains PARTIALLY VERIFIED: it requires an in-guest
  workload that obtains a Nitro attestation document from /dev/nsm and calls KMS.
========================================================================
EOF
  exit 0
}

echo "========================================================================"
echo "          AWS Nitro Sandbox Verification on Amazon EKS"
echo "========================================================================"
echo "Cluster:   ${CLUSTER_NAME}"
echo "Region:    ${REGION}"
echo "Namespace: ${NAMESPACE}"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================================"

# ── Check 1: Connectivity and expected values ─────────────────────────────
echo ""
echo "[Check 1/9] Verifying connectivity and resolving expected values..."
if ! kubectl cluster-info > /dev/null 2>&1; then
  fail "Unable to communicate with Kubernetes cluster."
  echo "    Please run: aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}"
  finish
fi
pass "Connected to Kubernetes API."

EXPECTED_CLUSTER_ARN=$(terraform -chdir="${TF_DIR}" output -raw eks_cluster_arn 2>/dev/null || echo "")
LIVE_CLUSTER_ARN=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query cluster.arn --output text 2>/dev/null || echo "")
if [ -z "${EXPECTED_CLUSTER_ARN}" ] || [ -z "${LIVE_CLUSTER_ARN}" ]; then
  fail "Could not resolve cluster ARN (terraform='${EXPECTED_CLUSTER_ARN}', live='${LIVE_CLUSTER_ARN}')."
  finish
elif [ "${EXPECTED_CLUSTER_ARN}" != "${LIVE_CLUSTER_ARN}" ]; then
  fail "Terraform cluster ARN '${EXPECTED_CLUSTER_ARN}' does not match live cluster '${LIVE_CLUSTER_ARN}'."
  finish
fi
PARTITION=$(echo "${EXPECTED_CLUSTER_ARN}" | cut -d: -f2)
EXPECTED_ACCOUNT=$(echo "${EXPECTED_CLUSTER_ARN}" | cut -d: -f5)
pass "Expected cluster ARN: ${EXPECTED_CLUSTER_ARN} (Terraform output matches live EKS)."
info "Expected account ID:  ${EXPECTED_ACCOUNT}"

MODES=$(terraform -chdir="${TF_DIR}" output -json eks_sandbox_modes 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
if [ -z "${MODES}" ]; then
  fail "Could not read eks_sandbox_modes from Terraform outputs."
  finish
fi
ISOLATED_ENABLED=false; CONFIDENTIAL_ENABLED=false
echo "${MODES}" | grep -qx isolated && ISOLATED_ENABLED=true
echo "${MODES}" | grep -qx confidential && CONFIDENTIAL_ENABLED=true
info "Enabled sandbox modes: $(echo "${MODES}" | paste -sd, -)"

if [ "${CONFIDENTIAL_ENABLED}" == "true" ]; then
  if [ -z "${EXPECTED_PCR17:-}" ]; then
    EXPECTED_PCR17=$(echo 'var.confidential_expected_pcr17' | terraform -chdir="${TF_DIR}" console 2>/dev/null | tr -d '"' || echo "")
  fi
  if [ -z "${EXPECTED_PCR17}" ]; then
    fail "Could not resolve expected PCR17 (set EXPECTED_PCR17 or check Terraform variables)."
  else
    info "Expected PCR17:       ${EXPECTED_PCR17}"
  fi
fi
EXPECTED_PCR8_SERVICE="eks.amazonaws.com"

ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --region "${REGION}" \
  --namespace "${NAMESPACE}" --service-account "${SERVICE_ACCOUNT}" \
  --query 'associations[0].associationId' --output text 2>/dev/null || echo "")
WORKLOAD_ROLE_ARN=""
if [ -n "${ASSOC_ID}" ] && [ "${ASSOC_ID}" != "None" ]; then
  WORKLOAD_ROLE_ARN=$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" --region "${REGION}" \
    --association-id "${ASSOC_ID}" --query association.roleArn --output text 2>/dev/null || echo "")
fi
if [ -z "${WORKLOAD_ROLE_ARN}" ]; then
  fail "No Pod Identity association found for ${NAMESPACE}/${SERVICE_ACCOUNT}."
else
  pass "Workload role (from Pod Identity association ${ASSOC_ID}): ${WORKLOAD_ROLE_ARN}"
fi
WORKLOAD_ROLE_NAME="${WORKLOAD_ROLE_ARN##*/}"

# ── Check 2: RuntimeClasses ───────────────────────────────────────────────
echo ""
echo "[Check 2/9] Verifying built-in EKS Auto Mode RuntimeClasses..."
for RC in isolated-sandbox confidential-sandbox; do
  MODE="${RC%-sandbox}"
  if ! echo "${MODES}" | grep -qx "${MODE}"; then
    info "RuntimeClass '${RC}' not required (mode '${MODE}' not enabled)."
    continue
  fi
  RC_JSON=$(kubectl get runtimeclass "${RC}" -o json 2>/dev/null || echo "")
  if [ -n "${RC_JSON}" ]; then
    pass "RuntimeClass '${RC}' exists (handler: $(echo "${RC_JSON}" | jq -r '.handler // "unknown"'))."
  else
    fail "RuntimeClass '${RC}' not found."
  fi
done

# ── Check 3: Node sandbox capacity ────────────────────────────────────────
echo ""
echo "[Check 3/9] Verifying Nitro sandbox node capacity..."
NODES_JSON=$(kubectl get nodes -l eks.amazonaws.com/nitro-sandbox=true -o json 2>/dev/null || echo '{"items":[]}')
NODE_COUNT=$(echo "${NODES_JSON}" | jq '.items | length')
if [ "${NODE_COUNT}" -gt 0 ]; then
  echo "${NODES_JSON}" | jq -r '.items[] | "  [+] Node \(.metadata.name): InstanceType=\(.metadata.labels["node.kubernetes.io/instance-type"] // "unknown"), SandboxCapacity=\(.status.capacity["eks.amazonaws.com/nitro-sandbox"] // "0"), Allocatable=\(.status.allocatable["eks.amazonaws.com/nitro-sandbox"] // "0")"'
else
  warn "No nodes found with label eks.amazonaws.com/nitro-sandbox=true."
fi

# ── Workload helper ───────────────────────────────────────────────────────
# Validates every pod for a mode: phase Running, expected RuntimeClass, and
# running-pod count >= Deployment desired replicas. Sets POD_NAMES.
check_workload() {
  local mode="$1" deploy="$2" expected_rc="$3"
  POD_NAMES=""
  local desired
  desired=$(kubectl get deployment -n "${NAMESPACE}" "${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  if [ -z "${desired}" ]; then
    fail "Deployment '${deploy}' not found in namespace '${NAMESPACE}'."
    return
  fi
  local pods_json count good=0
  pods_json=$(kubectl get pods -n "${NAMESPACE}" -l "sandbox.aws.amazon.com/mode=${mode}" -o json 2>/dev/null || echo '{"items":[]}')
  count=$(echo "${pods_json}" | jq '.items | length')
  echo "  Deployment '${deploy}' desired replicas: ${desired}; discovered pods: ${count}"

  if [ "${count}" -eq 0 ]; then
    fail "No ${mode} sandbox pods found (expected ${desired})."
    return
  fi
  for i in $(seq 0 $((count - 1))); do
    local name phase node rc deleting
    name=$(echo "${pods_json}" | jq -r ".items[$i].metadata.name")
    phase=$(echo "${pods_json}" | jq -r ".items[$i].status.phase")
    node=$(echo "${pods_json}" | jq -r ".items[$i].spec.nodeName // \"unscheduled\"")
    rc=$(echo "${pods_json}" | jq -r ".items[$i].spec.runtimeClassName // \"none\"")
    deleting=$(echo "${pods_json}" | jq -r ".items[$i].metadata.deletionTimestamp // \"\"")
    echo "  --- ${mode} replica $((i+1))/${count}: ${name} (phase=${phase}, node=${node}, runtimeClass=${rc}) ---"
    local ok=true
    if [ "${phase}" != "Running" ] || [ -n "${deleting}" ]; then
      fail "Pod '${name}' is not Running (phase=${phase}${deleting:+, terminating})."
      ok=false
    fi
    if [ "${rc}" != "${expected_rc}" ]; then
      fail "Pod '${name}' uses runtimeClassName='${rc}', expected '${expected_rc}'."
      ok=false
    fi
    if [ "${ok}" == "true" ]; then
      pass "Pod '${name}' is Running with runtimeClassName=${expected_rc}."
      good=$((good + 1))
      POD_NAMES="${POD_NAMES} ${name}"
    fi
  done
  if [ "${good}" -lt "${desired}" ]; then
    fail "Only ${good}/${desired} ${mode} replicas are Running with '${expected_rc}'."
  else
    pass "${good}/${desired} ${mode} replicas Running with '${expected_rc}'."
  fi
}

# ── Check 4: Isolated workloads ───────────────────────────────────────────
echo ""
echo "[Check 4/9] Verifying isolated sandbox workloads..."
if [ "${ISOLATED_ENABLED}" == "true" ]; then
  echo "  [Guest-level observation (uname) confirms a per-pod kernel; it does not"
  echo "   independently prove Nitro Hypervisor hardware isolation]"
  check_workload isolated nitro-sandbox-isolated isolated-sandbox
  for POD in ${POD_NAMES}; do
    GUEST_KERNEL=$(timeout 30 kubectl exec -n "${NAMESPACE}" "${POD}" -- uname -r 2>/dev/null || echo "exec-unavailable")
    info "${POD} guest kernel: ${GUEST_KERNEL} (guest-level observation)"
  done
else
  info "Isolated mode not enabled; skipped."
fi

# ── Check 5: Confidential workloads, Cedar policy, Exec denial ───────────
echo ""
echo "[Check 5/9] Verifying confidential sandbox workloads and Cedar policy..."
# Structural parse of a Cedar runtime_policy: strips // comments, splits on ';',
# and extracts the action clause of every permit statement. This is NOT a Cedar
# evaluator; it detects an explicit Exec permit or an unconstrained action.
CEDAR_PARSE='
  .runtime_policy
  | split("\n") | map(sub("//.*$"; "")) | join(" ")
  | split(";")
  | map(select(test("^\\s*permit\\s*\\(")))
  | map(capture("^\\s*permit\\s*\\(\\s*principal[^,]*,\\s*(?<action>action[^,]*?)\\s*,") // {action: null})
  | {
      permits:       map(.action),
      unparsed:      map(select(.action == null)) | length,
      exec_permit:   any(.[]; (.action // "") | test("Exec")),
      unconstrained: any(.[]; .action == "action")
    }'

if [ "${CONFIDENTIAL_ENABLED}" == "true" ]; then
  check_workload confidential nitro-sandbox-confidential confidential-sandbox
  CONF_PODS_JSON=$(kubectl get pods -n "${NAMESPACE}" -l sandbox.aws.amazon.com/mode=confidential -o json 2>/dev/null || echo '{"items":[]}')
  for POD in ${POD_NAMES}; do
    echo "  --- Cedar / exec checks: ${POD} ---"
    CEDAR_RAW=$(echo "${CONF_PODS_JSON}" | jq -r --arg p "${POD}" '.items[] | select(.metadata.name == $p) | .metadata.annotations["sandbox.amazonaws.com/policy"] // ""')
    if [ -z "${CEDAR_RAW}" ]; then
      fail "Pod '${POD}' is missing 'sandbox.amazonaws.com/policy' annotation."
    else
      CEDAR_JSON=$(echo "${CEDAR_RAW}" | base64 -d 2>/dev/null | gzip -d 2>/dev/null || echo "")
      if [ -z "${CEDAR_JSON}" ] || ! echo "${CEDAR_JSON}" | jq -e 'has("admission_policy") and has("runtime_policy")' >/dev/null 2>&1; then
        fail "Cedar annotation on '${POD}' is not a valid gzip+base64 envelope with admission_policy and runtime_policy."
      else
        PARSED=$(echo "${CEDAR_JSON}" | jq -c "${CEDAR_PARSE}" 2>/dev/null || echo "")
        if [ -z "${PARSED}" ]; then
          fail "Could not parse Cedar runtime_policy statements."
        else
          PERMITS=$(echo "${PARSED}" | jq -r '[.permits[] | sub("^action\\s*==\\s*Agent::Action::"; "") | gsub("\""; "")] | join(", ")')
          info "runtime_policy permit actions: ${PERMITS}"
          if [ "$(echo "${PARSED}" | jq '.unparsed')" -gt 0 ]; then
            fail "[structural] $(echo "${PARSED}" | jq '.unparsed') permit statement(s) could not be parsed; cannot rule out an Exec permit."
          elif [ "$(echo "${PARSED}" | jq '.exec_permit')" == "true" ]; then
            fail "[structural] runtime_policy contains a permit referencing Exec."
          elif [ "$(echo "${PARSED}" | jq '.unconstrained')" == "true" ]; then
            fail "[structural] runtime_policy contains a permit with an unconstrained action (permits every action, including Exec)."
          else
            pass "[structural] No permit statement in runtime_policy (comments stripped) references Exec or leaves the action unconstrained; Exec falls to Cedar default-deny."
          fi
        fi
      fi
    fi

    EXEC_OUTPUT=$(timeout 30 kubectl exec -n "${NAMESPACE}" "${POD}" -- uname -a 2>&1 || true)
    if echo "${EXEC_OUTPUT}" | grep -q 'policy denied Agent::Action::"Exec"'; then
      pass "[runtime] Guest agent denied kubectl exec: 'policy denied Agent::Action::\"Exec\"'."
    elif echo "${EXEC_OUTPUT}" | grep -qi "forbidden\|denied\|not permitted"; then
      warn "[runtime] Exec denied but with unexpected message: ${EXEC_OUTPUT}"
    else
      fail "[runtime] Exec was NOT denied on confidential pod '${POD}': ${EXEC_OUTPUT}"
    fi
  done
else
  info "Confidential mode not enabled; skipped."
fi

# ── Check 6: KMS key policy (key policy only) ─────────────────────────────
echo ""
echo "[Check 6/9] Verifying KMS key policy attestation statements (key policy only)..."
KMS_KEY_ARN=$(terraform -chdir="${TF_DIR}" output -raw eks_kms_key_arn 2>/dev/null || echo "")
KEY_POLICY=""
if [ -z "${KMS_KEY_ARN}" ]; then
  fail "Could not retrieve KMS key ARN from Terraform outputs."
else
  info "KMS key: ${KMS_KEY_ARN}"
  KEY_POLICY=$(aws kms get-key-policy --key-id "${KMS_KEY_ARN}" --policy-name default --region "${REGION}" --query Policy --output text 2>/dev/null || echo "")
  [ -z "${KEY_POLICY}" ] && fail "Could not retrieve KMS key policy."
fi

# validate_key_stmt <sid> <effect> <operator> <expected-condition-json>
validate_key_stmt() {
  local sid="$1" effect="$2" op="$3" cond="$4"
  local n result
  n=$(echo "${KEY_POLICY}" | jq --arg sid "${sid}" '[.Statement[] | select(.Sid == $sid)] | length')
  if [ "${n}" -ne 1 ]; then
    fail "Sid '${sid}': expected exactly 1 statement, found ${n}."
    return
  fi
  result=$(echo "${KEY_POLICY}" | jq -c --arg sid "${sid}" --arg eff "${effect}" --arg op "${op}" \
    --arg role "${WORKLOAD_ROLE_ARN}" --argjson cond "${cond}" '
    .Statement[] | select(.Sid == $sid) | {
      effect:    (.Effect == $eff),
      principal: (.Principal == {"AWS": $role}),
      resource:  (.Resource == "*" or .Resource == ["*"]),
      action:    ((.Action | if type == "string" then [.] else . end | sort) == ["kms:Decrypt", "kms:GenerateDataKey"]),
      no_not:    ((has("NotPrincipal") or has("NotAction") or has("NotResource")) | not),
      operator:  (((.Condition // {}) | keys) == [$op]),
      values:    ((.Condition[$op] // {}) as $c
                  | (($c | keys) == ($cond | keys))
                    and all($cond | to_entries[]; ($c[.key] | type) == "string"
                            and (($c[.key] | ascii_downcase) == (.value | ascii_downcase))))
    }')
  if echo "${result}" | jq -e 'all(.[]; . == true)' >/dev/null; then
    pass "Sid '${sid}': Effect=${effect}, Principal=workload role (exact), Resource=*, Action=[kms:Decrypt,kms:GenerateDataKey], ${op} $(echo "${cond}" | jq -c .)"
  else
    fail "Sid '${sid}' mismatch: $(echo "${result}" | jq -c 'with_entries(select(.value != true)) | keys') failed."
  fi
}

if [ -n "${KEY_POLICY}" ] && [ -n "${WORKLOAD_ROLE_ARN}" ]; then
  ROOT_STMT=$(echo "${KEY_POLICY}" | jq -c --arg r "arn:${PARTITION}:iam::${EXPECTED_ACCOUNT}:root" '[.Statement[] | select(.Effect == "Allow" and .Principal.AWS == $r)] | length')
  if [ "${ROOT_STMT}" -gt 0 ]; then
    info "Key policy contains an account-root Allow (EnableIAMUserPermissions): KMS authorization is"
    info "delegated to IAM policies, so the gated Allow below is NOT the only authorization path."
    info "The two explicit Deny statements are the critical attestation enforcement controls."
  fi

  if [ "${CONFIDENTIAL_ENABLED}" == "true" ] && [ -n "${EXPECTED_PCR17:-}" ]; then
    PCR17_COND=$(jq -nc --arg v "${EXPECTED_PCR17}" '{"kms:RecipientAttestation:PCR17": $v}')
    PCR8_COND=$(jq -nc --arg v "${EXPECTED_PCR8_SERVICE}" '{"kms:RecipientAttestation:PCR8:ServiceName": $v}')
    BOTH_COND=$(jq -nc --arg a "${EXPECTED_PCR17}" --arg b "${EXPECTED_PCR8_SERVICE}" \
      '{"kms:RecipientAttestation:PCR17": $a, "kms:RecipientAttestation:PCR8:ServiceName": $b}')
    validate_key_stmt DenyConfidentialWorkloadMismatchedPCR17 Deny StringNotEqualsIgnoreCase "${PCR17_COND}"
    validate_key_stmt DenyConfidentialWorkloadMismatchedPCR8  Deny StringNotEqualsIgnoreCase "${PCR8_COND}"
    validate_key_stmt EnforceNitroAttestationForConfidentialWorkloads Allow StringEqualsIgnoreCase "${BOTH_COND}"
    info "Negated operators match when the attestation key is absent, so unattested requests are also denied."

    UNGATED=$(echo "${KEY_POLICY}" | jq --arg role "${WORKLOAD_ROLE_ARN}" '[.Statement[]
      | select(.Effect == "Allow" and .Principal.AWS == $role and .Sid != "EnforceNitroAttestationForConfidentialWorkloads")] | length')
    if [ "${UNGATED}" -eq 0 ]; then
      pass "Key policy: no other Allow statement names the workload role directly."
    else
      warn "Key policy: ${UNGATED} other Allow statement(s) name the workload role (explicit Denies still apply)."
    fi
  else
    info "Confidential mode not enabled; attestation statements not expected."
  fi
fi

# ── Check 7: IAM identity policies and KMS grants ─────────────────────────
echo ""
echo "[Check 7/9] Reporting other KMS authorization paths (IAM policies, KMS grants)..."
if [ -n "${WORKLOAD_ROLE_NAME}" ] && [ -n "${KMS_KEY_ARN}" ]; then
  echo "  --- IAM identity-based policies on ${WORKLOAD_ROLE_NAME} ---"
  KMS_STMT_FILTER='.Statement | if type == "object" then [.] else . end | .[]
    | select(.Effect == "Allow")
    | select([.Action] | flatten | any(. == "*" or . == "kms:*" or . == "kms:Decrypt" or . == "kms:GenerateDataKey" or . == "kms:GenerateDataKey*"))
    | "\(.Sid // "no-sid"): Action=\([.Action] | flatten | join(",")), Resource=\([.Resource] | flatten | join(",")), Condition=\(if .Condition then "present" else "none" end)"'
  IAM_LINES=""
  for PARN in $(aws iam list-attached-role-policies --role-name "${WORKLOAD_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
    VER=$(aws iam get-policy --policy-arn "${PARN}" --query Policy.DefaultVersionId --output text 2>/dev/null || echo "")
    DOC=$(aws iam get-policy-version --policy-arn "${PARN}" --version-id "${VER}" --query PolicyVersion.Document --output json 2>/dev/null || echo "{}")
    while IFS= read -r L; do [ -n "${L}" ] && IAM_LINES="${IAM_LINES}${PARN##*/} -> ${L}"$'\n'; done < <(echo "${DOC}" | jq -r "${KMS_STMT_FILTER}" 2>/dev/null || true)
  done
  for PNAME in $(aws iam list-role-policies --role-name "${WORKLOAD_ROLE_NAME}" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
    DOC=$(aws iam get-role-policy --role-name "${WORKLOAD_ROLE_NAME}" --policy-name "${PNAME}" --query PolicyDocument --output json 2>/dev/null || echo "{}")
    while IFS= read -r L; do [ -n "${L}" ] && IAM_LINES="${IAM_LINES}inline:${PNAME} -> ${L}"$'\n'; done < <(echo "${DOC}" | jq -r "${KMS_STMT_FILTER}" 2>/dev/null || true)
  done
  if [ -n "${IAM_LINES}" ]; then
    while IFS= read -r L; do [ -n "${L}" ] && info "IAM Allow: ${L}"; done <<< "${IAM_LINES}"
    info "These IAM Allows are an authorization path via the key-policy root delegation;"
    info "they are subject to the key-policy explicit Deny statements validated in Check 6."
  else
    info "No IAM identity-based Allow for kms:Decrypt/GenerateDataKey on the workload role."
  fi

  echo "  --- KMS grants on ${KMS_KEY_ARN##*/} ---"
  GRANTS=$(aws kms list-grants --key-id "${KMS_KEY_ARN}" --region "${REGION}" --output json 2>/dev/null || echo "")
  if [ -z "${GRANTS}" ]; then
    fail "Could not list KMS grants."
  else
    echo "${GRANTS}" | jq -r '.Grants[] | "  [INFO] Grant to \(.GranteePrincipal): \(.Operations | join(","))"'
    ROLE_GRANTS=$(echo "${GRANTS}" | jq --arg role "${WORKLOAD_ROLE_ARN}" '[.Grants[] | select(.GranteePrincipal == $role and (.Operations | any(. == "Decrypt" or . == "GenerateDataKey")))] | length')
    if [ "${ROLE_GRANTS}" -eq 0 ]; then
      pass "No KMS grant gives the workload role Decrypt/GenerateDataKey."
    else
      warn "${ROLE_GRANTS} KMS grant(s) give the workload role Decrypt/GenerateDataKey (key-policy explicit Denies still apply)."
    fi
  fi
else
  fail "Workload role or KMS key unresolved; cannot inspect IAM policies or grants."
fi

# ── Check 8: Workload IAM trust policy ────────────────────────────────────
echo ""
echo "[Check 8/9] Verifying workload IAM trust policy..."
TRUST_POLICY=""
[ -n "${WORKLOAD_ROLE_NAME}" ] && TRUST_POLICY=$(aws iam get-role --role-name "${WORKLOAD_ROLE_NAME}" --query Role.AssumeRolePolicyDocument --output json 2>/dev/null || echo "")
if [ -z "${TRUST_POLICY}" ]; then
  fail "Could not retrieve workload role trust policy."
else
  STMT_COUNT=$(echo "${TRUST_POLICY}" | jq '.Statement | length')
  PI_COUNT=$(echo "${TRUST_POLICY}" | jq '[.Statement[] | select([.Principal.Service] | flatten | index("pods.eks.amazonaws.com"))] | length')
  if [ "${PI_COUNT}" -ne 1 ]; then
    fail "Expected exactly 1 Pod Identity trust statement, found ${PI_COUNT}."
  else
    TRUST_RESULT=$(echo "${TRUST_POLICY}" | jq -c --arg acct "${EXPECTED_ACCOUNT}" --arg arn "${EXPECTED_CLUSTER_ARN}" '
      .Statement[] | select([.Principal.Service] | flatten | index("pods.eks.amazonaws.com")) | {
        effect:         (.Effect == "Allow"),
        principal:      (.Principal == {"Service": "pods.eks.amazonaws.com"}),
        assume_role:    ([.Action] | flatten | index("sts:AssumeRole") != null),
        tag_session:    ([.Action] | flatten | index("sts:TagSession") != null),
        source_account: (.Condition.StringEquals["aws:SourceAccount"] == $acct),
        source_arn:     ((.Condition.ArnEquals["aws:SourceArn"] // .Condition.ArnLike["aws:SourceArn"] // .Condition.StringEquals["aws:SourceArn"]) == $arn)
      }')
    echo "${TRUST_RESULT}" | jq -e '.effect and .principal' >/dev/null \
      && pass "Pod Identity statement: Effect=Allow, Principal={Service: pods.eks.amazonaws.com}." \
      || fail "Pod Identity statement has unexpected Effect or Principal."
    echo "${TRUST_RESULT}" | jq -e '.assume_role and .tag_session' >/dev/null \
      && pass "Pod Identity statement allows both sts:AssumeRole and sts:TagSession." \
      || fail "Pod Identity statement is missing sts:AssumeRole and/or sts:TagSession: $(echo "${TRUST_RESULT}" | jq -c '{assume_role, tag_session}')."
    echo "${TRUST_RESULT}" | jq -e '.source_account' >/dev/null \
      && pass "Pod Identity statement: aws:SourceAccount = ${EXPECTED_ACCOUNT}." \
      || fail "Pod Identity statement: aws:SourceAccount missing or not '${EXPECTED_ACCOUNT}'."
    echo "${TRUST_RESULT}" | jq -e '.source_arn' >/dev/null \
      && pass "Pod Identity statement: aws:SourceArn = ${EXPECTED_CLUSTER_ARN}." \
      || fail "Pod Identity statement: aws:SourceArn missing or not '${EXPECTED_CLUSTER_ARN}'."
  fi

  if [ "${STMT_COUNT}" -ne "${PI_COUNT}" ]; then
    fail "Trust policy has $((STMT_COUNT - PI_COUNT)) additional statement(s) beyond the Pod Identity statement."
  fi
  ROOT_TRUST=$(echo "${TRUST_POLICY}" | jq '[.Statement[] | select(.Principal.AWS != null) | select([.Principal.AWS] | flatten | any(test(":root$") or . == "*"))] | length')
  if [ "${ROOT_TRUST}" -eq 0 ]; then
    pass "No account-root or wildcard AWS principal in trust policy."
  else
    fail "Trust policy contains an account-root or wildcard AWS principal."
  fi
fi

# ── Check 9: Fresh-pod Pod Identity credentials ───────────────────────────
echo ""
echo "[Check 9/9] Testing that a newly created pod obtains Pod Identity credentials..."
if [ "${SKIP_FRESH_POD_TEST:-0}" == "1" ]; then
  warn "Fresh-pod Pod Identity test skipped (SKIP_FRESH_POD_TEST=1)."
elif [ -z "${WORKLOAD_ROLE_NAME}" ]; then
  fail "Workload role unresolved; cannot run fresh-pod test."
else
  TRUST_UPDATED=$(aws cloudtrail lookup-events --region "${REGION}" \
    --lookup-attributes "AttributeKey=ResourceName,AttributeValue=${WORKLOAD_ROLE_NAME}" --max-results 50 --output json 2>/dev/null \
    | jq -r '[.Events[] | select(.EventName == "UpdateAssumeRolePolicy" or .EventName == "CreateRole") | .EventTime] | max // empty' 2>/dev/null || echo "")
  if [ -n "${TRUST_UPDATED}" ]; then
    TRUST_UPDATED_EPOCH=$(date -u -d "${TRUST_UPDATED}" +%s 2>/dev/null || echo 0)
    info "Last trust-policy change (CloudTrail): $(date -u -d "@${TRUST_UPDATED_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
  else
    TRUST_UPDATED_EPOCH=0
    info "No trust-policy change found in CloudTrail (90-day lookup window)."
  fi

  PROBE="pod-identity-verify-$(date +%s)"
  PROBE_RC_LINE=""
  [ "${ISOLATED_ENABLED}" == "true" ] && PROBE_RC_LINE="runtimeClassName: isolated-sandbox"
  cleanup_probe() { kubectl delete pod -n "${NAMESPACE}" "${PROBE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
  trap cleanup_probe EXIT

  if ! kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE}
  namespace: ${NAMESPACE}
spec:
  ${PROBE_RC_LINE}
  serviceAccountName: ${SERVICE_ACCOUNT}
  restartPolicy: Never
  containers:
  - name: probe
    image: ${FRESH_POD_IMAGE}
    command: ["aws", "sts", "get-caller-identity", "--region", "${REGION}", "--output", "json"]
    resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}
    securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 1000, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
EOF
  then
    fail "Could not create probe pod '${PROBE}'."
  else
    kubectl wait -n "${NAMESPACE}" "pod/${PROBE}" --for=jsonpath='{.status.phase}'=Succeeded --timeout=240s >/dev/null 2>&1 || true
    PROBE_PHASE=$(kubectl get pod -n "${NAMESPACE}" "${PROBE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    PROBE_CREATED=$(kubectl get pod -n "${NAMESPACE}" "${PROBE}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
    PROBE_LOGS=$(kubectl logs -n "${NAMESPACE}" "${PROBE}" 2>&1 || echo "")
    info "Probe pod '${PROBE}' created ${PROBE_CREATED}, phase=${PROBE_PHASE}, runtimeClass=${PROBE_RC_LINE#runtimeClassName: }"
    CREATED_EPOCH=$(date -u -d "${PROBE_CREATED}" +%s 2>/dev/null || echo 0)
    if [ "${CREATED_EPOCH}" -le "${TRUST_UPDATED_EPOCH}" ]; then
      fail "Probe pod was not created after the last trust-policy change."
    fi
    CALLER_ARN=$(echo "${PROBE_LOGS}" | jq -r '.Arn // empty' 2>/dev/null || echo "")
    EXPECTED_PREFIX="arn:${PARTITION}:sts::${EXPECTED_ACCOUNT}:assumed-role/${WORKLOAD_ROLE_NAME}/"
    if [ "${PROBE_PHASE}" == "Succeeded" ] && [[ "${CALLER_ARN}" == "${EXPECTED_PREFIX}"* ]]; then
      pass "[runtime] Fresh pod obtained Pod Identity credentials: ${CALLER_ARN}"
    else
      fail "[runtime] Fresh pod did not obtain workload-role credentials (phase=${PROBE_PHASE}): ${PROBE_LOGS}"
    fi
  fi
fi

finish
