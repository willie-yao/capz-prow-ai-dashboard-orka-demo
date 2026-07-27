# Optional Orka OpenCode fix runtime

This directory is an operator-facing example for the optional authenticated fix
preview path. The dashboard repository does not install, patch, upgrade, or own
Orka.

## Required Orka build

The installed Orka control plane must contain commit:

```text
d03acb995b6014a6e855181c50b922b65ea8e7ff
```

That commit merged the verified OpenCode runtime integration. No tagged Orka
release contains the required functionality at the time of this reference. The
base preflight checks the CRD for `opencode` and checks the installed workload
metadata for commit marker `d03acb`.

The Orka operator is responsible for controller permissions required by that
source build. Do not broaden the dashboard ServiceAccount to compensate for an
operator installation problem. The dashboard ServiceAccount remains limited to
Orka Tasks and the analysis input ConfigMaps required by the chart.

## Agent example

[`opencode-agent.yaml`](opencode-agent.yaml) defines the Agent referenced by
`project.yaml`:

```text
orka-system/opencode-fixer
```

Before an operator applies the example, replace only the model name with the
endpoint-specific provider model ID. The Agent runtime remains `opencode`.

Applying the Agent is an Orka operator action and is not part of the base install
script:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f deploy/orka/opencode-agent.yaml
```

Do not run that command unless the selected context is non-production and the
operator has approved the Agent configuration. The dashboard task does not
install or modify the Orka controller.

## Model credentials

Create `orka-system/opencode-credentials` without committing a Secret manifest:

```bash
export OPENAI_BASE_URL=https://<provider-endpoint>/v1
export OPENAI_API_KEY=...  # omit when the endpoint is unauthenticated
deploy/scripts/create-secrets.sh --context "$KUBE_CONTEXT" opencode-credentials
```

The Secret contains:

```text
OPENAI_BASE_URL
OPENAI_API_KEY when required
```

The Secret belongs to Orka and is mounted only into the Agent workspace. The
model endpoint, model credential, and model ID do not belong in `project.yaml`.

## Source repository credentials

CAPZ is public, so the example does not configure `git_secret`. A private source
repository requires a separate read-only clone credential owned by Orka. Never
reuse the GitHub OAuth token or another write-capable dashboard token as the
clone credential.

The boundary is strict:

- Orka clones the pinned source and generates a workspace change.
- Orka captures the final workspace and returns the outer structured result.
- The Agent never receives the GitHub write token.
- The dashboard verifies the base SHA, paths, file list, and reconstructed diff.
- The dashboard presents a preview and performs any later GitHub write.

## Actions overlay

[`../values-actions.yaml`](../values-actions.yaml) enables OAuth actions and the
fix runtime. The base [`../values.yaml`](../values.yaml) remains actions-disabled
and fix-runtime-disabled.

Render the optional configuration without applying it:

```bash
deploy/scripts/render.sh \
  --values deploy/values-actions.yaml \
  --output deploy/.rendered/actions.yaml
```

Before any application:

- replace the OAuth client ID, callback URL, and administrator login through the
  environment inputs documented in [`../README.md`](../README.md)
- create `dashboard-oauth`
- create `opencode-credentials`
- replace the CLA author placeholders in `project.yaml`
- verify `opencode-fixer` is Ready
- confirm the source target and fork behavior

During acceptance, generate preview-only issue and fix drafts. Stop before the
final GitHub confirmation. Do not create an issue or pull request in
`kubernetes-sigs/cluster-api-provider-azure`.
