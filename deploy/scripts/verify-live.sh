#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: verify-live.sh --context CONTEXT

Verifies the suspended release, published dashboard data, Orka Task lifecycle,
projected ServiceAccount result access, private-file blocking, unsafe-method
blocking, recurring-pattern identity, and search index generation.

Optional private-state inspection requires PRIVATE_STATE_INSPECTOR_IMAGE pinned
by digest. The image must provide sh, test, and sha256sum. The temporary Pod
mounts the retained PVC read-only and never prints file contents.
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
require_command curl
require_command python3
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

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/capz-orka-live.XXXXXX")
port_forward_pids=()
cleanup() {
  local pid
  for pid in "${port_forward_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$temp_dir"
}
trap cleanup EXIT

cronjob=$(discover_one "fetcher CronJob" kubectl --context "$context" -n "$namespace" get cronjobs.batch \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=fetcher" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ $(kubectl --context "$context" -n "$namespace" get "cronjob/$cronjob" -o jsonpath='{.spec.suspend}') == true ]] || fail "CronJob is not suspended"

active_jobs=$(kubectl --context "$context" -n "$namespace" get jobs.batch \
  -l "app.kubernetes.io/instance=$release" -o json | jq '[.items[] | select((.status.active // 0) > 0)] | length')
[[ $active_jobs -eq 0 ]] || fail "an active fetch Job still exists"

server=$(discover_one "server Deployment" kubectl --context "$context" -n "$namespace" get deployments.apps \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=server" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
kubectl --context "$context" -n "$namespace" rollout status "deployment/$server" --timeout "${SERVER_TIMEOUT:-10m}" >/dev/null
service=$(discover_one "server Service" kubectl --context "$context" -n "$namespace" get services \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=server" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
pvc=$(discover_one "dashboard PVC" kubectl --context "$context" -n "$namespace" get pvc \
  -l "app.kubernetes.io/instance=$release" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ $(kubectl --context "$context" -n "$namespace" get "pvc/$pvc" -o jsonpath='{.spec.accessModes[0]}') == ReadWriteMany ]] || fail "PVC is not ReadWriteMany"
[[ $(kubectl --context "$context" -n "$namespace" get "pvc/$pvc" -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}') == keep ]] || fail "PVC is not retained"

analysis_namespace=$(discover_analysis_namespace "$context" "$release")
service_account=$(discover_one "Orka runtime ServiceAccount" kubectl --context "$context" -n "$namespace" get serviceaccounts \
  -l "app.kubernetes.io/instance=$release,app.kubernetes.io/component=orka-runtime" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for permission in create get list watch patch delete; do
  [[ $(kubectl --context "$context" auth can-i "$permission" tasks.core.orka.ai \
      -n "$analysis_namespace" --as="system:serviceaccount:$namespace:$service_account") == yes ]] \
    || fail "ServiceAccount cannot $permission Orka Tasks"
done

cron_json=$(kubectl --context "$context" -n "$namespace" get "cronjob/$cronjob" -o json)
jq -e '.spec.jobTemplate.spec.template.spec.automountServiceAccountToken == true' <<<"$cron_json" >/dev/null || fail "fetcher does not automount the projected ServiceAccount token"
jq -e '[.spec.jobTemplate.spec.template.spec.containers[].env[]? | select(.name == "ORKA_API_TOKEN_FILE" and .value == "/var/run/secrets/kubernetes.io/serviceaccount/token")] | length == 1' <<<"$cron_json" >/dev/null || fail "fetcher is missing ORKA_API_TOKEN_FILE"
jq -e '[.spec.jobTemplate.spec.template.spec.containers[].env[]? | select(.name == "ORKA_API_TOKEN")] | length == 0' <<<"$cron_json" >/dev/null || fail "fetcher references a static Orka API token"

tasks=$(kubectl --context "$context" -n "$analysis_namespace" get tasks.core.orka.ai -o json)
task_count=$(jq '.items | length' <<<"$tasks")
[[ $task_count -gt 0 ]] || fail "no analyzer Tasks were created"
nonterminal=$(jq '[.items[] | select((.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed")] | length' <<<"$tasks")
[[ $nonterminal -eq 0 ]] || fail "$nonterminal analyzer Task(s) are not terminal"
first_task=$(jq -r '([.items[] | select((.status.phase // "") == "Succeeded")] + .items)[0].metadata.name' <<<"$tasks")

orka_namespace=${ORKA_NAMESPACE:-orka-system}
orka_service=${ORKA_SERVICE:-orka}
orka_port=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()
PY
)
kubectl --context "$context" -n "$orka_namespace" port-forward "service/$orka_service" "$orka_port:8080" >"$temp_dir/orka-port-forward.log" 2>&1 &
orka_port_forward_pid=$!
port_forward_pids+=("$orka_port_forward_pid")
for _ in $(seq 1 30); do
  curl -sS -o /dev/null "http://127.0.0.1:$orka_port/" >/dev/null 2>&1 && break
  kill -0 "$orka_port_forward_pid" 2>/dev/null || fail "Orka port-forward exited"
  sleep 1
done
kill -0 "$orka_port_forward_pid" 2>/dev/null || fail "Orka port-forward is not running"

token=$(kubectl --context "$context" -n "$namespace" create token "$service_account" --duration=10m)
[[ -n $token ]] || fail "TokenRequest returned an empty ServiceAccount token"
umask 077
printf 'header = "Authorization: Bearer %s"\n' "$token" > "$temp_dir/curl-auth.conf"
unset token
curl --config "$temp_dir/curl-auth.conf" -fsS \
  "http://127.0.0.1:$orka_port/api/v1/tasks/$first_task/result?namespace=$analysis_namespace" \
  -o "$temp_dir/orka-result.json"
jq -e '.result | type == "string" and length > 0' "$temp_dir/orka-result.json" >/dev/null || fail "Orka result API returned no Task result"

server_port=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()
PY
)
kubectl --context "$context" -n "$namespace" port-forward "service/$service" "$server_port:80" >"$temp_dir/server-port-forward.log" 2>&1 &
server_port_forward_pid=$!
port_forward_pids+=("$server_port_forward_pid")
base="http://127.0.0.1:$server_port"
for _ in $(seq 1 60); do
  curl -fsS "$base/healthz" >/dev/null 2>&1 && break
  kill -0 "$server_port_forward_pid" 2>/dev/null || fail "server port-forward exited"
  sleep 1
done
curl -fsS "$base/healthz" >/dev/null

for file in manifest.json dashboard.json flakiness.json search-index.json; do
  curl -fsS "$base/data/$file" -o "$temp_dir/$file"
  jq -e . "$temp_dir/$file" >/dev/null
  [[ -s $temp_dir/$file ]] || fail "$file is empty"
done

python3 - "$temp_dir/dashboard.json" "$temp_dir/search-index.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    dashboard=json.load(f)
patterns=dashboard.get("recurring_patterns", [])
if not patterns:
    raise SystemExit("no recurring patterns were published")
for pattern in patterns:
    if not pattern.get("id") or not pattern.get("content_hash"):
        raise SystemExit("recurring pattern is missing id or content_hash")
with open(sys.argv[2]) as f:
    search=json.load(f)
count=len(search) if isinstance(search,list) else len(search.get("entries", []))
if count == 0:
    raise SystemExit("search index has no entries")
print(f"verified {len(patterns)} recurring pattern(s) and {count} search entries")
PY

for private_path in \
  ai_cache.json ai_traces.json orka_analysis.json issue_state.json fix_pr_state.json \
  action_request_state.json remediation_state.json analysis_correction_state.json .analysis-chat/sessions.json; do
  status=$(curl -sS -o /dev/null -w '%{http_code}' "$base/data/$private_path")
  [[ $status == 404 ]] || fail "private path /data/$private_path returned HTTP $status"
done

for method in POST PUT PATCH DELETE CONNECT; do
  status=$(curl -sS -X "$method" -o /dev/null -w '%{http_code}' "$base/data/manifest.json")
  [[ $status == 405 ]] || fail "$method /data/manifest.json returned HTTP $status"
done

curl -fsS "$base/api/capabilities" -o "$temp_dir/capabilities.json"
jq -e '.features.analysis_chat == true and .features.analysis_traces == true and .features.actions == false' "$temp_dir/capabilities.json" >/dev/null || fail "capabilities do not expose chat and traces with actions disabled"
trace_status=$(curl -sS -o /dev/null -w '%{http_code}' "$base/api/analysis-traces")
case "$trace_status" in
  301|302|303|307|308|401|403) ;;
  *) fail "unauthenticated trace API returned HTTP $trace_status" ;;
esac

if [[ -n ${PRIVATE_STATE_INSPECTOR_IMAGE:-} ]]; then
  [[ $PRIVATE_STATE_INSPECTOR_IMAGE == *@sha256:* ]] || fail "PRIVATE_STATE_INSPECTOR_IMAGE must be pinned by digest"
  inspector="capz-private-state-${RANDOM}-${RANDOM}"
  cat > "$temp_dir/inspector.yaml" <<EOF_INSPECTOR
apiVersion: v1
kind: Pod
metadata:
  name: $inspector
  namespace: $namespace
  labels:
    app.kubernetes.io/part-of: capz-orka-demo
    app.kubernetes.io/component: private-state-inspector
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: inspect
      image: $PRIVATE_STATE_INSPECTOR_IMAGE
      command: ["sh", "-ceu"]
      args:
        - |
          test -s /data/ai_cache.json
          test -s /data/ai_traces.json
          sha256sum /data/ai_cache.json /data/ai_traces.json
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $pvc
        readOnly: true
EOF_INSPECTOR
  kubectl --context "$context" apply -f "$temp_dir/inspector.yaml" >/dev/null
  if ! kubectl --context "$context" -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$inspector" --timeout=5m; then
    kubectl --context "$context" -n "$namespace" logs "pod/$inspector" >&2 || true
    fail "private-state inspector did not succeed"
  fi
  kubectl --context "$context" -n "$namespace" logs "pod/$inspector" > "$temp_dir/private-state-hashes.txt"
  kubectl --context "$context" -n "$namespace" delete "pod/$inspector" --wait=true >/dev/null
fi

if [[ -n $evidence_dir ]]; then
  cp "$temp_dir/capabilities.json" "$evidence_dir/capabilities.json"
  cp "$temp_dir/manifest.json" "$evidence_dir/manifest.json"
  cp "$temp_dir/private-state-hashes.txt" "$evidence_dir/private-state-hashes.txt" 2>/dev/null || true
  kubectl --context "$context" -n "$analysis_namespace" get tasks.core.orka.ai -o yaml > "$evidence_dir/orka-tasks.yaml"
  kubectl --context "$context" -n "$namespace" get cronjob,job,pod,pvc,service,deployment -o wide > "$evidence_dir/dashboard-resources.txt"
fi

info "live verification passed"
info "release: $namespace/$release"
info "analysis namespace: $analysis_namespace"
info "analyzer Tasks: $task_count"
info "CronJob remains suspended"
