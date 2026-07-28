#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/orka/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: install.sh --context CONTEXT [--release NAME] [--namespace NAME] [--yes]" >&2
}

context=
release=orka
namespace=orka-system
assume_yes=false
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
    --yes)
      assume_yes=true
      shift
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

if [[ -z "${release}" || -z "${namespace}" ]]; then
  usage
  exit 2
fi

printf 'Kubernetes context: %s\n' "${context}"
printf 'Helm release:       %s\n' "${release}"
printf 'Namespace:          %s\n' "${namespace}"
printf 'Chart version:      %s\n' "${ORKA_CHART_VERSION}"
printf 'Chart reference:    %s\n' "${ORKA_CHART_REFERENCE}"

existing_releases=$(helm list --kube-context "${context}" --all-namespaces --output json)
if jq -e '[.[] | select((.chart // "") | startswith("orka-"))] | length > 0' \
  <<<"${existing_releases}" >/dev/null; then
  echo "an Orka Helm release already exists; use the guarded upgrade workflow" >&2
  jq -r '.[] | select((.chart // "") | startswith("orka-")) | "  release=\(.name) namespace=\(.namespace) chart=\(.chart)"' \
    <<<"${existing_releases}" >&2
  exit 1
fi

existing_deployments=$(kubectl --context "${context}" get deployments --all-namespaces \
  -l app.kubernetes.io/name=orka -o json)
if jq -e '.items | length > 0' <<<"${existing_deployments}" >/dev/null; then
  echo "an existing Orka controller or harness deployment was found" >&2
  jq -r '.items[] | "  deployment=\(.metadata.namespace)/\(.metadata.name)"' \
    <<<"${existing_deployments}" >&2
  exit 1
fi

storage_class=$(awk '$1 == "storageClass:" {gsub(/"/, "", $2); print $2; exit}' \
  "${SCRIPT_DIR}/values.yaml")
if [[ -n "${storage_class}" ]]; then
  kubectl --context "${context}" get storageclass "${storage_class}" >/dev/null
elif ! kubectl --context "${context}" get storageclass -o json | jq -e \
  'any(.items[].metadata.annotations // {} | .["storageclass.kubernetes.io/is-default-class"] == "true" or .["storageclass.beta.kubernetes.io/is-default-class"] == "true")' \
  >/dev/null; then
  echo "persistence is enabled but the cluster has no default StorageClass" >&2
  exit 1
fi

confirm_write "${assume_yes}" "Install Orka into ${context}/${namespace}?"

package_dir=$(mktemp -d)
cleanup() {
  find "${package_dir}" -type f -delete 2>/dev/null || true
  find "${package_dir}" -depth -type d -exec rmdir {} + 2>/dev/null || true
}
trap cleanup EXIT

helm pull "${ORKA_CHART_REFERENCE}" \
  --version "${ORKA_CHART_VERSION}" \
  --destination "${package_dir}"
chart_package="${package_dir}/orka-${ORKA_CHART_VERSION}.tgz"
if [[ ! -f "${chart_package}" ]]; then
  echo "downloaded chart package was not found: ${chart_package}" >&2
  exit 1
fi
actual_chart_digest=$(sha256_file "${chart_package}")
if [[ "${actual_chart_digest}" != "${ORKA_CHART_DIGEST}" ]]; then
  echo "chart digest mismatch: expected ${ORKA_CHART_DIGEST}, got ${actual_chart_digest}" >&2
  exit 1
fi
actual_chart_version=$(helm show chart "${chart_package}" | \
  awk '$1 == "version:" {print $2; exit}')
if [[ "${actual_chart_version}" != "${ORKA_CHART_VERSION}" ]]; then
  echo "chart version mismatch: expected ${ORKA_CHART_VERSION}, got ${actual_chart_version}" >&2
  exit 1
fi

helm upgrade --install "${release}" "${chart_package}" \
  --kube-context "${context}" \
  --namespace "${namespace}" \
  --create-namespace \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait

"${SCRIPT_DIR}/validate.sh" \
  --context "${context}" \
  --release "${release}" \
  --namespace "${namespace}"

evidence_dir="${REPO_ROOT}/deploy/evidence/orka-install-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${evidence_dir}"
cat > "${evidence_dir}/versions.txt" <<EOF
context=${context}
release=${release}
namespace=${namespace}
chart_reference=${ORKA_CHART_REFERENCE}
chart_version=${ORKA_CHART_VERSION}
chart_digest=${ORKA_CHART_DIGEST}
controller_digest=${ORKA_CONTROLLER_DIGEST}
ai_worker_digest=${ORKA_AI_WORKER_DIGEST}
general_worker_digest=${ORKA_GENERAL_WORKER_DIGEST}
harness_wrapper_digest=${ORKA_HARNESS_WRAPPER_DIGEST}
EOF

echo "Orka installation validated. Non-secret version evidence: ${evidence_dir}/versions.txt"
echo "Next steps:"
echo "  configure OPENAI_BASE_URL and optional OPENAI_API_KEY"
echo "  ${SCRIPT_DIR}/create-agent-secret.sh --context ${context}"
echo "  kubectl --context ${context} apply -f ${SCRIPT_DIR}/opencode-agent.yaml"
echo "  ${SCRIPT_DIR}/verify-agent.sh --context ${context}"
