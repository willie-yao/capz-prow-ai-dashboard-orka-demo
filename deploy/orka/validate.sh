#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/orka/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: validate.sh --context CONTEXT [--release NAME] [--namespace NAME]" >&2
}

context=
release=orka
namespace=orka-system
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context=${2:-}
      shift 2
      ;;
    --release)
      release=${2:-}
      shift 2
      ;;
    --namespace)
      namespace=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

load_orka_versions
require_commands helm kubectl jq curl
require_context "${context}"
require_release_configuration

release_info=$(helm list --kube-context "${context}" --namespace "${namespace}" \
  --filter "^${release}$" --output json)
chart_name=$(jq -er \
  'if length == 1 then .[0].chart else error("expected one release") end' \
  <<<"${release_info}")
if [[ "${chart_name}" != orka-* ]]; then
  echo "release ${namespace}/${release} is not an Orka chart release" >&2
  exit 1
fi

for crd in "${EXPECTED_CRDS[@]}"; do
  kubectl --context "${context}" wait --for=condition=Established \
    --timeout=60s "crd/${crd}" >/dev/null
done

controller_selector="app.kubernetes.io/instance=${release},app.kubernetes.io/component=controller"
harness_selector="app.kubernetes.io/instance=${release},app.kubernetes.io/component=agent-harness-wrapper"
kubectl --context "${context}" --namespace "${namespace}" wait \
  --for=condition=Available --timeout=180s deployment \
  -l "${controller_selector}" >/dev/null
kubectl --context "${context}" --namespace "${namespace}" wait \
  --for=condition=Available --timeout=180s deployment \
  -l "${harness_selector}" >/dev/null

service_name=$(kubectl --context "${context}" --namespace "${namespace}" get service \
  -l "app.kubernetes.io/instance=${release},app.kubernetes.io/name=orka" \
  -o json | jq -er \
  '.items | if length == 1 then .[0].metadata.name else error("expected one Orka REST Service") end')

persistence_enabled=$(helm get values "${release}" --kube-context "${context}" \
  --namespace "${namespace}" --all --output json | jq -r '.store.persistence.enabled')
if [[ "${persistence_enabled}" == "true" ]]; then
  pvc_count=$(kubectl --context "${context}" --namespace "${namespace}" get pvc \
    -l "app.kubernetes.io/instance=${release},app.kubernetes.io/name=orka" \
    -o json | jq '[.items[] | select(.status.phase == "Bound")] | length')
  if [[ "${pvc_count}" -lt 1 ]]; then
    echo "Orka persistence is enabled but no Bound PVC was found" >&2
    exit 1
  fi
fi

controller_role=$(kubectl --context "${context}" get clusterrole \
  -l "app.kubernetes.io/instance=${release},app.kubernetes.io/name=orka" \
  -o json | jq -er \
  '[.items[] | select(.metadata.name | endswith("-controller-role"))] | \
   if length == 1 then .[0] else error("expected one controller ClusterRole") end')
for resource in agentruntimes substrateactorpools; do
  if ! jq -e --arg resource "${resource}" \
    'any(.rules[]?; ((.apiGroups // []) | index("core.orka.ai")) and ((.resources // []) | index($resource)))' \
    <<<"${controller_role}" >/dev/null; then
    echo "controller RBAC is missing ${resource}" >&2
    exit 1
  fi
done

worker_accounts=$(kubectl --context "${context}" --namespace "${namespace}" \
  get serviceaccount \
  -l "app.kubernetes.io/instance=${release},orka.ai/worker=true" \
  -o json | jq '.items | length')
if [[ "${worker_accounts}" -lt 3 ]]; then
  echo "expected at least three Orka worker ServiceAccounts" >&2
  exit 1
fi
worker_roles=$(kubectl --context "${context}" get clusterrole \
  -l "app.kubernetes.io/instance=${release},app.kubernetes.io/name=orka" \
  -o json | jq \
  '[.items[] | select(.metadata.name | test("worker-role$"))] | length')
if [[ "${worker_roles}" -lt 3 ]]; then
  echo "expected at least three Orka worker ClusterRoles" >&2
  exit 1
fi

manifest=$(helm get manifest "${release}" --kube-context "${context}" \
  --namespace "${namespace}")
expected_image_refs=(
  "ghcr.io/orka-agents/orka:${ORKA_CHART_VERSION}"
  "ghcr.io/orka-agents/orka/ai-worker:${ORKA_CHART_VERSION}"
  "ghcr.io/orka-agents/orka/general-worker:${ORKA_CHART_VERSION}"
  "ghcr.io/orka-agents/orka/agent-harness-wrapper:${ORKA_CHART_VERSION}"
)
for expected_image_ref in "${expected_image_refs[@]}"; do
  if ! grep -Fq "${expected_image_ref}" <<<"${manifest}"; then
    echo "installed manifest is missing pinned runtime image ${expected_image_ref}" >&2
    exit 1
  fi
done

port_log=$(mktemp)
kubectl --context "${context}" --namespace "${namespace}" port-forward \
  "service/${service_name}" :8080 >"${port_log}" 2>&1 &
port_forward_pid=$!
cleanup_port_forward() {
  kill "${port_forward_pid}" 2>/dev/null || true
  wait "${port_forward_pid}" 2>/dev/null || true
  rm -f "${port_log}"
}
trap cleanup_port_forward EXIT
local_port=
for _ in {1..30}; do
  local_port=$(sed -nE \
    's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$/\1/p' \
    "${port_log}" | head -n 1)
  if [[ -n "${local_port}" ]]; then
    break
  fi
  sleep 1
done
if [[ -z "${local_port}" ]]; then
  echo "Orka REST Service port-forward did not become ready" >&2
  cat "${port_log}" >&2
  exit 1
fi
curl --fail --silent --show-error \
  "http://127.0.0.1:${local_port}/v1/health" >/dev/null

expected_running_digests=(
  "${ORKA_CONTROLLER_DIGEST}"
  "${ORKA_HARNESS_WRAPPER_DIGEST}"
)
for expected_digest in "${expected_running_digests[@]}"; do
  if ! kubectl --context "${context}" --namespace "${namespace}" get pods \
    -l "app.kubernetes.io/instance=${release}" -o json | \
    jq -e --arg digest "${expected_digest}" \
    'any(.items[].status.containerStatuses[]?; (.imageID // "") | contains($digest))' \
    >/dev/null; then
    echo "running Orka pod does not match pinned digest ${expected_digest}" >&2
    exit 1
  fi
done

echo "Validated Orka release ${namespace}/${release} on context ${context}."
