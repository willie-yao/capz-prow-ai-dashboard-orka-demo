#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: create-secrets.sh --context CONTEXT TARGET

Targets:
  dashboard-model  Creates dashboard-model/AI_TOKEN in DASHBOARD_NAMESPACE
  analyzer-model   Creates orka-model/token in the chart-created analysis namespace
  dashboard-oauth      Creates dashboard-oauth/OAUTH_CLIENT_SECRET,SESSION_KEY
  opencode-credentials Creates opencode-credentials in ORKA_NAMESPACE

Protected environment variables:
  DASHBOARD_AI_TOKEN, ANALYZER_AI_TOKEN, OAUTH_CLIENT_SECRET, SESSION_KEY,
  OPENAI_BASE_URL, and optional OPENAI_API_KEY

Unset variables are prompted without echo. Analyzer credentials are never copied
from the dashboard namespace automatically.
USAGE
}

context=
target=
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
      [[ -z $target ]] || fail "unexpected argument: $1"
      target=$1
      shift
      ;;
  esac
done

[[ -n $target ]] || fail "secret target is required"
require_command kubectl
context=$(require_context "$context")
namespace=${DASHBOARD_NAMESPACE:-capz-orka-demo}
release=${RELEASE_NAME:-capz-orka-demo}
refuse_h100 "$namespace"
refuse_h100 "$release"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/capz-orka-secrets.XXXXXX")
chmod 0700 "$temp_dir"
trap 'cleanup_temp_dir "$temp_dir"' EXIT

write_secret_file() {
  local env_name=$1 prompt=$2 output=$3
  local value=${!env_name-}
  if [[ -z $value ]]; then
    [[ -t 0 ]] || fail "$env_name is unset and no terminal is available for a secure prompt"
    read -r -s -p "$prompt: " value
    printf '\n' >&2
  fi
  [[ -n $value ]] || fail "$env_name must not be empty"
  umask 077
  printf '%s' "$value" > "$output"
  unset value
}

apply_secret() {
  local target_namespace=$1 secret_name=$2
  shift 2
  kubectl --context "$context" -n "$target_namespace" create secret generic "$secret_name" \
    "$@" --dry-run=client -o yaml \
    | kubectl --context "$context" -n "$target_namespace" apply --server-side \
        --field-manager=capz-orka-demo-secrets -f - >/dev/null
  info "applied Secret $target_namespace/$secret_name"
}

case "$target" in
  dashboard-model)
    kubectl --context "$context" get namespace "$namespace" >/dev/null
    write_secret_file DASHBOARD_AI_TOKEN 'Dashboard model token' "$temp_dir/AI_TOKEN"
    apply_secret "$namespace" dashboard-model --from-file="AI_TOKEN=$temp_dir/AI_TOKEN"
    ;;
  analyzer-model)
    analysis_namespace=$(discover_analysis_namespace "$context" "$release")
    write_secret_file ANALYZER_AI_TOKEN 'Analyzer model token' "$temp_dir/token"
    apply_secret "$analysis_namespace" orka-model --from-file="token=$temp_dir/token"
    ;;
  dashboard-oauth)
    kubectl --context "$context" get namespace "$namespace" >/dev/null
    write_secret_file OAUTH_CLIENT_SECRET 'OAuth client secret' "$temp_dir/OAUTH_CLIENT_SECRET"
    write_secret_file SESSION_KEY 'OAuth session key' "$temp_dir/SESSION_KEY"
    if [[ $(wc -c < "$temp_dir/SESSION_KEY" | tr -d ' ') -lt 32 ]]; then
      fail "SESSION_KEY must contain at least 32 bytes"
    fi
    apply_secret "$namespace" dashboard-oauth \
      --from-file="OAUTH_CLIENT_SECRET=$temp_dir/OAUTH_CLIENT_SECRET" \
      --from-file="SESSION_KEY=$temp_dir/SESSION_KEY"
    ;;
  opencode-credentials)
    orka_namespace=${ORKA_NAMESPACE:-orka-system}
    refuse_h100 "$orka_namespace"
    kubectl --context "$context" get namespace "$orka_namespace" >/dev/null
    write_secret_file OPENAI_BASE_URL 'OpenCode model base URL' "$temp_dir/OPENAI_BASE_URL"
    secret_args=(--from-file="OPENAI_BASE_URL=$temp_dir/OPENAI_BASE_URL")
    if [[ -n ${OPENAI_API_KEY:-} ]]; then
      umask 077
      printf '%s' "$OPENAI_API_KEY" > "$temp_dir/OPENAI_API_KEY"
      secret_args+=(--from-file="OPENAI_API_KEY=$temp_dir/OPENAI_API_KEY")
    fi
    apply_secret "$orka_namespace" opencode-credentials "${secret_args[@]}"
    ;;
  *)
    fail "unknown secret target: $target"
    ;;
esac
