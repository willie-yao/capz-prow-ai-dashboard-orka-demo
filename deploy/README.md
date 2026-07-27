# Helm and Orka deployment track

This directory deploys the CAPZ consumer with the public
[`prow-ai-dashboard`](https://github.com/willie-yao/prow-ai-dashboard) Helm
chart. The base configuration is suspended, uses a fresh retained ReadWriteMany
PVC, enables experimental Orka container analysis, enables authenticated chat
and traces, and disables GitHub write actions.

## Safety state

The checked-in base state is intentionally inert:

- `mode: cron`
- `fetcher.suspend: true`
- `fetcher.concurrencyPolicy: Forbid`
- no ingress
- ClusterIP service only
- GitHub write actions disabled
- Orka fix generation disabled
- no static Orka result API Secret
- no committed Secret values

Every script requires an explicit Kubernetes context and rejects any context or
target namespace containing `h100`. Installation accepts no scheduling overlay.
The first-run script reserves and creates at most one manual fetch Job.

## Pinned versions

[`versions.env`](versions.env) records the immutable release inputs:

- dashboard chart `1.0.0-beta.6`
- engine commit `1281269cc51f3172072396da3f2e734ac93e3445`
- OCI chart digest
  `sha256:c8c55a6acb6ac9cb1c8f3a02cd9ecc0ca4956825e837f99cab042db3d339f4dd`
- dashboard image digest
  `sha256:285a290804a7dc0c73e8481b1de5340de0a25d3ffcd411a9bed7198a23072b70`
- analyzer image digest
  `sha256:bf6fd8e8eefc5b35b51d7ba4583f68d0139c3d8f4b819cb5be1c721301b13195`
- fixer image digest
  `sha256:96253e557f22c46fe894e8bb23d1d76cef86a6b47034e0434affd0454fa6f052`

The values file uses the exact `v1.0.0-beta.6` image tags. The render and install
scripts pull the exact chart version and reject a chart digest mismatch.

## Orka prerequisite

This repository does not install, upgrade, or modify Orka. A cluster operator
must provide Orka built from exactly:

```text
d03acb995b6014a6e855181c50b922b65ea8e7ff
```

There is no tagged Orka release containing the required OpenCode integration at
the time of this reference. The deployed Orka workloads must expose the short or
full commit in an image tag, label, annotation, or environment value so
`preflight.sh` can verify it.

The operator-managed installation must provide:

- `tasks.core.orka.ai`
- `agents.core.orka.ai`
- Agent runtime type `opencode`
- an Orka REST result Service
- ready Service endpoints
- container Task support
- Task result authorization for Kubernetes ServiceAccount tokens

The preflight also verifies that the cluster supports
`ValidatingAdmissionPolicy`. The chart creates a release-scoped analysis
namespace, Task and ConfigMap RBAC, a restricted admission policy, and a
release-scoped ServiceAccount. Live Task authorization is verified after Helm
creates those resources.

## Required cluster inputs

The checked-in values use safe reserved placeholders. Supply real values through
environment variables before preflight, rendering for a cluster, or install:

```bash
export KUBE_CONTEXT=<non-production-context>
export DASHBOARD_NAMESPACE=capz-orka-demo
export RELEASE_NAME=capz-orka-demo

export RWX_STORAGE_CLASS=<rwx-storage-class>
export CPU_AGENTPOOL=<cpu-agentpool-label-value>
export MODEL_ENDPOINT=http://<service>.<namespace>.svc.cluster.local:8000/v1/chat/completions
export MODEL_ID=<provider-model-id>

export ADMIN_LOGIN=<github-login>
export OAUTH_CLIENT_ID=<dedicated-demo-oauth-client-id>
export OAUTH_REDIRECT_URL=https://<demo-host>/api/auth/callback
```

`CPU_AGENTPOOL` is the value of the `agentpool` node label. It is not hardcoded
to any production pool. Preflight requires at least one Ready matching node and
rejects a pool that advertises GPU resources.

`RWX_STORAGE_CLASS` must use a file or network provisioner that supports
ReadWriteMany. Known block-only provisioners are rejected. An unknown
provisioner requires explicit operator acknowledgement through
`ALLOW_UNKNOWN_RWX_STORAGE_CLASS=true` after its capabilities are verified.

The model endpoint must use cluster Service DNS. Preflight verifies the Service
and a ready EndpointSlice without creating a probe workload.

## Authentication model

Analysis chat and the private trace console are authenticated even though write
actions are disabled. The base values use a dedicated demo GitHub OAuth
application and an existing Secret named `dashboard-oauth`.

This does not enable issue or pull request writes. The server capability contract
reports chat and traces enabled while actions remain false. The optional actions
overlay is documented separately and must use a dedicated demo OAuth
application during validation.

## Secret boundaries

No Secret value belongs in Git, a Helm values file, shell history, or a command
line argument.

Dashboard namespace:

```text
dashboard-model
  AI_TOKEN

dashboard-oauth
  OAUTH_CLIENT_SECRET
  SESSION_KEY
```

Chart-created analysis namespace:

```text
orka-model
  token
```

The analyzer token is prompted separately. `create-secrets.sh` never copies the
dashboard token into the analysis namespace. It writes protected temporary files
with mode `0600`, uses `kubectl create secret --dry-run=client` only to construct
a manifest, and applies through server-side apply so no last-applied annotation
contains secret data.

Provide protected values through environment variables or secure prompts:

```bash
export DASHBOARD_AI_TOKEN=...
export ANALYZER_AI_TOKEN=...
export OAUTH_CLIENT_SECRET=...
export SESSION_KEY=...
```

Unset variables are prompted without echo. `SESSION_KEY` must contain at least
32 bytes.

## Local validation and render

Run the repository checks without contacting a Kubernetes cluster:

```bash
deploy/scripts/validate.sh
```

Render the exact chart with the safe placeholders:

```bash
deploy/scripts/render.sh --output deploy/.rendered/base.yaml
```

Render with real cluster-specific values without applying them:

```bash
deploy/scripts/render.sh --output deploy/.rendered/cluster.yaml
```

The render script passes `project.yaml`, `prompts/system.md`, and every skill by
`--set-file`. Generated output is ignored and must not be committed.

## Preflight

Preflight is read-only:

```bash
deploy/scripts/preflight.sh --context "$KUBE_CONTEXT"
```

It verifies:

- the context is explicit and is not `h100`
- the target namespace and release are new
- no worker or CronJob with the demo release label can race the writer
- the RWX StorageClass and CPU placement exist
- Orka CRDs, Service endpoints, OpenCode schema, and required commit marker exist
- the cluster supports ValidatingAdmissionPolicy
- the current installer identity can create the required cluster and namespaced
  resources
- the model Service has ready endpoints
- the rendered RBAC grants only the required Task and ConfigMap operations
- projected ServiceAccount authentication is rendered instead of a static Orka
  API token

## Install

Install only after preflight succeeds:

```bash
deploy/scripts/install.sh --context "$KUBE_CONTEXT"
```

The script:

1. reruns preflight
2. creates the dedicated dashboard namespace
3. creates the dashboard model and OAuth Secrets
4. installs the exact pinned chart with the CronJob suspended
5. discovers the retained chart-created analysis namespace by labels
6. creates the analyzer model Secret there
7. waits for the server Deployment
8. verifies the CronJob remains suspended
9. verifies no active fetch Job exists
10. verifies the dashboard ServiceAccount can manage Orka Tasks
11. prints the manual next command without running it

The chart creates a fresh retained PVC. `persistence.existingClaim` remains
empty. The historical H100 PVC and ConfigMap-copy workaround are not used.

## One manual first run

Review the installed resources before creating the only allowed manual Job:

```bash
export CONFIRM_RUN_ONCE=RUN
export EVIDENCE_DIR=/absolute/path/outside/this/repository
deploy/scripts/run-once.sh --context "$KUBE_CONTEXT"
```

The script verifies suspension and absence of active Jobs, reserves a unique Job
name on the CronJob, creates one Job, streams its logs, waits for a terminal
condition, and verifies suspension again. A reservation is not removed after a
failure. The script therefore refuses to create a retry Job.

If the Job fails, preserve its logs, Job state, Orka Tasks, and existing
published dashboard data. Do not modify Orka or the model service to force a
success.

## Live verification

After the manual Job is terminal:

```bash
deploy/scripts/verify-live.sh --context "$KUBE_CONTEXT"
```

It verifies:

- server readiness, retained RWX PVC, and suspended CronJob
- no active fetch Job
- Task-only ServiceAccount RBAC
- projected token-file authentication
- terminal analyzer Tasks
- authenticated Orka REST result retrieval with a short-lived TokenRequest
- dashboard, manifest, flakiness, and search index publication
- recurring-pattern IDs and content hashes
- direct private operational files return `404`
- unsafe methods against static data return `405`
- capabilities expose chat and traces but not write actions

For direct private-state existence and hash validation, supply a trusted
inspector image pinned by digest:

```bash
export PRIVATE_STATE_INSPECTOR_IMAGE=<image>@sha256:<digest>
deploy/scripts/verify-live.sh --context "$KUBE_CONTEXT"
```

The temporary Pod mounts the PVC read-only, checks that `ai_cache.json` and
`ai_traces.json` are nonempty, prints only their hashes, and deletes itself on
success. It never prints file contents.

Browser validation and authenticated chat checks are performed after the server
is port-forwarded and the dedicated demo OAuth callback is reachable.

## Scheduling promotion

[`values-scheduled.yaml`](values-scheduled.yaml) contains only:

```yaml
fetcher:
  suspend: false
```

It is not used by the install or first-run scripts. Applying it would enable the
schedule `0 */6 * * *`, which starts a fetch Job at minute 0 every six hours in
the controller's configured timezone.

Do not apply this overlay during implementation or initial acceptance. Leave the
CronJob suspended after validation. A later explicit decision must review first
run duration, model cost, cache reuse, notifications, analyzer concurrency,
provider capacity, and data freshness requirements.
