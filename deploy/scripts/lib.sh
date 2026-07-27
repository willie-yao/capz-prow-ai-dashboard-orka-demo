#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT_DIR=$(cd "$DEPLOY_DIR/.." && pwd)
CHART_OCI=oci://ghcr.io/willie-yao/charts/prow-ai-dashboard

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

cleanup_temp_dir() {
  local dir=${1:-}
  [[ -n $dir && -d $dir ]] || return 0
  find "$dir" -depth -mindepth 1 -delete
  rmdir "$dir" 2>/dev/null || true
}

load_versions() {
  # shellcheck disable=SC1091
  source "$DEPLOY_DIR/versions.env"
  : "${DASHBOARD_CHART_VERSION:?}"
  : "${DASHBOARD_ENGINE_COMMIT:?}"
  : "${DASHBOARD_CHART_DIGEST:?}"
  : "${DASHBOARD_CHART_ASSET_DIGEST:?}"
  : "${DASHBOARD_IMAGE_DIGEST:?}"
  : "${DASHBOARD_ANALYZER_DIGEST:?}"
  : "${DASHBOARD_FIXER_DIGEST:?}"
  : "${ORKA_REQUIRED_COMMIT:?}"
}

refuse_h100() {
  local context=$1 lower
  lower=$(printf '%s' "$context" | tr '[:upper:]' '[:lower:]')
  [[ $lower != *h100* ]] || fail "refusing prohibited Kubernetes context: $context"
}

require_context() {
  local context=${1:-${KUBE_CONTEXT:-}}
  [[ -n $context ]] || fail "set KUBE_CONTEXT or pass --context"
  refuse_h100 "$context"
  kubectl config get-contexts -o name | grep -Fxq "$context" || fail "Kubernetes context not found: $context"
  printf '%s\n' "$context"
}

assert_real_value() {
  local name=$1 value=${2:-}
  [[ -n $value ]] || fail "$name is required"
  [[ $value != replace-with-* ]] || fail "$name still uses a placeholder"
  [[ $value != *example.com* ]] || fail "$name still uses the reserved example.com placeholder"
}

build_project_args() {
  PROJECT_ARGS=(
    --set-file "project.config=$ROOT_DIR/project.yaml"
    --set-file "project.systemPrompt=$ROOT_DIR/prompts/system.md"
  )
  local skill name escaped
  for skill in "$ROOT_DIR"/skills/*.yaml; do
    [[ -f $skill ]] || fail "no skill files found"
    name=$(basename "$skill")
    escaped=${name//./\\.}
    PROJECT_ARGS+=(--set-file "project.skills.${escaped}=$skill")
  done
}

build_runtime_args() {
  RUNTIME_ARGS=()
  [[ -n ${RWX_STORAGE_CLASS:-} ]] && RUNTIME_ARGS+=(--set-string "persistence.storageClass=$RWX_STORAGE_CLASS")
  [[ -n ${CPU_AGENTPOOL:-} ]] && RUNTIME_ARGS+=(--set-string "analysisRuntime.orkaContainer.nodeSelector.agentpool=$CPU_AGENTPOOL")
  [[ -n ${MODEL_ENDPOINT:-} ]] && RUNTIME_ARGS+=(--set-string "ai.endpoint=$MODEL_ENDPOINT")
  [[ -n ${MODEL_ID:-} ]] && RUNTIME_ARGS+=(--set-string "ai.model=$MODEL_ID")
  [[ -n ${ADMIN_LOGIN:-} ]] && RUNTIME_ARGS+=(--set-string "server.actions.admins[0]=$ADMIN_LOGIN")
  [[ -n ${OAUTH_CLIENT_ID:-} ]] && RUNTIME_ARGS+=(--set-string "server.actions.oauth.clientId=$OAUTH_CLIENT_ID")
  [[ -n ${OAUTH_REDIRECT_URL:-} ]] && RUNTIME_ARGS+=(--set-string "server.actions.oauth.redirectUrl=$OAUTH_REDIRECT_URL")
  return 0
}

require_install_inputs() {
  assert_real_value RWX_STORAGE_CLASS "${RWX_STORAGE_CLASS:-}"
  assert_real_value CPU_AGENTPOOL "${CPU_AGENTPOOL:-}"
  assert_real_value MODEL_ENDPOINT "${MODEL_ENDPOINT:-}"
  assert_real_value MODEL_ID "${MODEL_ID:-}"
  assert_real_value ADMIN_LOGIN "${ADMIN_LOGIN:-}"
  assert_real_value OAUTH_CLIENT_ID "${OAUTH_CLIENT_ID:-}"
  assert_real_value OAUTH_REDIRECT_URL "${OAUTH_REDIRECT_URL:-}"
}

pull_chart() {
  local temp_dir=$1 output digest registry_config
  load_versions
  registry_config="$temp_dir/helm-registry.json"
  printf '{}\n' > "$registry_config"
  chmod 0600 "$registry_config"
  output=$(HELM_REGISTRY_CONFIG="$registry_config" helm pull "$CHART_OCI" \
    --version "$DASHBOARD_CHART_VERSION" --destination "$temp_dir" 2>&1)
  printf '%s\n' "$output" >&2
  digest=$(printf '%s\n' "$output" | awk '/^Digest:/ {print $2; exit}')
  [[ $digest == "$DASHBOARD_CHART_DIGEST" ]] || fail "chart digest mismatch: got ${digest:-none}, want $DASHBOARD_CHART_DIGEST"
  CHART_PACKAGE="$temp_dir/prow-ai-dashboard-${DASHBOARD_CHART_VERSION}.tgz"
  [[ -f $CHART_PACKAGE ]] || fail "chart package was not downloaded"
}

discover_one() {
  local description=$1
  shift
  local output count
  output=$("$@")
  count=$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  [[ $count == 1 ]] || fail "expected one $description, found $count"
  printf '%s\n' "$output"
}

discover_analysis_namespace() {
  local context=$1 release=$2
  discover_one "analysis namespace" kubectl --context "$context" get namespace \
    -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=orka-container-analysis" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}
