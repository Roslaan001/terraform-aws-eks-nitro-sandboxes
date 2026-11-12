#!/usr/bin/env bash
# ==============================================================================
# Script: verify_sandbox.sh
# Purpose: Verification of AWS Nitro Sandboxes on EKS Auto Mode
#
# Validates observable Kubernetes, IAM, and KMS state, plus two live runtime
# tests (confidential-pod exec denial and fresh-pod Pod Identity credentials).
# It does NOT prove hardware isolation — that is an architectural property of
# the AWS Nitro Hypervisor: https://docs.aws.amazon.com/eks/latest/userguide/sandboxing.html
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
now()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
tf_out() { terraform -chdir="${TF_DIR}" output "$@" 2>/dev/null || echo ""; }
# check <json> <jq-filter> <pass-msg> <fail-msg>: PASS if the filter is true.
check() { if echo "$1" | jq -e "$2" >/dev/null 2>&1; then pass "$3"; else fail "$4"; fi; }

# Single EXIT trap: removes the AWS error file and the probe pod (if created).
PROBE=""
AWS_ERR_FILE=$(mktemp)
cleanup() {
  rm -f "${AWS_ERR_FILE}"
  [ -z "${PROBE}" ] || kubectl delete pod -n "${NAMESPACE}" "${PROBE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT
# aws_json <args>: AWS CLI call with JSON output; on failure, stderr is kept for aws_err.
aws_json() { aws "$@" --output json 2>"${AWS_ERR_FILE}"; }
aws_err()  { tr '\n' ' ' < "${AWS_ERR_FILE}" | sed 's/[[:space:]]*$//'; }

for BIN in kubectl aws jq terraform python3 base64 gzip; do
  command -v "${BIN}" >/dev/null 2>&1 || { echo "Required tool not found: ${BIN}"; exit 2; }
done

finish() {
  echo ""
  echo "Completed at: $(now)"
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
  1. Expected values:            Terraform outputs/variables cross-checked with live EKS;
                                 active kubectl API server == EKS cluster endpoint [config]
  2. RuntimeClass availability:  Kubernetes API [structural]
  3. Node sandbox capacity:      Kubernetes API labels/allocatable; required when a mode is enabled [structural]
  4. Workload posture:           Pods matching the Deployment selector AND owned via its
                                 ReplicaSets: phase, termination, RuntimeClass, replica count [live state]
  5. Cedar runtime_policy:       Strict parse of the generated syntax only; any other action
                                 expression fails closed; no permit may name Exec [structural]
     Exec denial:                kubectl exec rejected by the guest agent [runtime]
  6. KMS key policy:             Exact principal/resource/action/operator/values [structural]
  7. IAM policies & KMS grants:  Managed + inline policies on the workload role only (wildcard-aware);
                                 KMS grants on the key, reported separately [structural]
                                 Not inspected: permissions boundaries, SCPs/RCPs, session
                                 policies, other principals. This is not an account-wide analysis.
  8. IAM trust policy:           Principal, actions, SourceAccount, SourceArn [structural]
  9. Fresh-pod Pod Identity:     New pod obtains workload-role credentials [runtime]

Architectural Boundary Note:
  Hardware isolation is an architectural property of the AWS Nitro Hypervisor and
  cannot be measured from the Kubernetes API or from inside the guest. Guest-level
  observations (e.g. uname) confirm a per-pod kernel; they do not independently
  prove hypervisor-level isolation. This script makes no claim about the specific
  memory-protection technology used by confidential sandboxes.
  KMS recipient-attestation enforcement is verified structurally (policy content).
  End-to-end attested decrypt is PARTIALLY VERIFIED by this script (structure and
  configuration only). The live in-guest test is manual: see tests/attestation-e2e/.
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
echo "Started at: $(now)"
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

EXPECTED_CLUSTER_ARN=$(tf_out -raw eks_cluster_arn)
if ! LIVE_CLUSTER_JSON=$(aws_json eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}"); then
  fail "aws eks describe-cluster failed for '${CLUSTER_NAME}': $(aws_err)"
  finish
fi
LIVE_CLUSTER_ARN=$(echo "${LIVE_CLUSTER_JSON}" | jq -r '.cluster.arn // ""')
EXPECTED_ENDPOINT=$(echo "${LIVE_CLUSTER_JSON}" | jq -r '.cluster.endpoint // ""')
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

# The ARN match only proves Terraform and AWS agree; every kubectl call goes to
# the active context's API server, so that must be this cluster's endpoint.
KUBE_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "<none>")
KUBE_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
normalize_endpoint() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#/+$##; s#:443$##'; }
if [ -z "${EXPECTED_ENDPOINT}" ] || [ -z "${KUBE_SERVER}" ]; then
  fail "Could not resolve API endpoints (EKS='${EXPECTED_ENDPOINT}', kubectl context '${KUBE_CONTEXT}'='${KUBE_SERVER}')."
  finish
elif [ "$(normalize_endpoint "${KUBE_SERVER}")" != "$(normalize_endpoint "${EXPECTED_ENDPOINT}")" ]; then
  fail "WRONG CLUSTER: active kubectl context '${KUBE_CONTEXT}' points to ${KUBE_SERVER},"
  echo "         but EKS cluster '${CLUSTER_NAME}' (${REGION}) has endpoint ${EXPECTED_ENDPOINT}."
  echo "         Kubernetes checks would inspect a different cluster. Run:"
  echo "         aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}"
  finish
fi
pass "Active kubectl context '${KUBE_CONTEXT}' API server matches EKS endpoint: ${EXPECTED_ENDPOINT}"

MODES=$(tf_out -json eks_sandbox_modes | jq -r '.[]' 2>/dev/null || echo "")
[ -n "${MODES}" ] || { fail "Could not read eks_sandbox_modes from Terraform outputs."; finish; }
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
  elif RC_JSON=$(kubectl get runtimeclass "${RC}" -o json 2>/dev/null); then
    pass "RuntimeClass '${RC}' exists (handler: $(echo "${RC_JSON}" | jq -r '.handler // "unknown"'))."
  else
    fail "RuntimeClass '${RC}' not found."
  fi
done

# ── Check 3: Node sandbox capacity ────────────────────────────────────────
echo ""
echo "[Check 3/9] Verifying Nitro sandbox node capacity..."
if ! NODES_JSON=$(kubectl get nodes -l eks.amazonaws.com/nitro-sandbox=true -o json 2>&1); then
  fail "Could not list nodes: ${NODES_JSON}"
  NODES_JSON='{"items":[]}'
fi
echo "${NODES_JSON}" | jq -r '.items[] | "  [+] Node \(.metadata.name): InstanceType=\(.metadata.labels["node.kubernetes.io/instance-type"] // "unknown"), SandboxCapacity=\(.status.capacity["eks.amazonaws.com/nitro-sandbox"] // "0"), Allocatable=\(.status.allocatable["eks.amazonaws.com/nitro-sandbox"] // "0")"'
CAPABLE_NODES=$(echo "${NODES_JSON}" | jq '[.items[] | select(((.status.allocatable["eks.amazonaws.com/nitro-sandbox"] // "0") | tonumber? // 0) > 0)] | length')
if [ "${CAPABLE_NODES}" -gt 0 ]; then
  pass "${CAPABLE_NODES} Nitro Sandbox-capable node(s) (label eks.amazonaws.com/nitro-sandbox=true, allocatable > 0)."
elif [ "${ISOLATED_ENABLED}" == "true" ] || [ "${CONFIDENTIAL_ENABLED}" == "true" ]; then
  fail "Sandbox mode(s) enabled but no Nitro Sandbox-capable node found (label eks.amazonaws.com/nitro-sandbox=true with allocatable eks.amazonaws.com/nitro-sandbox > 0)."
else
  info "No Nitro Sandbox-capable nodes; none required (no sandbox mode enabled)."
fi

# ── Workload helper ───────────────────────────────────────────────────────
# Deployment .spec.selector -> kubectl label-selector string (unknown operators error out).
SELECTOR_TO_STRING='.spec.selector as $s
  | ([($s.matchLabels // {}) | to_entries[] | "\(.key)=\(.value)"]
     + [($s.matchExpressions // [])[]
        | if   .operator == "In"           then "\(.key) in (\(.values | join(",")))"
          elif .operator == "NotIn"        then "\(.key) notin (\(.values | join(",")))"
          elif .operator == "Exists"       then .key
          elif .operator == "DoesNotExist" then "!\(.key)"
          else error("unsupported selector operator \(.operator)") end])
  | join(",")'

# check_workload <mode> <deployment> <runtimeClass>
# Selects pods with the Deployment's own selector and keeps only those whose
# controller is a ReplicaSet controlled by that Deployment (matched by UID).
# Unrelated pods with matching labels are warned about and NOT counted. Each
# owned pod must be Running, not terminating, and use the expected RuntimeClass.
# Sets POD_NAMES (healthy owned pods) and OWNED_PODS_JSON.
check_workload() {
  local mode="$1" deploy="$2" expected_rc="$3" deploy_json desired uid selector rs_json pods_json split
  POD_NAMES=""; OWNED_PODS_JSON='{"items":[]}'
  if ! deploy_json=$(kubectl get deployment -n "${NAMESPACE}" "${deploy}" -o json 2>&1); then
    fail "Deployment '${deploy}' not found in namespace '${NAMESPACE}': ${deploy_json}"; return
  fi
  desired=$(echo "${deploy_json}" | jq -r '.spec.replicas // 1')
  uid=$(echo "${deploy_json}" | jq -r '.metadata.uid')
  if ! selector=$(echo "${deploy_json}" | jq -r "${SELECTOR_TO_STRING}" 2>&1) || [ -z "${selector}" ]; then
    fail "Deployment '${deploy}' selector is empty or unsupported (${selector}); cannot attribute pods."; return
  fi
  info "Deployment '${deploy}' (uid ${uid}) selector: ${selector}"
  if ! rs_json=$(kubectl get replicasets -n "${NAMESPACE}" -l "${selector}" -o json 2>&1); then
    fail "Could not list ReplicaSets for '${deploy}': ${rs_json}"; return
  fi
  if ! pods_json=$(kubectl get pods -n "${NAMESPACE}" -l "${selector}" -o json 2>&1); then
    fail "Could not list pods for '${deploy}': ${pods_json}"; return
  fi
  split=$(printf '%s\n%s\n' "${rs_json}" "${pods_json}" | jq -sc --arg uid "${uid}" '
    def ctrl($kind; $uids): any(.metadata.ownerReferences[]?; .controller == true and .kind == $kind and (.uid as $u | $uids | index($u)));
    .[0] as $rs | .[1] as $pods
    | [$rs.items[] | select(ctrl("Deployment"; [$uid])) | .metadata.uid] as $rsu
    | {rs: ($rsu | length), owned: [$pods.items[] | select(ctrl("ReplicaSet"; $rsu))],
       unowned: [$pods.items[] | select(ctrl("ReplicaSet"; $rsu) | not) | .metadata.name]}')
  OWNED_PODS_JSON=$(echo "${split}" | jq -c '{items: .owned}')
  for u in $(echo "${split}" | jq -r '.unowned[]'); do
    warn "Pod '${u}' matches the selector of '${deploy}' but is not owned by it (via ReplicaSet); excluded from count."
  done

  local count good=0 i=0 name phase node rc deleting
  count=$(echo "${split}" | jq '.owned | length')
  echo "  Deployment '${deploy}' desired replicas: ${desired}; owned ReplicaSets: $(echo "${split}" | jq .rs); owned pods: ${count}"
  if [ "${count}" -eq 0 ]; then
    fail "No ${mode} sandbox pods owned by Deployment '${deploy}' (expected ${desired})."; return
  fi
  while IFS=$'\t' read -r name phase node rc deleting; do
    i=$((i + 1)); [ "${deleting}" == "-" ] && deleting=""
    echo "  --- ${mode} replica ${i}/${count}: ${name} (phase=${phase}, node=${node}, runtimeClass=${rc}) ---"
    local ok=true
    if [ "${phase}" != "Running" ] || [ -n "${deleting}" ]; then
      fail "Pod '${name}' is not Running (phase=${phase}${deleting:+, terminating})."; ok=false
    fi
    if [ "${rc}" != "${expected_rc}" ]; then
      fail "Pod '${name}' uses runtimeClassName='${rc}', expected '${expected_rc}'."; ok=false
    fi
    if [ "${ok}" == "true" ]; then
      pass "Pod '${name}' is Running with runtimeClassName=${expected_rc}."
      good=$((good + 1)); POD_NAMES="${POD_NAMES} ${name}"
    fi
  done < <(echo "${split}" | jq -r '.owned[] | [.metadata.name, .status.phase, (.spec.nodeName // "unscheduled"),
             (.spec.runtimeClassName // "none"), (.metadata.deletionTimestamp // "-")] | @tsv')
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
# Strict structural reader for the Cedar runtime_policy (no Cedar CLI is assumed).
# It tokenizes the policy (so ';' or '//' inside a string cannot hide a statement)
# and accepts ONLY the action syntax emitted by eks-nitro-sandbox-genpolicy:
#   action == Agent::Action::"<Name>"   or   action in [Agent::Action::"<Name>", ...]
# Anything else (bare action, !=, in <group>, is, escapes, other entity types,
# trailing tokens, unbalanced brackets) fails closed. Stdin: decoded envelope JSON.
# Stdout: {ok, error, permits, forbids, exec_permitted}. NOT a Cedar evaluator;
# the live kubectl exec test below is the runtime verification.
CEDAR_PY=$(cat <<'PY'
import json, re, sys
TOK = re.compile(r'\s+|//[^\n]*|(?P<t>"(?:[^"\\\n]|\\.)*"|[A-Za-z_]\w*|\d+|::|==|!=|<=|>=|&&|\|\||[()\[\]{},;@.<>!+\-*%])')
PAIRS = {"(": ")", "[": "]", "{": "}"}
REF = r'Agent :: Action :: "[A-Za-z][A-Za-z0-9]*"'
class Reject(Exception): pass

def tokenize(src):
    toks, i = [], 0
    while i < len(src):
        m = TOK.match(src, i)
        if not m: raise Reject(f"unrecognised character {src[i]!r} at offset {i}")
        if m.group("t"): toks.append(m.group("t"))
        i = m.end()
    return toks

def close(toks, i):  # index of the bracket matching toks[i]
    stack = []
    for j in range(i, len(toks)):
        if toks[j] in PAIRS: stack.append(PAIRS[toks[j]])
        elif toks[j] in ")]}":
            if not stack or stack.pop() != toks[j]: raise Reject("unbalanced brackets")
            if not stack: return j
    raise Reject("unterminated bracket")

def statements(toks):
    i = 0
    while i < len(toks):
        while toks[i] == "@":  # annotation: @name("string")
            if not (len(toks) > i + 4 and re.fullmatch(r"\w+", toks[i+1]) and toks[i+2] == "("
                    and toks[i+3].startswith('"') and toks[i+4] == ")"): raise Reject("malformed annotation")
            i += 5
        effect = toks[i]
        if effect not in ("permit", "forbid"): raise Reject(f"expected permit/forbid, found {effect!r}")
        if i + 1 >= len(toks) or toks[i+1] != "(": raise Reject(f"{effect}: expected '('")
        end = close(toks, i + 1)
        scope, i = toks[i+2:end], end + 1
        while i < len(toks) and toks[i] in ("when", "unless"):
            if i + 1 >= len(toks) or toks[i+1] != "{": raise Reject(f"{effect}: expected '{{' after {toks[i]}")
            i = close(toks, i + 1) + 1
        if i >= len(toks) or toks[i] != ";": raise Reject(f"{effect}: expected ';' after statement")
        i += 1
        parts, depth, cur = [], 0, []
        for t in scope:
            depth += (t in PAIRS) - (t in ")]}")
            if t == "," and depth == 0: parts.append(cur); cur = []
            else: cur.append(t)
        parts.append(cur)
        if len(parts) != 3 or parts[0][:1] != ["principal"] or parts[2][:1] != ["resource"]:
            raise Reject(f"{effect}: scope is not (principal..., action..., resource...)")
        yield effect, " ".join(parts[1])

def permit_actions(expr):
    if expr == "action": raise Reject("unconstrained action (permits every action, including Exec)")
    if not (re.fullmatch(rf"action == {REF}", expr) or re.fullmatch(rf"action in \[ {REF}( , {REF})* \]", expr)):
        raise Reject(f"unsupported action expression: {expr}")
    return re.findall(r'"([A-Za-z0-9]+)"', expr)

out = {"ok": False, "error": None, "permits": [], "forbids": 0, "exec_permitted": False}
try:
    policy = json.load(sys.stdin)["runtime_policy"]
    if not isinstance(policy, str): raise Reject("runtime_policy is not a string")
    stmts = list(statements(tokenize(policy)))
    if not stmts: raise Reject("no statements found")
    for effect, expr in stmts:
        if effect == "forbid": out["forbids"] += 1
        else: out["permits"] += permit_actions(expr)
    out.update(ok=True, exec_permitted="Exec" in out["permits"])
except Exception as e:
    out["error"] = str(e) if isinstance(e, Reject) else f"{type(e).__name__}: {e}"
print(json.dumps(out))
PY
)

if [ "${CONFIDENTIAL_ENABLED}" == "true" ]; then
  check_workload confidential nitro-sandbox-confidential confidential-sandbox
  for POD in ${POD_NAMES}; do
    echo "  --- Cedar / exec checks: ${POD} ---"
    CEDAR_RAW=$(echo "${OWNED_PODS_JSON}" | jq -r --arg p "${POD}" '.items[] | select(.metadata.name == $p) | .metadata.annotations["sandbox.amazonaws.com/policy"] // ""')
    CEDAR_JSON=$(echo "${CEDAR_RAW}" | base64 -d 2>/dev/null | gzip -d 2>/dev/null || echo "")
    PARSED=$(echo "${CEDAR_JSON}" | python3 -I -c "${CEDAR_PY}" 2>&1 || echo "")
    if [ -z "${CEDAR_RAW}" ]; then
      fail "Pod '${POD}' is missing 'sandbox.amazonaws.com/policy' annotation."
    elif ! echo "${CEDAR_JSON}" | jq -e 'has("admission_policy") and has("runtime_policy")' >/dev/null 2>&1; then
      fail "Cedar annotation on '${POD}' is not a valid gzip+base64 envelope with admission_policy and runtime_policy."
    elif ! echo "${PARSED}" | jq -e 'has("ok")' >/dev/null 2>&1; then
      fail "[structural] Cedar parser did not run: ${PARSED}"
    elif [ "$(echo "${PARSED}" | jq -r '.ok')" != "true" ]; then
      fail "[structural] runtime_policy could not be confidently interpreted ($(echo "${PARSED}" | jq -r '.error')); cannot rule out an Exec permit."
    else
      info "runtime_policy permit actions: $(echo "${PARSED}" | jq -r '.permits | join(", ")') (forbid statements: $(echo "${PARSED}" | jq -r '.forbids'))"
      check "${PARSED}" '.exec_permitted | not' \
        "[structural] Every permit uses an exact Agent::Action literal (== or in [list]) and none is Exec; Exec falls to Cedar default-deny." \
        "[structural] runtime_policy contains a permit for Agent::Action::\"Exec\"."
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
KMS_KEY_ARN=$(tf_out -raw eks_kms_key_arn)
KEY_POLICY=""
if [ -z "${KMS_KEY_ARN}" ]; then
  fail "Could not retrieve KMS key ARN from Terraform outputs."
else
  info "KMS key: ${KMS_KEY_ARN}"
  KEY_POLICY=$(aws kms get-key-policy --key-id "${KMS_KEY_ARN}" --policy-name default --region "${REGION}" --query Policy --output text 2>/dev/null || echo "")
  [ -n "${KEY_POLICY}" ] || fail "Could not retrieve KMS key policy."
fi

# validate_key_stmt <sid> <effect> <operator> <expected-condition-json>
validate_key_stmt() {
  local sid="$1" effect="$2" op="$3" cond="$4" n result
  n=$(echo "${KEY_POLICY}" | jq --arg sid "${sid}" '[.Statement[] | select(.Sid == $sid)] | length')
  [ "${n}" -eq 1 ] || { fail "Sid '${sid}': expected exactly 1 statement, found ${n}."; return; }
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
  check "${result}" 'all(.[]; . == true)' \
    "Sid '${sid}': Effect=${effect}, Principal=workload role (exact), Resource=*, Action=[kms:Decrypt,kms:GenerateDataKey], ${op} ${cond}" \
    "Sid '${sid}' mismatch: $(echo "${result}" | jq -c 'with_entries(select(.value != true)) | keys') failed."
}

if [ -n "${KEY_POLICY}" ] && [ -n "${WORKLOAD_ROLE_ARN}" ]; then
  if echo "${KEY_POLICY}" | jq -e --arg r "arn:${PARTITION}:iam::${EXPECTED_ACCOUNT}:root" \
       'any(.Statement[]; .Effect == "Allow" and .Principal.AWS == $r)' >/dev/null; then
    info "Key policy contains an account-root Allow (EnableIAMUserPermissions): KMS authorization is"
    info "delegated to IAM policies, so the gated Allow below is NOT the only authorization path."
    info "The two explicit Deny statements are the critical attestation enforcement controls."
  fi

  if [ "${CONFIDENTIAL_ENABLED}" == "true" ] && [ -n "${EXPECTED_PCR17:-}" ]; then
    PCR17_KEY="kms:RecipientAttestation:PCR17"; PCR8_KEY="kms:RecipientAttestation:PCR8:ServiceName"
    validate_key_stmt DenyConfidentialWorkloadMismatchedPCR17 Deny StringNotEqualsIgnoreCase \
      "$(jq -nc --arg k "${PCR17_KEY}" --arg v "${EXPECTED_PCR17}" '{($k): $v}')"
    validate_key_stmt DenyConfidentialWorkloadMismatchedPCR8 Deny StringNotEqualsIgnoreCase \
      "$(jq -nc --arg k "${PCR8_KEY}" --arg v "${EXPECTED_PCR8_SERVICE}" '{($k): $v}')"
    validate_key_stmt EnforceNitroAttestationForConfidentialWorkloads Allow StringEqualsIgnoreCase \
      "$(jq -nc --arg k1 "${PCR17_KEY}" --arg v1 "${EXPECTED_PCR17}" --arg k2 "${PCR8_KEY}" --arg v2 "${EXPECTED_PCR8_SERVICE}" '{($k1): $v1, ($k2): $v2}')"
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
  echo "  --- IAM identity-based policies on ${WORKLOAD_ROLE_NAME} (managed + inline) ---"
  # Allow statements whose Action (IAM wildcards * and ?, case-insensitive) or
  # NotAction (grants everything NOT listed) covers kms:Decrypt or kms:GenerateDataKey.
  # Resource and Condition are reported, not evaluated.
  KMS_STMT_FILTER='
    def glob_re: ascii_downcase | gsub("(?<c>[^a-z0-9:*?])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".") | "^" + . + "$";
    def covers($t): any(.[]; . as $p | $t | ascii_downcase | test($p | glob_re));
    (.Statement | if type == "object" then [.] else . end) | .[]
    | select(.Effect == "Allow")
    | ([.Action // empty] | flatten) as $act | ([.NotAction // empty] | flatten) as $nact
    | [ "kms:Decrypt", "kms:GenerateDataKey" | . as $t
        | select(if ($act | length) > 0 then ($act | covers($t)) elif ($nact | length) > 0 then ($nact | covers($t) | not) else false end) ] as $hit
    | select($hit | length > 0)
    | "\(.Sid // "no-sid"): covers \($hit | join(",")) via \(if ($act | length) > 0 then "Action" else "NotAction" end)=\([.Action // .NotAction] | flatten | join(",")), \(if .NotResource then "NotResource" else "Resource" end)=\([.Resource // .NotResource] | flatten | join(",")), Condition=\(if .Condition then "present" else "none" end)"'
  IAM_LINES=""; IAM_INCOMPLETE=0
  iam_incomplete() { fail "IAM inspection INCOMPLETE: $1"; IAM_INCOMPLETE=1; }
  # scan_policy_doc <label> <policy-document-json>
  scan_policy_doc() {
    local lines
    if ! lines=$(echo "$2" | jq -r "${KMS_STMT_FILTER}" 2>&1); then
      iam_incomplete "could not evaluate policy document '$1': ${lines}"; return
    fi
    while IFS= read -r L; do [ -n "${L}" ] && IAM_LINES="${IAM_LINES}$1 -> ${L}"$'\n'; done <<< "${lines}"
  }

  # Counters: incremented once per policy document successfully retrieved.
  MANAGED_COUNT=0; INLINE_COUNT=0
  if ! ATTACHED=$(aws_json iam list-attached-role-policies --role-name "${WORKLOAD_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn'); then
    iam_incomplete "list-attached-role-policies failed: $(aws_err)"; MANAGED_COUNT="NOT ENUMERATED"
  else
    for PARN in $(echo "${ATTACHED}" | jq -r '.[]'); do
      if ! VER=$(aws_json iam get-policy --policy-arn "${PARN}" --query Policy.DefaultVersionId) \
         || [ "$(echo "${VER}" | jq -r 'type')" != "string" ]; then
        iam_incomplete "get-policy failed for ${PARN}: $(aws_err)"; continue
      fi
      if ! DOC=$(aws_json iam get-policy-version --policy-arn "${PARN}" --version-id "$(echo "${VER}" | jq -r .)" --query PolicyVersion.Document); then
        iam_incomplete "get-policy-version failed for ${PARN}: $(aws_err)"; continue
      fi
      MANAGED_COUNT=$((MANAGED_COUNT + 1)); scan_policy_doc "${PARN##*/}" "${DOC}"
    done
  fi
  if ! INLINE=$(aws_json iam list-role-policies --role-name "${WORKLOAD_ROLE_NAME}" --query 'PolicyNames'); then
    iam_incomplete "list-role-policies failed: $(aws_err)"; INLINE_COUNT="NOT ENUMERATED"
  else
    for PNAME in $(echo "${INLINE}" | jq -r '.[]'); do
      if ! DOC=$(aws_json iam get-role-policy --role-name "${WORKLOAD_ROLE_NAME}" --policy-name "${PNAME}" --query PolicyDocument); then
        iam_incomplete "get-role-policy failed for inline '${PNAME}': $(aws_err)"; continue
      fi
      INLINE_COUNT=$((INLINE_COUNT + 1)); scan_policy_doc "inline:${PNAME}" "${DOC}"
    done
  fi
  info "Policy documents retrieved and inspected on ${WORKLOAD_ROLE_NAME}: managed=${MANAGED_COUNT}, inline=${INLINE_COUNT}."

  if [ -n "${IAM_LINES}" ]; then
    while IFS= read -r L; do [ -n "${L}" ] && info "IAM Allow: ${L}"; done <<< "${IAM_LINES}"
    info "These IAM Allows are an authorization path via the key-policy root delegation;"
    info "they are subject to the key-policy explicit Deny statements validated in Check 6."
  fi
  if [ "${IAM_INCOMPLETE}" -eq 1 ]; then
    fail "IAM inspection of ${WORKLOAD_ROLE_NAME} is INCOMPLETE; absence of KMS Allows above is NOT established."
  elif [ -z "${IAM_LINES}" ]; then
    pass "No managed or inline policy on ${WORKLOAD_ROLE_NAME} allows kms:Decrypt/GenerateDataKey (wildcards and NotAction considered)."
  fi
  info "Scope: this role's identity policies only. Permissions boundaries, SCPs/RCPs, session policies"
  info "and other principals are not inspected; this is not an account-wide authorization analysis."

  echo "  --- KMS grants on ${KMS_KEY_ARN##*/} ---"
  if ! GRANTS=$(aws_json kms list-grants --key-id "${KMS_KEY_ARN}" --region "${REGION}"); then
    fail "Could not list KMS grants: $(aws_err)"
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
    T=$(echo "${TRUST_POLICY}" | jq -c --arg acct "${EXPECTED_ACCOUNT}" --arg arn "${EXPECTED_CLUSTER_ARN}" '
      .Statement[] | select([.Principal.Service] | flatten | index("pods.eks.amazonaws.com")) | {
        effect:         (.Effect == "Allow"),
        principal:      (.Principal == {"Service": "pods.eks.amazonaws.com"}),
        assume_role:    ([.Action] | flatten | index("sts:AssumeRole") != null),
        tag_session:    ([.Action] | flatten | index("sts:TagSession") != null),
        source_account: (.Condition.StringEquals["aws:SourceAccount"] == $acct),
        source_arn:     ((.Condition.ArnEquals["aws:SourceArn"] // .Condition.ArnLike["aws:SourceArn"] // .Condition.StringEquals["aws:SourceArn"]) == $arn)
      }')
    check "${T}" '.effect and .principal' "Pod Identity statement: Effect=Allow, Principal={Service: pods.eks.amazonaws.com}." \
      "Pod Identity statement has unexpected Effect or Principal."
    check "${T}" '.assume_role and .tag_session' "Pod Identity statement allows both sts:AssumeRole and sts:TagSession." \
      "Pod Identity statement is missing sts:AssumeRole and/or sts:TagSession: $(echo "${T}" | jq -c '{assume_role, tag_session}')."
    check "${T}" '.source_account' "Pod Identity statement: aws:SourceAccount = ${EXPECTED_ACCOUNT}." \
      "Pod Identity statement: aws:SourceAccount missing or not '${EXPECTED_ACCOUNT}'."
    check "${T}" '.source_arn' "Pod Identity statement: aws:SourceArn = ${EXPECTED_CLUSTER_ARN}." \
      "Pod Identity statement: aws:SourceArn missing or not '${EXPECTED_CLUSTER_ARN}'."
  fi
  [ "${STMT_COUNT}" -eq "${PI_COUNT}" ] || fail "Trust policy has $((STMT_COUNT - PI_COUNT)) additional statement(s) beyond the Pod Identity statement."
  check "${TRUST_POLICY}" '[.Statement[] | select(.Principal.AWS != null) | [.Principal.AWS] | flatten | .[] | select(test(":root$") or . == "*")] | length == 0' \
    "No account-root or wildcard AWS principal in trust policy." \
    "Trust policy contains an account-root or wildcard AWS principal."
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
  TRUST_UPDATED_EPOCH=0
  if [ -n "${TRUST_UPDATED}" ]; then
    TRUST_UPDATED_EPOCH=$(date -u -d "${TRUST_UPDATED}" +%s 2>/dev/null || echo 0)
    info "Last trust-policy change (CloudTrail): $(date -u -d "@${TRUST_UPDATED_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
  else
    info "No trust-policy change found in CloudTrail (90-day lookup window)."
  fi

  PROBE="pod-identity-verify-$(date +%s)"   # deleted by the EXIT trap (cleanup)
  PROBE_RC_LINE=""
  [ "${ISOLATED_ENABLED}" == "true" ] && PROBE_RC_LINE="runtimeClassName: isolated-sandbox"
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
    [ "${CREATED_EPOCH}" -gt "${TRUST_UPDATED_EPOCH}" ] || fail "Probe pod was not created after the last trust-policy change."
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
