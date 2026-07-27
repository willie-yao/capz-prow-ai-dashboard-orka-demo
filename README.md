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
- optional operator-managed Orka OpenCode Agent example
- secure Secret creation, read-only preflight, install, one-run, and live
  validation scripts
- CI that pulls, lints, renders, and asserts every supported configuration

## Pinned prerequisites

| Component | Pin |
| --- | --- |
| Dashboard chart | `1.0.0-beta.6` |
| Dashboard engine | `1281269cc51f3172072396da3f2e734ac93e3445` |
| Orka source | `d03acb995b6014a6e855181c50b922b65ea8e7ff` |

The chart is pulled from
`oci://ghcr.io/willie-yao/charts/prow-ai-dashboard`. Exact OCI chart and image
digests are recorded in [`deploy/versions.env`](deploy/versions.env).

Orka is operator-managed. This repository does not install, upgrade, patch, or
modify the Orka controller. No tagged Orka release contains the required
OpenCode functionality at the time of this reference.

## Repository layout

```text
project.yaml                 CAPZ discovery, branding, analysis, and fix preview config
prompts/system.md            CAPZ prompt addendum
skills/                      CAPZ diagnostic recipes
deploy/values.yaml           suspended base Helm values
deploy/values-actions.yaml   optional OAuth actions and Orka fix runtime
deploy/values-scheduled.yaml explicit scheduling promotion only
deploy/versions.env          exact release commits and digests
deploy/orka/                 operator-managed OpenCode Agent example
deploy/scripts/              render, preflight, install, one-run, and validation tools
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
flow is:

1. choose an explicit non-production context
2. supply an RWX StorageClass, CPU agentpool, model Service, model ID, and
   dedicated demo OAuth application
3. run read-only preflight
4. install into a new namespace with scheduling suspended
5. create the analyzer model Secret in the chart-created analysis namespace
6. review the installed resources
7. create exactly one manual fetch Job
8. preserve evidence and run live verification
9. port-forward the server for authenticated UI validation
10. leave the CronJob suspended

The scripts do not apply `deploy/values-scheduled.yaml`.

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
