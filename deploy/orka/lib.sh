#!/usr/bin/env bash

set -euo pipefail

ORKA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Used by scripts that source this file.
# shellcheck disable=SC2034
REPO_ROOT=$(cd "${ORKA_DIR}/../.." && pwd)
VERSIONS_FILE="${ORKA_DIR}/versions.env"
# Used by scripts and CI that source this file.
# shellcheck disable=SC2034
EXPECTED_CRDS=(
  agentruntimes.core.orka.ai
  agents.core.orka.ai
  providers.core.orka.ai
  repositorymonitors.core.orka.ai
  repositoryscans.core.orka.ai
  skills.core.orka.ai
  substrateactorpools.core.orka.ai
  tasks.core.orka.ai
  tools.core.orka.ai
  gatewaybindings.gateway.orka.ai
  gatewayclasses.gateway.orka.ai
  gateways.gateway.orka.ai
)

load_orka_versions() {
  if [[ ! -f "${VERSIONS_FILE}" ]]; then
    echo "missing Orka version file: ${VERSIONS_FILE}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${VERSIONS_FILE}"
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "required command not found: ${command_name}" >&2
      exit 2
    fi
  done
}

require_context() {
  local context=$1
  if [[ -z "${context}" ]]; then
    echo "an explicit Kubernetes context is required" >&2
    exit 2
  fi
  if [[ "${context}" == "h100" ]]; then
    echo "refusing Kubernetes context h100" >&2
    exit 1
  fi
  if ! kubectl config get-contexts "${context}" >/dev/null 2>&1; then
    echo "Kubernetes context does not exist: ${context}" >&2
    exit 1
  fi
}

confirm_write() {
  local assume_yes=$1
  local prompt=$2
  if [[ "${assume_yes}" == "true" ]]; then
    return
  fi
  local response
  read -r -p "${prompt} [y/N] " response
  if [[ ! "${response}" =~ ^[Yy]$ ]]; then
    echo "cancelled"
    exit 1
  fi
}

sha256_file() {
  local path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print "sha256:" $1}'
  else
    shasum -a 256 "${path}" | awk '{print "sha256:" $1}'
  fi
}

require_release_configuration() {
  local value_name
  for value_name in \
    ORKA_CHART_REFERENCE \
    ORKA_CHART_VERSION \
    ORKA_CHART_DIGEST \
    ORKA_CONTROLLER_DIGEST \
    ORKA_AI_WORKER_DIGEST \
    ORKA_GENERAL_WORKER_DIGEST \
    ORKA_HARNESS_WRAPPER_DIGEST; do
    if [[ -z "${!value_name:-}" ]]; then
      cat >&2 <<EOF
No released Orka chart is configured.

The normal installer is intentionally disabled until orka-agents/orka publishes
an exact chart and matching runtime images containing commit
${ORKA_MINIMUM_COMMIT} or later. Maintainers may package the pinned source chart
for lint, render, and temporary kind validation with package-source.sh. Source
mode is not a turnkey installation and does not publish or supply runtime images.
EOF
      exit 1
    fi
  done

  if [[ ! "${ORKA_CHART_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    echo "ORKA_CHART_VERSION must be an exact version: ${ORKA_CHART_VERSION}" >&2
    exit 1
  fi
  for value_name in \
    ORKA_CHART_DIGEST \
    ORKA_CONTROLLER_DIGEST \
    ORKA_AI_WORKER_DIGEST \
    ORKA_GENERAL_WORKER_DIGEST \
    ORKA_HARNESS_WRAPPER_DIGEST; do
    if [[ ! "${!value_name}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "${value_name} must be an exact sha256 digest" >&2
      exit 1
    fi
  done
}
