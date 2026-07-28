#!/usr/bin/env bash
# Verify the configured OpenCode Agent without creating a Task.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/orka/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: verify-agent.sh --context CONTEXT [--namespace NAME] [--name NAME] [--timeout DURATION]" >&2
}

context=
namespace=orka-system
agent_name=opencode-fixer
timeout=120s
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
      agent_name=${2:-}
      shift 2
      ;;
    --timeout)
      timeout=${2:-}
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

require_commands kubectl jq
require_context "${context}"
if [[ -z "${namespace}" || -z "${agent_name}" || -z "${timeout}" ]]; then
  usage
  exit 2
fi

if ! kubectl --context "${context}" --namespace "${namespace}" wait \
  --for=condition=Ready --timeout="${timeout}" "agent/${agent_name}" >/dev/null; then
  kubectl --context "${context}" --namespace "${namespace}" get \
    "agent/${agent_name}" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.reason}{": "}{.message}{"\n"}{end}' \
    >&2 || true
  echo "Agent did not become Ready: ${namespace}/${agent_name}" >&2
  exit 1
fi

agent=$(kubectl --context "${context}" --namespace "${namespace}" get \
  "agent/${agent_name}" -o json)
runtime_type=$(jq -er '.spec.runtime.type' <<<"${agent}")
if [[ "${runtime_type}" != "opencode" ]]; then
  echo "Agent runtime is ${runtime_type}, expected opencode" >&2
  exit 1
fi
model_name=$(jq -er '.spec.model.name' <<<"${agent}")
if [[ -z "${model_name}" || "${model_name}" == replace-with-* ]]; then
  echo "Agent model name is still a placeholder" >&2
  exit 1
fi
secret_name=$(jq -er '.spec.secretRef.name' <<<"${agent}")
secret=$(kubectl --context "${context}" --namespace "${namespace}" get \
  "secret/${secret_name}" -o json)
if ! jq -e '.data.OPENAI_BASE_URL | length > 0' <<<"${secret}" >/dev/null; then
  echo "Agent Secret is missing OPENAI_BASE_URL" >&2
  exit 1
fi
if ! jq -e '
  (.metadata.generation) as $generation |
  (.status.ready == true) and
  any(.status.conditions[]?;
    .type == "Ready" and
    .status == "True" and
    .observedGeneration == $generation
  )
' <<<"${agent}" >/dev/null; then
  echo "Agent Ready status does not match its current generation" >&2
  exit 1
fi
if [[ $(jq -r '.status.activeTasks // 0' <<<"${agent}") -ne 0 ]]; then
  echo "Agent reports active Tasks" >&2
  exit 1
fi

active_tasks=$(kubectl --context "${context}" --namespace "${namespace}" get tasks \
  -o json | jq --arg agent "${agent_name}" \
  '[.items[] | select(
    .spec.agentRef.name == $agent and
    ((.status.phase // "") as $phase | ["Succeeded", "Failed", "Cancelled"] | index($phase) | not)
  )] | length')
if [[ "${active_tasks}" -ne 0 ]]; then
  echo "Agent has ${active_tasks} non-terminal Task resources" >&2
  exit 1
fi

echo "Validated Ready OpenCode Agent ${namespace}/${agent_name} with no active Tasks."
