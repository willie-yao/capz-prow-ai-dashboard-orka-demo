#!/usr/bin/env bash
# Create or rotate the model credential Secret used by the OpenCode Agent.

set -euo pipefail
set +x

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/orka/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: create-agent-secret.sh --context CONTEXT [--namespace NAME] [--name NAME] [--no-api-key] [--yes]" >&2
}

context=
namespace=orka-system
secret_name=opencode-credentials
no_api_key=false
assume_yes=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context=${2:-}
      shift 2
      ;;
    --namespace)
      namespace=${2:-}
      shift 2
      ;;
    --name)
      secret_name=${2:-}
      shift 2
      ;;
    --no-api-key)
      no_api_key=true
      shift
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

require_commands kubectl jq
require_context "${context}"
if [[ -z "${namespace}" || -z "${secret_name}" ]]; then
  usage
  exit 2
fi
kubectl --context "${context}" get namespace "${namespace}" >/dev/null

temp_dir=$(mktemp -d)
chmod 700 "${temp_dir}"
cleanup() {
  rm -f "${temp_dir}/OPENAI_BASE_URL" "${temp_dir}/OPENAI_API_KEY"
  rmdir "${temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT
umask 077

base_url=${OPENAI_BASE_URL:-}
if [[ -z "${base_url}" ]]; then
  read -r -p "OpenCode model base URL: " base_url
fi
if [[ -z "${base_url}" || ! "${base_url}" =~ ^https?:// ]]; then
  echo "OPENAI_BASE_URL must be a non-empty HTTP or HTTPS URL" >&2
  exit 1
fi
printf '%s' "${base_url}" > "${temp_dir}/OPENAI_BASE_URL"
chmod 600 "${temp_dir}/OPENAI_BASE_URL"
unset base_url

api_key=${OPENAI_API_KEY:-}
if [[ "${no_api_key}" == "true" ]]; then
  api_key=
else
  if [[ -z "${api_key}" ]]; then
    read -r -s -p "OpenCode model API key, leave empty for unauthenticated endpoints: " api_key
    echo >&2
  fi
fi
secret_args=(--from-file="OPENAI_BASE_URL=${temp_dir}/OPENAI_BASE_URL")
include_api_key=false
if [[ -n "${api_key}" ]]; then
  printf '%s' "${api_key}" > "${temp_dir}/OPENAI_API_KEY"
  chmod 600 "${temp_dir}/OPENAI_API_KEY"
  secret_args+=(--from-file="OPENAI_API_KEY=${temp_dir}/OPENAI_API_KEY")
  include_api_key=true
fi
unset api_key

printf 'Kubernetes context: %s\n' "${context}"
printf 'Namespace:          %s\n' "${namespace}"
printf 'Secret:             %s\n' "${secret_name}"
confirm_write "${assume_yes}" \
  "Create or rotate ${namespace}/${secret_name} on ${context}?"

kubectl --context "${context}" --namespace "${namespace}" create secret generic \
  "${secret_name}" "${secret_args[@]}" --dry-run=client -o json | \
  kubectl --context "${context}" apply \
    --server-side \
    --force-conflicts \
    --field-manager=capz-orka-demo-agent-secret \
    -f - >/dev/null

if [[ "${include_api_key}" != "true" ]]; then
  secret=$(kubectl --context "${context}" --namespace "${namespace}" get \
    "secret/${secret_name}" -o json)
  if jq -e '.data | has("OPENAI_API_KEY")' <<<"${secret}" >/dev/null; then
    kubectl --context "${context}" --namespace "${namespace}" patch \
      "secret/${secret_name}" --type=json \
      -p='[{"op":"remove","path":"/data/OPENAI_API_KEY"}]' >/dev/null
  fi
fi

echo "Created or rotated ${namespace}/${secret_name} without printing credential values."
