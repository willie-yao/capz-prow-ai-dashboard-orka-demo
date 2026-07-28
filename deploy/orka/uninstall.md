# Uninstall Orka

Orka is a separate cluster-level release. Uninstall it only after every
dashboard and other client has stopped creating Orka Tasks.

Use an explicit context and refuse `h100`:

```bash
KUBE_CONTEXT=<non-production-context>
test "$KUBE_CONTEXT" != h100
helm uninstall orka \
  --kube-context "$KUBE_CONTEXT" \
  --namespace orka-system
```

Helm removes release-scoped resources such as Deployments, Services,
ServiceAccounts, RBAC bindings, Secrets, and the chart-managed PVC. Back up the
Orka store before uninstalling if its result and session data must survive.

Helm does not remove CRDs from a chart's `crds/` directory. All 12 Orka CRDs
remain, and Kubernetes retains the Orka custom resources stored under them. The
resources are unavailable until a compatible controller is installed again.

Verify retained CRDs without deleting them:

```bash
for crd in \
  agentruntimes.core.orka.ai \
  agents.core.orka.ai \
  providers.core.orka.ai \
  repositorymonitors.core.orka.ai \
  repositoryscans.core.orka.ai \
  skills.core.orka.ai \
  substrateactorpools.core.orka.ai \
  tasks.core.orka.ai \
  tools.core.orka.ai \
  gatewaybindings.gateway.orka.ai \
  gatewayclasses.gateway.orka.ai \
  gateways.gateway.orka.ai; do
  kubectl --context "$KUBE_CONTEXT" get "crd/$crd"
done
```

CRDs are cluster-scoped and may be shared by multiple dashboards or Orka
releases. Deleting a CRD deletes every custom resource for that kind across the
cluster. CRD deletion is a separate destructive operation and is never part of
the demo uninstall flow. This repository intentionally has no automated CRD
deletion script.
