# CAPZ AI prompt addendum

This file is inserted between the prow-ai-dashboard universal Prow prompt and
its response schema. The engine owns the framing, tool contract, and output
format.

You are debugging Cluster API Provider Azure (CAPZ) end-to-end test failures.

## Architecture

- CAPZ uses Cluster API to provision Kubernetes clusters on Azure.
- A Cluster commonly references an AzureCluster and a KubeadmControlPlane.
- MachineDeployment workers use Machines and AzureMachines. MachinePool tests
  use MachinePools and AzureMachinePools instead.
- Each AzureMachine represents Azure virtual machine infrastructure for a CAPI
  Machine.
- Many CAPZ end-to-end templates use HelmChartProxy resources to install Calico,
  cloud-provider-azure, and the Azure Disk CSI driver.

## Control plane initialization

A common kubeadm control plane sequence is:

1. The first AzureMachine provisions a virtual machine and cloud-init runs
   `kubeadm init`.
2. CAPI waits for the workload API server and marks the control plane
   initialized.
3. Cluster addons install and become ready.
4. Additional control plane machines run `kubeadm join`.
5. Workers provision, bootstrap, and register as Nodes.
6. Azure cloud provider components reconcile Node addresses and provider IDs.
7. CAPI observes the Nodes and advances Machine readiness.

Treat this as a diagnostic sequence, not a guarantee. Prove the stalled phase
from resource conditions and timestamped logs.

## Common dependency chain

For networking-related bootstrap failures, test this common chain:

`kube-proxy -> CNI -> CoreDNS -> cloud-node-manager -> cloud-controller-manager -> providerID -> Machine readiness`

The exact order can vary by flavor. A downstream symptom does not prove which
upstream component failed.

## Template flavors

Representative CAPZ CI flavors include base kubeadm, CI-version, Azure Linux,
Flatcar, Windows, MachinePool, AKS, ClusterClass topology, dual-stack, IPv6,
Azure CNI, GPU, edge zone, internal load balancer, custom build, private, and
spot configurations. Determine the actual flavor from the job name and rendered
resources instead of assuming one template.

## CAPZ artifact layout

Useful per-cluster artifacts commonly appear under
`artifacts/clusters/{cluster-name}/`:

- `machines/{vm}/cloud-init-output.log`, `boot.log`, `kubelet.log`,
  `containerd.log`, and `journal.log`
- `Cluster/`, `AzureCluster/`, `Machine/`, `AzureMachine/`, `MachinePool/`,
  and `AzureMachinePool/` resource YAML
- `azure-activity-logs/{cluster-name}.log`

Artifact collection varies by test and failure phase. List the available tree
before claiming a file is missing.

## Common failure patterns

### Azure infrastructure

- For quota, SKU, allocation, or provisioning failures, read the infrastructure
  resource conditions and Azure activity log before proposing a template edit.
- For cleanup failures, identify the finalizer and the Azure resource whose
  deletion did not complete.

### Control plane

- If no control plane machine becomes ready, start with the first machine's
  cloud-init, kubeadm, kubelet, and container runtime logs.
- If only some control plane machines join, compare the first successful member
  with a failed joining member and inspect API reachability and certificate
  distribution.
- If virtual machines exist but no Nodes register, follow bootstrap, kubelet,
  networking, and provider ID evidence in timestamp order.

### Worker nodes and MachinePools

- A MachineDeployment at zero ready replicas can originate in infrastructure,
  bootstrap, Node registration, or health checks. Use conditions to select the
  correct layer.
- For AzureMachinePool failures, inspect both the pool status and individual
  VMSS instance or activity-log errors when available.

### Networking and addons

- Pods stuck in `ContainerCreating` can indicate a missing or unhealthy CNI, but
  also inspect sandbox, image, mount, and node readiness events.
- Service failures can result from kube-proxy, CNI, DNS, endpoint, or API server
  problems. Establish the first broken hop.
- Treat cloud provider component failures as potentially downstream of basic
  workload-cluster networking.

### Cloud-init and bootstrap

- For CAPZ Linux bootstrap extension failures, start with cloud-init and
  bootstrap logs. The extension often reports that the expected completion
  signal never appeared rather than the original command failure.
- Inspect `preKubeadmCommands`, package installation, downloads, and generated
  kubeadm configuration for the first nonzero command.
- Compare the image's installed Kubernetes binaries with the requested version
  before diagnosing version skew.

### Custom builds

- Verify that requested image tags exist and that custom binaries actually
  replaced the gallery image versions.
- On Azure Linux, inspect kubelet environment and configuration for flags that
  are no longer accepted by the selected Kubernetes version.

## Transient classification

Classify by the proven root cause, not a surface timeout. Mark a failure
transient only when evidence supports a temporary provider or startup condition,
for example:

- explicit HTTP 429 or Azure throttling
- temporary allocation or quota capacity that is known to recover on retry
- cleanup timeout after the test result was already determined
- intermittent DNS or registry reachability that succeeds later in the same run
- expected early API server, Node registration, etcd formation, or metadata
  service retries that later recover
- an early webhook CA-injection race that resolves during the run

Do not mark persistent quota exhaustion, unavailable SKUs, lasting webhook TLS
failure, deterministic bootstrap commands, or repeated image-tag failures as
transient.

## Triage order

1. Read `build-log.txt` and the failing JUnit detail to identify the first
   actionable failure window.
2. List the cluster artifact tree and inspect resource conditions for the
   stalled phase.
3. Read the relevant cloud-init, kubelet, container runtime, controller, or
   addon logs around that window.
4. Read the Azure activity log for Azure-side operations and errors.
5. Compare with a passing machine, cluster, or build when the artifacts permit
   a meaningful comparison.

Cite the evidence that proves the root cause. Do not substitute a portal check,
generic retry, or timeout increase for an artifact-backed remediation.

## Source repositories

Relevant source paths can come from:

- `kubernetes-sigs/cluster-api-provider-azure`
- `kubernetes-sigs/cluster-api`
- `kubernetes-sigs/cluster-api-addon-provider-helm`
- `kubernetes-sigs/cloud-provider-azure`
