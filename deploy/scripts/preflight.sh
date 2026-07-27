#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: preflight.sh --context CONTEXT

Required environment:
  RWX_STORAGE_CLASS  Existing ReadWriteMany-capable StorageClass
  CPU_AGENTPOOL      Value of the agentpool label for CPU-only nodes
  MODEL_ENDPOINT     Cluster-local chat-completions URL
  MODEL_ID           Provider model identifier
  ADMIN_LOGIN        GitHub login allowed to use chat and traces
  OAUTH_CLIENT_ID    Dedicated demo OAuth application client ID
  OAUTH_REDIRECT_URL Dedicated demo OAuth callback URL

Optional environment:
  DASHBOARD_NAMESPACE  Default: capz-orka-demo
  RELEASE_NAME         Default: capz-orka-demo
  ORKA_NAMESPACE       Default: orka-system
  ORKA_SERVICE         Default: orka
  ALLOW_UNKNOWN_RWX_STORAGE_CLASS=true
USAGE
}

context=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      [[ $# -ge 2 ]] || fail "--context requires a value"
      context=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

require_command kubectl
require_command helm
require_command jq
require_command python3
require_command grep
load_versions
context=$(require_context "$context")
require_install_inputs

namespace=${DASHBOARD_NAMESPACE:-capz-orka-demo}
release=${RELEASE_NAME:-capz-orka-demo}
refuse_h100 "$namespace"
refuse_h100 "$release"
orka_namespace=${ORKA_NAMESPACE:-orka-system}
orka_service=${ORKA_SERVICE:-orka}

if kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1; then
  fail "target namespace already exists; initial acceptance requires a new namespace: $namespace"
fi

if helm --kube-context "$context" list --all-namespaces -o json | jq -e --arg release "$release" '.[] | select(.name == $release)' >/dev/null; then
  fail "a Helm release named $release already exists in the cluster"
fi

writers=$(kubectl --context "$context" get deployments.apps,cronjobs.batch --all-namespaces \
  -l "app.kubernetes.io/instance=$release" -o json)
if jq -e '.items | length > 0' <<<"$writers" >/dev/null; then
  fail "an existing worker or CronJob uses release label $release"
fi

storage=$(kubectl --context "$context" get storageclass "$RWX_STORAGE_CLASS" -o json)
provisioner=$(jq -r '.provisioner' <<<"$storage")
case "$provisioner" in
  file.csi.azure.com|kubernetes.io/azure-file|nfs.csi.k8s.io|efs.csi.aws.com|filestore.csi.storage.gke.io|cephfs.csi.ceph.com)
    info "RWX StorageClass: $RWX_STORAGE_CLASS ($provisioner)"
    ;;
  disk.csi.azure.com|kubernetes.io/azure-disk|ebs.csi.aws.com|pd.csi.storage.gke.io|rbd.csi.ceph.com)
    fail "StorageClass $RWX_STORAGE_CLASS uses block provisioner $provisioner and is not suitable for ReadWriteMany"
    ;;
  *)
    [[ ${ALLOW_UNKNOWN_RWX_STORAGE_CLASS:-false} == true ]] || fail "unrecognized RWX provisioner $provisioner; set ALLOW_UNKNOWN_RWX_STORAGE_CLASS=true only after operator verification"
    info "operator-approved RWX StorageClass: $RWX_STORAGE_CLASS ($provisioner)"
    ;;
esac

nodes=$(kubectl --context "$context" get nodes -l "agentpool=$CPU_AGENTPOOL" -o json)
ready_nodes=$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$nodes")
[[ $ready_nodes -gt 0 ]] || fail "no Ready nodes match agentpool=$CPU_AGENTPOOL"
if ! jq -e '[.items[].status.capacity | to_entries[]? | select(.key | test("gpu|nvidia|amd.com/gpu|xilinx"; "i"))] | length == 0' <<<"$nodes" >/dev/null; then
  fail "agentpool=$CPU_AGENTPOOL advertises accelerator capacity; select a CPU-only pool"
fi
info "CPU placement: $ready_nodes Ready node(s) match agentpool=$CPU_AGENTPOOL"

for crd in tasks.core.orka.ai agents.core.orka.ai; do
  kubectl --context "$context" get crd "$crd" >/dev/null
  info "Orka CRD present: $crd"
done
agent_crd=$(kubectl --context "$context" get crd agents.core.orka.ai -o json)
jq -e '[.. | strings | select(. == "opencode")] | length > 0' <<<"$agent_crd" >/dev/null || fail "Orka Agent CRD does not advertise runtime type opencode"

kubectl --context "$context" -n "$orka_namespace" get service "$orka_service" >/dev/null
orka_endpoints=$(kubectl --context "$context" -n "$orka_namespace" get endpointslices.discovery.k8s.io \
  -l "kubernetes.io/service-name=$orka_service" -o json)
jq -e '[.items[].endpoints[]? | select(.conditions.ready != false) | .addresses[]?] | length > 0' <<<"$orka_endpoints" >/dev/null || fail "Orka Service has no ready endpoints"

orka_workloads=$(kubectl --context "$context" -n "$orka_namespace" get deployments.apps,statefulsets.apps,daemonsets.apps -o json)
if ! jq -r '.. | strings' <<<"$orka_workloads" | grep -Fqi "${ORKA_REQUIRED_COMMIT:0:7}"; then
  fail "Orka workloads do not expose required commit ${ORKA_REQUIRED_COMMIT:0:7} in an image, label, annotation, or environment value"
fi
info "Orka required commit marker found: ${ORKA_REQUIRED_COMMIT:0:7}"

kubectl --context "$context" api-resources --api-group=admissionregistration.k8s.io -o name \
  | grep -Fxq 'validatingadmissionpolicies.admissionregistration.k8s.io' \
  || fail "cluster does not support ValidatingAdmissionPolicy"

for permission in \
  'create namespaces' \
  'create validatingadmissionpolicies.admissionregistration.k8s.io' \
  'create validatingadmissionpolicybindings.admissionregistration.k8s.io'; do
  verb=${permission%% *}
  resource=${permission#* }
  [[ $(kubectl --context "$context" auth can-i "$verb" "$resource") == yes ]] || fail "current identity cannot $verb $resource"
done

for resource in secrets configmaps deployments.apps cronjobs.batch jobs.batch persistentvolumeclaims services serviceaccounts; do
  [[ $(kubectl --context "$context" auth can-i create "$resource" -n "$namespace") == yes ]] || fail "current identity cannot create $resource in $namespace"
done

read -r model_service model_namespace < <(python3 - "$MODEL_ENDPOINT" <<'PY'
import sys
from urllib.parse import urlparse
url = urlparse(sys.argv[1])
parts = (url.hostname or "").split(".")
if url.scheme not in {"http", "https"} or len(parts) < 4 or parts[2] != "svc":
    raise SystemExit("MODEL_ENDPOINT must use <service>.<namespace>.svc cluster DNS")
print(parts[0], parts[1])
PY
)
kubectl --context "$context" -n "$model_namespace" get service "$model_service" >/dev/null
model_endpoints=$(kubectl --context "$context" -n "$model_namespace" get endpointslices.discovery.k8s.io \
  -l "kubernetes.io/service-name=$model_service" -o json)
jq -e '[.items[].endpoints[]? | select(.conditions.ready != false) | .addresses[]?] | length > 0' <<<"$model_endpoints" >/dev/null || fail "model Service has no ready endpoints"
info "model Service resolves to ready endpoints: $model_service.$model_namespace.svc"

rendered=$(mktemp "${TMPDIR:-/tmp}/capz-orka-preflight.XXXXXX.yaml")
trap 'unlink "$rendered" 2>/dev/null || true' EXIT
"$SCRIPT_DIR/render.sh" --output "$rendered"
grep -Fq 'resources: ["tasks"]' "$rendered" || fail "rendered analysis Role is missing Task access"
grep -Fq 'verbs: ["create", "get", "list", "watch", "patch", "delete"]' "$rendered" || fail "rendered analysis Task verbs are incomplete"
grep -Fq 'name: ORKA_API_TOKEN_FILE' "$rendered" || fail "rendered fetcher does not use projected ServiceAccount authentication"
if grep -Eq '^[[:space:]]*- name: ORKA_API_TOKEN$' "$rendered"; then
  fail "rendered fetcher uses a static Orka API token"
fi

analysis_namespace=$(awk '
  $1 == "kind:" { kind=$2; name="" }
  kind == "Namespace" && $1 == "name:" { name=$2 }
  kind == "Namespace" && $0 ~ /app.kubernetes.io\/component: orka-container-analysis/ { print name; exit }
' "$rendered")
[[ -n $analysis_namespace ]] || fail "could not determine rendered analysis namespace"
for resource in roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io secrets configmaps; do
  [[ $(kubectl --context "$context" auth can-i create "$resource" -n "$analysis_namespace") == yes ]] || fail "current identity cannot create $resource in $analysis_namespace"
done

info "preflight passed for context $context"
info "target release: $namespace/$release"
info "rendered analysis namespace: $analysis_namespace"
info "live ServiceAccount Task RBAC will be verified after Helm creates the release"
