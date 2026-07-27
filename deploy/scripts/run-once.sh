#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: run-once.sh --context CONTEXT

Creates one manual Job from the suspended fetcher CronJob. The CronJob is marked
before Job creation so rerunning this script cannot create a second acceptance
Job. Set CONFIRM_RUN_ONCE=RUN to confirm noninteractively.
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
require_command jq
context=$(require_context "$context")
namespace=${DASHBOARD_NAMESPACE:-capz-orka-demo}
release=${RELEASE_NAME:-capz-orka-demo}
refuse_h100 "$namespace"
refuse_h100 "$release"
evidence_dir=${EVIDENCE_DIR:-}
[[ -z $evidence_dir || $evidence_dir != "$ROOT_DIR"* ]] || fail "EVIDENCE_DIR must be outside the repository"
if [[ -n $evidence_dir ]]; then
  mkdir -p "$evidence_dir"
  chmod 0700 "$evidence_dir"
fi

cronjob=$(discover_one "fetcher CronJob" kubectl --context "$context" -n "$namespace" get cronjobs.batch \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=fetcher" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

ensure_suspended() {
  local suspended
  suspended=$(kubectl --context "$context" -n "$namespace" get "cronjob/$cronjob" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)
  [[ $suspended == true ]] || printf 'warning: CronJob %s/%s is not suspended\n' "$namespace" "$cronjob" >&2
}
trap ensure_suspended EXIT

[[ $(kubectl --context "$context" -n "$namespace" get "cronjob/$cronjob" -o jsonpath='{.spec.suspend}') == true ]] || fail "CronJob must be suspended before a manual run"

reservation=$(kubectl --context "$context" -n "$namespace" get "cronjob/$cronjob" -o json \
  | jq -r '.metadata.annotations["capz-orka-demo.willieyao.dev/manual-job"] // empty')
[[ -z $reservation ]] || fail "manual acceptance Job was already reserved: $reservation"

active_jobs=$(kubectl --context "$context" -n "$namespace" get jobs.batch \
  -l "app.kubernetes.io/instance=$release" -o json | jq '[.items[] | select((.status.active // 0) > 0)] | length')
[[ $active_jobs -eq 0 ]] || fail "an active fetch Job already exists"

confirmation=${CONFIRM_RUN_ONCE:-}
if [[ $confirmation != RUN ]]; then
  [[ -t 0 ]] || fail "set CONFIRM_RUN_ONCE=RUN to confirm the one manual Job"
  printf 'This creates the only allowed manual fetch Job in %s on context %s.\n' "$namespace" "$context" >&2
  read -r -p 'Type RUN to continue: ' confirmation
fi
[[ $confirmation == RUN ]] || fail "manual run was not confirmed"

stamp=$(date -u +%Y%m%d%H%M%S)
job_base=${release:0:35}
job_name="${job_base}-manual-${stamp}"
kubectl --context "$context" -n "$namespace" annotate "cronjob/$cronjob" \
  "capz-orka-demo.willieyao.dev/manual-job=$job_name" >/dev/null
info "reserved the one manual Job name: $job_name"

kubectl --context "$context" -n "$namespace" create job "$job_name" --from="cronjob/$cronjob" >/dev/null
info "created Job $namespace/$job_name"
if [[ -n $evidence_dir ]]; then
  printf '%s\n' "$job_name" > "$evidence_dir/manual-job-name.txt"
fi

pod=
for _ in $(seq 1 120); do
  pod=$(kubectl --context "$context" -n "$namespace" get pods -l "job-name=$job_name" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)
  [[ -n $pod ]] && break
  sleep 5
done
[[ -n $pod ]] || fail "Job pod was not created within 10 minutes"

log_args=(kubectl --context "$context" -n "$namespace" logs -f "pod/$pod" --all-containers=true --prefix=true)
if [[ -n $evidence_dir ]]; then
  "${log_args[@]}" 2>&1 | tee "$evidence_dir/manual-job.log"
else
  "${log_args[@]}"
fi

terminal=false
for _ in $(seq 1 60); do
  job_json=$(kubectl --context "$context" -n "$namespace" get "job/$job_name" -o json)
  complete=$(jq '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' <<<"$job_json")
  failed=$(jq '[.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length' <<<"$job_json")
  if [[ $complete -gt 0 || $failed -gt 0 ]]; then
    terminal=true
    break
  fi
  sleep 5
done
[[ $terminal == true ]] || fail "Job did not report a terminal condition after its pod exited"

if [[ -n $evidence_dir ]]; then
  kubectl --context "$context" -n "$namespace" get "job/$job_name" -o yaml > "$evidence_dir/manual-job.yaml"
  kubectl --context "$context" -n "$namespace" describe "job/$job_name" > "$evidence_dir/manual-job-describe.txt"
fi

[[ $complete -gt 0 ]] || fail "manual Job failed; no retry Job will be created"
[[ $(kubectl --context "$context" -n "$namespace" get "cronjob/$cronjob" -o jsonpath='{.spec.suspend}') == true ]] || fail "CronJob became unsuspended"

info "manual Job completed successfully: $job_name"
printf '\nValidation commands:\n'
printf '  KUBE_CONTEXT=%q DASHBOARD_NAMESPACE=%q RELEASE_NAME=%q EVIDENCE_DIR=%q %q --context %q\n' \
  "$context" "$namespace" "$release" "$evidence_dir" "$SCRIPT_DIR/verify-live.sh" "$context"
