#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: render.sh [--output FILE] [--values FILE]... [--allow-scheduled]

Renders the exact pinned chart. Cluster-specific values may be supplied through:
  RWX_STORAGE_CLASS, CPU_AGENTPOOL, MODEL_ENDPOINT, MODEL_ID,
  ADMIN_LOGIN, OAUTH_CLIENT_ID, and OAUTH_REDIRECT_URL.
USAGE
}

output_file=
overlays=()
allow_scheduled=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a path"
      output_file=$2
      shift 2
      ;;
    --values)
      [[ $# -ge 2 ]] || fail "--values requires a path"
      overlays+=("$2")
      shift 2
      ;;
    --allow-scheduled)
      allow_scheduled=true
      shift
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

require_command helm
require_command awk
load_versions

for overlay in "${overlays[@]}"; do
  [[ -f $overlay ]] || fail "values file not found: $overlay"
  if [[ $(basename "$overlay") == values-scheduled.yaml && $allow_scheduled != true ]]; then
    fail "values-scheduled.yaml is render-only unless --allow-scheduled is explicit"
  fi
done

release=${RELEASE_NAME:-capz-orka-demo}
namespace=${DASHBOARD_NAMESPACE:-capz-orka-demo}
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/capz-orka-render.XXXXXX")
trap 'cleanup_temp_dir "$temp_dir"' EXIT
pull_chart "$temp_dir"
build_project_args
build_runtime_args

value_args=(-f "$DEPLOY_DIR/values.yaml")
for overlay in "${overlays[@]}"; do
  value_args+=(-f "$overlay")
done

helm lint "$CHART_PACKAGE" "${value_args[@]}" "${PROJECT_ARGS[@]}" "${RUNTIME_ARGS[@]}" >&2
if [[ -n $output_file ]]; then
  mkdir -p "$(dirname "$output_file")"
  helm template "$release" "$CHART_PACKAGE" --namespace "$namespace" \
    "${value_args[@]}" "${PROJECT_ARGS[@]}" "${RUNTIME_ARGS[@]}" > "$output_file"
  info "rendered $output_file"
else
  helm template "$release" "$CHART_PACKAGE" --namespace "$namespace" \
    "${value_args[@]}" "${PROJECT_ARGS[@]}" "${RUNTIME_ARGS[@]}"
fi
