#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_command bash
require_command grep
require_command helm

load_versions
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/capz-orka-validate.XXXXXX")
trap 'cleanup_temp_dir "$temp_dir"' EXIT

for script in "$SCRIPT_DIR"/*.sh; do
  bash -n "$script"
done

[[ $DASHBOARD_CHART_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] || fail "chart version is not an exact prerelease"
[[ $DASHBOARD_ENGINE_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail "engine commit is not a full SHA"
for digest in "$DASHBOARD_CHART_DIGEST" "$DASHBOARD_CHART_ASSET_DIGEST" \
  "$DASHBOARD_IMAGE_DIGEST" "$DASHBOARD_ANALYZER_DIGEST" "$DASHBOARD_FIXER_DIGEST"; do
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid digest: $digest"
done
[[ $ORKA_REQUIRED_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail "Orka commit is not a full SHA"

skill_file="$ROOT_DIR/skills/aks-kubernetes-version-support.yaml"
[[ -f $skill_file ]] || fail "AKS version support skill is missing"
skill_count=$(find "$ROOT_DIR/skills" -maxdepth 1 -type f -name '*.yaml' | wc -l | tr -d ' ')
[[ $skill_count == 13 ]] || fail "expected 13 consumer skills, found $skill_count"
grep -Fq 'supported non-LTS version or enable the required support plan' "$skill_file"
grep -Fq 'Before naming a source file, use grep_repo or read_repo_file' "$skill_file"
grep -Fq 'Do not provide an exact cloud-provider command or option name' "$skill_file"
if grep -Eq -- '(^|[[:space:]])az[[:space:]]|--[[:alnum:]-]+' "$skill_file"; then
  fail "AKS version support skill contains ungrounded cloud CLI syntax"
fi

expected_schedule="$temp_dir/values-scheduled.yaml"
printf 'fetcher:\n  suspend: false\n' > "$expected_schedule"
cmp -s "$expected_schedule" "$DEPLOY_DIR/values-scheduled.yaml" || fail "values-scheduled.yaml contains more than the reviewed promotion"

grep -Fxq 'mode: cron' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  suspend: true' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  schedule: "0 */6 * * *"' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  concurrencyPolicy: Forbid' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  activeDeadlineSeconds: 86400' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  backoffLimit: 0' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  restartPolicy: Never' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  type: orka-container' "$DEPLOY_DIR/values.yaml"
grep -Fxq '    taskTimeout: 55m' "$DEPLOY_DIR/values.yaml"
grep -Fxq '    maxConcurrentTasks: 2' "$DEPLOY_DIR/values.yaml"
grep -Fxq '      existingSecret: ""' "$DEPLOY_DIR/values.yaml"
grep -Fxq '      agentpool: replace-with-cpu-agentpool' "$DEPLOY_DIR/values.yaml"
grep -Fxq '    enabled: false' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  accessMode: ReadWriteMany' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  retain: true' "$DEPLOY_DIR/values.yaml"
grep -Fxq '    enabled: true' "$DEPLOY_DIR/values.yaml"
grep -Fxq '    timeout: 30m' "$DEPLOY_DIR/values.yaml"
grep -Fxq '  timeout: 45m' "$ROOT_DIR/project.yaml"

grep -Fq "tag: v$DASHBOARD_CHART_VERSION" "$DEPLOY_DIR/values.yaml"
if grep -Eiq 'tag:[[:space:]]*(latest|main|v[0-9]+)[[:space:]]*$' "$DEPLOY_DIR/values.yaml"; then
  fail "mutable image tag found"
fi
if grep -RInE 'ghp_|github_pat_|AKIA|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|clientSecret: [^"[:space:]]|sessionKey: [^"[:space:]]|token: [^"[:space:]]' \
  "$ROOT_DIR" --exclude-dir=.git --exclude=validate.sh; then
  fail "possible committed secret value found"
fi
em_dash=$(printf '\u2014')
if grep -RIn "$em_dash" "$ROOT_DIR" --exclude-dir=.git; then
  fail "em dash found"
fi

base_render="$temp_dir/base.yaml"
scheduled_render="$temp_dir/scheduled.yaml"
actions_render="$temp_dir/actions.yaml"
"$SCRIPT_DIR/render.sh" --output "$base_render"
"$SCRIPT_DIR/render.sh" --allow-scheduled --values "$DEPLOY_DIR/values-scheduled.yaml" --output "$scheduled_render"
if [[ -f $DEPLOY_DIR/values-actions.yaml ]]; then
  "$SCRIPT_DIR/render.sh" --values "$DEPLOY_DIR/values-actions.yaml" --output "$actions_render"
fi

grep -Fq 'suspend: true' "$base_render"
grep -Fq 'suspend: false' "$scheduled_render"
grep -Fq -- '-analysis-runtime=orka-container' "$base_render"
grep -Fq 'automountServiceAccountToken: true' "$base_render"
grep -Fq 'name: ORKA_API_TOKEN_FILE' "$base_render"
grep -Fq 'value: /var/run/secrets/kubernetes.io/serviceaccount/token' "$base_render"
if grep -Eq '^[[:space:]]*- name: ORKA_API_TOKEN$' "$base_render"; then
  fail "base render uses a static Orka API token"
fi
grep -Fq 'resources: ["tasks"]' "$base_render"
grep -Fq 'resources: ["configmaps"]' "$base_render"
grep -Fq 'kind: ValidatingAdmissionPolicy' "$base_render"
grep -Fq 'id: aks-kubernetes-version-support' "$base_render"
grep -Fq 'K8sVersionNotSupported' "$base_render"
grep -Fq "image: ghcr.io/willie-yao/prow-ai-dashboard:v$DASHBOARD_CHART_VERSION" "$base_render"
grep -Fq -- "-orka-analysis-image=ghcr.io/willie-yao/prow-ai-dashboard/analyzer:v$DASHBOARD_CHART_VERSION" "$base_render"
if grep -Fq 'ACTIONS_ENABLED' "$base_render"; then
  fail "write actions are enabled in the base render"
fi

if [[ -f $DEPLOY_DIR/values-actions.yaml ]]; then
  grep -Fq 'name: ACTIONS_ENABLED' "$actions_render"
  grep -Fq 'value: "true"' "$actions_render"
  grep -Fq 'name: OAUTH_CLIENT_ID' "$actions_render"
  grep -Fq "image: ghcr.io/willie-yao/prow-ai-dashboard/fixer:v$DASHBOARD_CHART_VERSION" "$actions_render"
  grep -Fq 'app.kubernetes.io/component: orka-fix-runtime' "$actions_render"
  grep -Fq 'resources: ["tasks"]' "$actions_render"
  grep -Fq 'name: ORKA_API_TOKEN_FILE' "$actions_render"
  if grep -Eq '^[[:space:]]*- name: ORKA_API_TOKEN$' "$actions_render"; then
    fail "actions render uses a static Orka API token"
  fi
fi

info "validation passed"
