# CAPZ Prow AI Dashboard Orka Demo

A concrete public consumer reference for deploying
[`prow-ai-dashboard`](https://github.com/willie-yao/prow-ai-dashboard) for
Cluster API Provider Azure test results with Helm and experimental Orka
container analysis.

## Safety defaults

The repository is intentionally safe by default:

- the fetcher runs in Cron mode but remains suspended
- the server is ClusterIP-only and no ingress is created
- GitHub write actions are disabled
- Orka fix generation is disabled
- persistence uses a fresh retained ReadWriteMany PVC
- Orka result access uses rotating projected ServiceAccount tokens
- no credentials, cache state, traces, dashboard data, or Secret values are
  committed
- every cluster-writing script requires an explicit context and refuses `h100`
- the first-run script can reserve and create only one manual fetch Job

The scheduled overlay is documented but is not applied during implementation or
initial acceptance. Validation must not create a CAPZ issue or pull request.

## What the reference contains

- CAPZ TestGrid discovery from
  `sig-cluster-lifecycle-cluster-api-provider-azure`
- CAPZ-specific prompt knowledge and twelve reviewed diagnostic skills
- exact dashboard chart and image pins
- suspended Helm Cron deployment
- experimental Orka container analyzer Tasks with bounded concurrency
- retained dashboard data, AI cache, traces, and interactive state
- authenticated analysis chat and private trace console
- optional GitHub OAuth actions overlay
- separate cluster-level Orka Helm installation and CRD lifecycle tools
- operator-owned Orka OpenCode Agent manifest, Secret setup, and readiness checks
- secure Secret creation, read-only preflight, install, one-run, and live
  validation scripts
- CI that pulls, lints, renders, and asserts every supported configuration

## Pinned prerequisites

| Component | Pin |
| --- | --- |
| Dashboard chart | `1.0.0-beta.6` |
| Dashboard engine | `1281269cc51f3172072396da3f2e734ac93e3445` |
| Orka release | Not published as of July 28, 2026 |
| Orka minimum source | `fde3b7925c367784570fcc36d7a5b3a51747bf10` |

The dashboard chart is pulled from
`oci://ghcr.io/willie-yao/charts/prow-ai-dashboard`. Exact dashboard chart and
image digests are recorded in [`deploy/versions.env`](deploy/versions.env).

Orka is operator-managed as a separate cluster-level Helm release. This
repository provides explicit install, validate, upgrade, uninstall, and Agent
setup tools under [`deploy/orka/`](deploy/orka/). The dashboard chart and
dashboard installer never invoke them implicitly. No Orka tag or GitHub release
exists as of July 28, 2026, so the normal Orka installer remains fail-closed.
The source-commit path is maintainer-only and limited to local chart and kind
validation because matching released runtime images do not exist.

## Repository layout

```text
project.yaml                 CAPZ discovery, branding, analysis, and fix preview config
prompts/system.md            CAPZ prompt addendum
skills/                      CAPZ diagnostic recipes
deploy/values.yaml           suspended base Helm values
deploy/values-actions.yaml   optional OAuth actions and Orka fix runtime
deploy/values-scheduled.yaml explicit scheduling promotion only
deploy/versions.env          exact dashboard release commits and digests
deploy/orka/                 separate Orka release lifecycle and OpenCode Agent setup
deploy/scripts/              dashboard render, preflight, install, one-run, and validation tools
.github/workflows/validate.yml
```

## Validate locally

Requirements are Bash, Helm 4, and standard Unix tools. Cluster commands also
require `kubectl` and `jq`.

```bash
deploy/scripts/validate.sh
```

The validation downloads the exact public chart without registry credentials,
verifies its digest, runs Helm lint, renders the base, actions, and scheduling
configurations, and asserts the safety contracts.

Render without applying:

```bash
deploy/scripts/render.sh --output deploy/.rendered/base.yaml

deploy/scripts/render.sh \
  --values deploy/values-actions.yaml \
  --output deploy/.rendered/actions.yaml
```

## Deployment and acceptance

Read [`deploy/README.md`](deploy/README.md) before using a cluster. The deployment
flow is explicit and Orka-first:

1. choose an explicit non-production context
2. install Orka as release `orka` in namespace `orka-system`
3. validate the 12 CRDs, controller, workers, harness wrapper, store, REST API,
   and RBAC
4. create the OpenCode model Secret
5. apply and validate `opencode-fixer`
6. supply the dashboard StorageClass, CPU agentpool, model Service, model ID,
   OAuth application, and protected Secret inputs
7. run dashboard preflight and install with the CronJob suspended
8. verify the dashboard ServiceAccount Task RBAC and review installed resources
9. create exactly one manual fetch Job
10. validate Tasks, results, cache, patterns, traces, and the UI
11. leave the CronJob suspended until a separate promotion decision

The dashboard installer creates dashboard model and OAuth Secrets before Helm,
then creates the analyzer model Secret after the chart-created analysis
namespace exists. It never installs Orka. The scripts do not apply
`deploy/values-scheduled.yaml`.

The Orka release steps cannot run on a cloud cluster until a verified release
publishes the chart and all matching runtime images. No H100 installation or
upgrade is permitted.

## Optional actions and fixes

The base configuration enables authenticated chat and traces but not writes.
[`deploy/values-actions.yaml`](deploy/values-actions.yaml) separately enables
OAuth write actions and the Orka fix runtime. The OpenCode boundary is documented
in [`deploy/orka/README.md`](deploy/orka/README.md).

Preview validation must stop before final GitHub confirmation. Do not create a
real issue or pull request in
`kubernetes-sigs/cluster-api-provider-azure`.

## Scheduling promotion

[`deploy/values-scheduled.yaml`](deploy/values-scheduled.yaml) contains only:

```yaml
fetcher:
  suspend: false
```

Applying it would enable `0 */6 * * *`, starting a fetch at minute 0 every six
hours in the controller's configured timezone. Promotion requires a later
explicit decision after reviewing duration, model cost, cache reuse,
notifications, analyzer concurrency, provider capacity, and data freshness.

## License

Apache License 2.0. See [LICENSE](LICENSE).
