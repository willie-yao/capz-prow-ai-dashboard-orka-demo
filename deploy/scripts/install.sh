#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: install.sh --context CONTEXT

Runs preflight, creates a new dashboard namespace, creates dashboard model and
OAuth Secrets, installs the exact pinned chart with scheduling suspended, then
creates the analyzer model Secret in the chart-created analysis namespace.
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
load_versions
context=$(require_context "$context")
require_install_inputs
namespace=${DASHBOARD_NAMESPACE:-capz-orka-demo}
release=${RELEASE_NAME:-capz-orka-demo}
refuse_h100 "$namespace"
refuse_h100 "$release"

"$SCRIPT_DIR/preflight.sh" --context "$context"

kubectl --context "$context" create namespace "$namespace" >/dev/null
kubectl --context "$context" label namespace "$namespace" \
  app.kubernetes.io/part-of=capz-orka-demo app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
info "created namespace $namespace"

"$SCRIPT_DIR/create-secrets.sh" --context "$context" dashboard-model
"$SCRIPT_DIR/create-secrets.sh" --context "$context" dashboard-oauth

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/capz-orka-install.XXXXXX")
trap 'cleanup_temp_dir "$temp_dir"' EXIT
pull_chart "$temp_dir"
build_project_args
build_runtime_args

helm --kube-context "$context" install "$release" "$CHART_PACKAGE" \
  --namespace "$namespace" \
  -f "$DEPLOY_DIR/values.yaml" \
  "${PROJECT_ARGS[@]}" "${RUNTIME_ARGS[@]}" \
  --wait --timeout "${HELM_TIMEOUT:-15m}"

analysis_namespace=$(discover_analysis_namespace "$context" "$release")
info "analysis namespace: $analysis_namespace"
"$SCRIPT_DIR/create-secrets.sh" --context "$context" analyzer-model

server=$(discover_one "server Deployment" kubectl --context "$context" -n "$namespace" get deployments.apps \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=server" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
kubectl --context "$context" -n "$namespace" rollout status "deployment/$server" --timeout "${SERVER_TIMEOUT:-10m}"

cronjob=$(discover_one "fetcher CronJob" kubectl --context "$context" -n "$namespace" get cronjobs.batch \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=fetcher" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ $(kubectl --context "$context" -n "$namespace" get "cronjob/$cronjob" -o jsonpath='{.spec.suspend}') == true ]] || fail "CronJob is not suspended"

active_jobs=$(kubectl --context "$context" -n "$namespace" get jobs.batch \
  -l "app.kubernetes.io/instance=$release" -o json | jq '[.items[] | select((.status.active // 0) > 0)] | length')
[[ $active_jobs -eq 0 ]] || fail "an active fetch Job exists after installation"

service_account=$(discover_one "Orka runtime ServiceAccount" kubectl --context "$context" -n "$namespace" get serviceaccounts \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=orka-runtime" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for permission in create get list watch patch delete; do
  [[ $(kubectl --context "$context" auth can-i "$permission" tasks.core.orka.ai \
      -n "$analysis_namespace" --as="system:serviceaccount:$namespace:$service_account") == yes ]] \
    || fail "ServiceAccount cannot $permission Orka Tasks"
done

info "installation passed: $namespace/$release"
info "CronJob remains suspended: $cronjob"
printf '\nManual next step, after reviewing the installed state:\n'
printf '  KUBE_CONTEXT=%q DASHBOARD_NAMESPACE=%q RELEASE_NAME=%q %q --context %q\n' \
  "$context" "$namespace" "$release" "$SCRIPT_DIR/run-once.sh" "$context"
