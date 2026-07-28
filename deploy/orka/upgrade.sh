#!/usr/bin/env bash
# Apply exact target CRDs before upgrading the Orka Helm release.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/orka/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: upgrade.sh --context CONTEXT --chart CHART --version VERSION [options]

Options:
  --release NAME          Helm release name, default: orka
  --namespace NAME        Helm namespace, default: orka-system
  --source-commit SHA     Enable maintainer-only source mode for a local chart
  --yes                   Skip the interactive confirmation

Release mode requires CHART and VERSION to match the immutable pins in
versions.env. Source mode requires a local chart package and the exact minimum
source commit. Source mode is only for temporary kind validation.
EOF
}

context=
chart_arg=
target_version=
release=orka
namespace=orka-system
source_commit=
assume_yes=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context=${2:-}
      shift 2
      ;;
    --chart)
      chart_arg=${2:-}
      shift 2
      ;;
    --version)
      target_version=${2:-}
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
    --source-commit)
      source_commit=${2:-}
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
require_commands helm kubectl jq
require_context "${context}"

if [[ -z "${chart_arg}" || -z "${target_version}" || \
      -z "${release}" || -z "${namespace}" ]]; then
  usage
  exit 2
fi
if [[ ! "${target_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "--version must be an exact chart version: ${target_version}" >&2
  exit 2
fi

package_dir=
chart_package=
source_mode=false
lock_acquired=false
lock_name=orka-crd-lifecycle
lock_namespace=kube-system
target_crds=$(mktemp)
cleanup() {
  local exit_code=$?
  set +e
  if [[ "${lock_acquired}" == "true" ]]; then
    kubectl --context "${context}" --namespace "${lock_namespace}" \
      delete lease "${lock_name}" --ignore-not-found >/dev/null
  fi
  rm -f "${target_crds}"
  if [[ -n "${package_dir}" && -d "${package_dir}" ]]; then
    find "${package_dir}" -type f -delete 2>/dev/null
    find "${package_dir}" -depth -type d -exec rmdir {} + 2>/dev/null
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

if [[ -f "${chart_arg}" ]]; then
  source_mode=true
  chart_package=$(cd "$(dirname "${chart_arg}")" && pwd)/$(basename "${chart_arg}")
  if [[ "${source_commit}" != "${ORKA_MINIMUM_COMMIT}" ]]; then
    echo "local chart upgrades require --source-commit ${ORKA_MINIMUM_COMMIT}" >&2
    exit 1
  fi
else
  require_release_configuration
  if [[ "${chart_arg}" != "${ORKA_CHART_REFERENCE}" || \
        "${target_version}" != "${ORKA_CHART_VERSION}" ]]; then
    echo "target chart and version must match deploy/orka/versions.env" >&2
    exit 1
  fi
  package_dir=$(mktemp -d)
  helm pull "${chart_arg}" --version "${target_version}" \
    --destination "${package_dir}"
  chart_package=$(find "${package_dir}" -maxdepth 1 -name 'orka-*.tgz' -print -quit)
  if [[ -z "${chart_package}" ]]; then
    echo "downloaded Orka chart package was not found" >&2
    exit 1
  fi
  actual_digest=$(sha256_file "${chart_package}")
  if [[ "${actual_digest}" != "${ORKA_CHART_DIGEST}" ]]; then
    echo "chart digest mismatch: expected ${ORKA_CHART_DIGEST}, got ${actual_digest}" >&2
    exit 1
  fi
fi

actual_version=$(helm show chart "${chart_package}" | \
  awk '$1 == "version:" {print $2; exit}')
if [[ "${actual_version}" != "${target_version}" ]]; then
  echo "chart version mismatch: expected ${target_version}, got ${actual_version}" >&2
  exit 1
fi

helm show crds "${chart_package}" > "${target_crds}"
if [[ ! -s "${target_crds}" ]]; then
  echo "target chart contains no CRDs" >&2
  exit 1
fi
mapfile -t actual_crds < <(
  awk '$1 == "name:" && $2 ~ /\.orka\.ai$/ {print $2}' "${target_crds}" | sort -u
)
mapfile -t expected_crds < <(printf '%s\n' "${EXPECTED_CRDS[@]}" | sort)
if [[ "${#actual_crds[@]}" -ne 12 ]] || \
   ! diff -u <(printf '%s\n' "${expected_crds[@]}") \
     <(printf '%s\n' "${actual_crds[@]}") >/dev/null; then
  echo "target chart does not contain the expected 12 Orka CRDs" >&2
  diff -u <(printf '%s\n' "${expected_crds[@]}") \
    <(printf '%s\n' "${actual_crds[@]}") >&2 || true
  exit 1
fi

release_info=$(helm list --kube-context "${context}" --namespace "${namespace}" \
  --filter "^${release}$" --output json)
current_chart=$(jq -er \
  'if length == 1 then .[0].chart else error("expected one installed release") end' \
  <<<"${release_info}")
if [[ "${current_chart}" != orka-* ]]; then
  echo "release ${namespace}/${release} is not an Orka release" >&2
  exit 1
fi

printf 'Kubernetes context: %s\n' "${context}"
printf 'Helm release:       %s\n' "${release}"
printf 'Namespace:          %s\n' "${namespace}"
printf 'Current chart:      %s\n' "${current_chart}"
printf 'Target chart:       %s\n' "${chart_package}"
printf 'Target version:     %s\n' "${target_version}"
printf 'Source mode:        %s\n' "${source_mode}"
confirm_write "${assume_yes}" \
  "Apply target CRDs and upgrade ${namespace}/${release} on ${context}?"

evidence_dir="${REPO_ROOT}/deploy/evidence/orka-upgrade-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${evidence_dir}"
{
  printf 'context=%s\n' "${context}"
  printf 'release=%s\n' "${release}"
  printf 'namespace=%s\n' "${namespace}"
  printf 'current_chart=%s\n' "${current_chart}"
  printf 'target_version=%s\n' "${target_version}"
  printf 'target_digest=%s\n' "$(sha256_file "${chart_package}")"
  printf 'source_mode=%s\n' "${source_mode}"
  if [[ "${source_mode}" == "true" ]]; then
    printf 'source_commit=%s\n' "${source_commit}"
  fi
} > "${evidence_dir}/target.txt"

kubectl --context "${context}" get crd "${EXPECTED_CRDS[@]}" \
  -o custom-columns=NAME:.metadata.name,RESOURCE_VERSION:.metadata.resourceVersion,STORED_VERSIONS:.status.storedVersions \
  > "${evidence_dir}/crds-before.txt"
for crd in "${EXPECTED_CRDS[@]}"; do
  {
    echo "## ${crd}"
    kubectl --context "${context}" get "${crd}" --all-namespaces \
      -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name \
      --no-headers 2>/dev/null || true
  } >> "${evidence_dir}/resources-before.txt"
done
helm list --kube-context "${context}" --namespace "${namespace}" \
  --filter "^${release}$" > "${evidence_dir}/release-before.txt"

holder="${context}/${namespace}/${release}/$$"
if ! cat <<EOF | kubectl --context "${context}" create -f - >/dev/null
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: ${lock_name}
  namespace: ${lock_namespace}
spec:
  holderIdentity: ${holder}
  leaseDurationSeconds: 1800
EOF
then
  echo "another Orka CRD lifecycle operation holds ${lock_namespace}/${lock_name}" >&2
  exit 1
fi
lock_acquired=true

kubectl --context "${context}" apply \
  --server-side \
  --force-conflicts \
  --field-manager=orka-crd-lifecycle \
  -f "${target_crds}"

kubectl --context "${context}" create --dry-run=client \
  -f "${target_crds}" -o json | \
  jq -c '{name: .metadata.name, spec: .spec}' | \
  while IFS= read -r target; do
    name=$(jq -er '.name' <<<"${target}")
    spec=$(jq -ec '.spec' <<<"${target}")
    resource_version=$(kubectl --context "${context}" get crd "${name}" \
      -o jsonpath='{.metadata.resourceVersion}')
    patch=$(jq -cn \
      --arg resourceVersion "${resource_version}" \
      --argjson spec "${spec}" \
      '[
        {"op":"test","path":"/metadata/resourceVersion","value":$resourceVersion},
        {"op":"replace","path":"/spec","value":$spec}
      ]')
    kubectl --context "${context}" patch crd "${name}" \
      --type=json -p "${patch}" >/dev/null
    kubectl --context "${context}" wait --for=condition=Established \
      --timeout=60s "crd/${name}" >/dev/null
  done

helm_upgrade_args=(
  upgrade "${release}" "${chart_package}"
  --kube-context "${context}"
  --namespace "${namespace}"
  --reset-then-reuse-values
)
if [[ "${source_mode}" != "true" ]]; then
  helm_upgrade_args+=(
    --set-string "controller.image.tag=${target_version}@${ORKA_CONTROLLER_DIGEST}"
    --set-string "workers.ai.image.tag=${target_version}@${ORKA_AI_WORKER_DIGEST}"
    --set-string "workers.general.image.tag=${target_version}@${ORKA_GENERAL_WORKER_DIGEST}"
    --set-string "workers.harnessWrapper.image.tag=${target_version}@${ORKA_HARNESS_WRAPPER_DIGEST}"
    --wait
  )
fi
helm "${helm_upgrade_args[@]}"

if [[ "${source_mode}" == "true" ]]; then
  for crd in "${EXPECTED_CRDS[@]}"; do
    kubectl --context "${context}" wait --for=condition=Established \
      --timeout=60s "crd/${crd}" >/dev/null
  done
  helm status "${release}" --kube-context "${context}" \
    --namespace "${namespace}" >/dev/null
else
  "${SCRIPT_DIR}/validate.sh" \
    --context "${context}" \
    --release "${release}" \
    --namespace "${namespace}"
fi

helm list --kube-context "${context}" --namespace "${namespace}" \
  --filter "^${release}$" > "${evidence_dir}/release-after.txt"
kubectl --context "${context}" --namespace "${namespace}" get deployment \
  -l "app.kubernetes.io/instance=${release},app.kubernetes.io/name=orka" \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGES:.spec.template.spec.containers[*].image \
  > "${evidence_dir}/deployments-after.txt"

echo "Orka CRDs and release upgraded successfully."
echo "Non-secret upgrade evidence: ${evidence_dir}"
