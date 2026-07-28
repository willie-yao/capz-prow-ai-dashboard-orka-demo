# Orka cluster installation

Orka is a separate cluster-level Helm release. The dashboard chart does not
install Orka, its controller, its workers, or its CRDs. Multiple dashboards may
share one compatible Orka release.

## Release status

No `orka-agents/orka` release or tag existed when this guide was verified on
July 27, 2026. The normal installer is fail-closed until `versions.env` contains
an exact published chart and the matching runtime image digests. Do not fill
those fields from an unverified `0.1.1` tag. The release must contain Orka commit
`fde3b7925c367784570fcc36d7a5b3a51747bf10` or later and publish all four runtime
images plus the chart.

The final operator path is:

```bash
deploy/orka/install.sh --context <non-production-context>
deploy/orka/validate.sh --context <non-production-context>
```

The installer always uses release `orka` in namespace `orka-system` unless the
operator explicitly selects different names. It refuses context `h100`, checks
for conflicting Orka installations, verifies persistent storage prerequisites,
requires confirmation, validates the chart digest, installs the chart, waits for
all 12 CRDs and both Deployments, verifies the REST API and RBAC, and records
non-secret version evidence under ignored `deploy/evidence/`.

## Maintainer-only source validation

Until a release exists, maintainers may package the chart from the exact minimum
source commit for lint, render, and temporary kind validation:

```bash
git -C /path/to/orka checkout --detach \
  fde3b7925c367784570fcc36d7a5b3a51747bf10
deploy/orka/package-source.sh \
  --source-dir /path/to/orka \
  --output-dir /tmp/orka-chart
```

This source path does not build, publish, or provide matching runtime images. It
is not a turnkey end-user installation and is not approved for production or a
cloud-cluster installation.

## Upgrade and uninstall

Helm does not update files from a chart's `crds/` directory during upgrade.
Run the guarded CRD-first workflow with an exact target chart and version:

```bash
deploy/orka/upgrade.sh \
  --context <non-production-context> \
  --chart <exact-released-chart-reference> \
  --version <exact-version>
```

The script applies the exact target CRDs with the `orka-crd-lifecycle` field
manager, replaces each CRD spec behind a resourceVersion test, waits for all
CRDs, and only then upgrades and validates the release. It also takes a
cluster-wide Lease so two CRD lifecycle operations cannot run concurrently.

See [`uninstall.md`](uninstall.md) before removing a release. Helm retains CRDs
and custom resources, but release resources including the chart-managed store
PVC are removed.

## Owned resources

The Orka chart manages the controller, worker ServiceAccounts and RBAC, REST
Service, harness wrapper, persistent store, and these 12 CRDs:

- `agentruntimes.core.orka.ai`
- `agents.core.orka.ai`
- `providers.core.orka.ai`
- `repositorymonitors.core.orka.ai`
- `repositoryscans.core.orka.ai`
- `skills.core.orka.ai`
- `substrateactorpools.core.orka.ai`
- `tasks.core.orka.ai`
- `tools.core.orka.ai`
- `gatewaybindings.gateway.orka.ai`
- `gatewayclasses.gateway.orka.ai`
- `gateways.gateway.orka.ai`

A fresh Helm install creates the CRDs before release resources. The chart now
includes AgentRuntime and SubstrateActorPool controller permissions, so the
dashboard must not patch or broaden Orka controller RBAC.

## Configuration

[`values.yaml`](values.yaml) contains only non-secret, cluster-operator-owned
settings. An empty harness-wrapper Secret and token configuration makes the chart
generate and preserve a release-local token. Never commit that token. The demo
does not enable GitHub webhooks or label-triggered automation.

Use one Orka controller release per namespace. Multiple releases require unique
release names, isolated controller namespaces, and distinct non-empty watch
namespaces. Never combine a cluster-wide watcher with namespace-scoped releases.

OpenCode Agent setup remains a separate operator step. See
[`opencode-agent.yaml`](opencode-agent.yaml). Model credentials and the Agent are
not created by the Orka installer.
