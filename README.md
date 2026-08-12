# ACM & OpenShift GitOps Failover Guide

Verified live against the `k8socp.com` lab (contexts `hub`, `spoke`, `sage`)
on 2026-08-12. Every command in this guide was actually run; outputs shown are
real. Work in progress — sections are added as they are verified.

## Environment

| Cluster | API | OCP | Shape | Role (before) | Role (after) |
| --- | --- | --- | --- | --- | --- |
| hub | api.hub.k8socp.com | — | — | ACM 2.17.0 hub (`local-cluster` + `spoke` managed) | ACM hub |
| spoke | api.spoke.k8socp.com | 4.21.20 | SNO (1 node, all roles) | ACM managed cluster of hub | standalone ACM 2.17.0 hub |
| sage | api.sage.k8socp.com | — | — | powered off during this exercise | — |

Facts recorded from the live environment before the change:

- `spoke` was imported into hub 33 days ago; klusterlet in **Singleton** mode
  (`deployOption.mode: Singleton`), `clusterName: spoke`, agent namespaces
  `open-cluster-management-agent`, `-agent-addon`, `open-cluster-management-policies`.
- Enabled addons on spoke: `application-manager`, `cert-policy-controller`,
  `config-policy-controller`, `governance-policy-framework`, `klusterlet-addon-search`.
- Hub pushed 13 replicated policies to spoke (`acm-policy-research.*`,
  `rhcl-ossm-policy.*`) — see `~/acm-policy-research` for that demo's runbook.
- OpenShift GitOps is NOT installed on spoke. The `openshift-gitops(-operator)`
  namespaces on spoke exist but are empty shells created by ACM's GitOps addon
  (`apps.open-cluster-management.io/gitopsaddon: "true"` label).
- Spoke catalog offers ACM channels release-2.15/2.16/2.17; hub runs MCH 2.17.0,
  so release-2.17 was chosen for version parity (a hard requirement if ACM
  hub backup/restore is ever used between the two hubs).

## Phase 1 — Make `spoke` a standalone ACM hub

### 1.1 Install the ACM operator (safe while still attached)

Installing the *operator* does not conflict with the klusterlet; only the
`MultiClusterHub` (which self-imports `local-cluster` and would collide with
the existing `klusterlet` CR) must wait until after detach.

```console
$ oc --context spoke apply -f manifests/10-acm-operator.yaml
namespace/open-cluster-management created
operatorgroup.operators.coreos.com/open-cluster-management created
subscription.operators.coreos.com/advanced-cluster-management created
```

Verified: CSV `advanced-cluster-management.v2.17.0` reached `Succeeded` in
~3 minutes.

### 1.2 Detach spoke from the old hub

Record the hub-side state first (what the detach must clean up):

```console
$ oc --context hub get manifestwork -n spoke
NAME                                         AGE
addon-application-manager-deploy-0           33d
addon-cert-policy-controller-deploy-0        33d
addon-config-policy-controller-deploy-0      33d
addon-governance-policy-framework-deploy-0   33d
addon-search-collector-deploy-0              33d
spoke-klusterlet                             33d
spoke-klusterlet-crds                        33d
```

The clean detach is a single delete on the hub; four finalizers do the rest:

```console
$ oc --context hub delete managedcluster spoke --wait=false
managedcluster.cluster.open-cluster-management.io "spoke" deleted
# finalizers: resource-cleanup, managedcluster-import-controller cleanup,
#             api-resource-cleanup, manifestwork-cleanup
```

Observed sequence and timing (live, 2026-08-12):

1. `ManagedClusterImportSucceeded` flips to `False/ManagedClusterDetaching`;
   addon ManifestWorks are deleted one by one (~4 min for 5 addons).
2. `spoke-klusterlet` + `spoke-klusterlet-crds` ManifestWorks are deleted;
   the work agent uninstalls the klusterlet and all agent namespaces on
   spoke (~30 s).
3. Hub-side namespace `spoke` and the `ManagedCluster` object disappear.

**Total: ~4.5 minutes** from delete to fully clean on both sides.

Verify on spoke (all should come back empty / NotFound):

```console
$ oc --context spoke get klusterlet
$ oc --context spoke get ns | grep open-cluster-management
$ oc --context spoke get crd | grep open-cluster-management
appliedmanifestworks.work.open-cluster-management.io   # harmless leftovers,
clusterclaims.cluster.open-cluster-management.io       # reused by the new hub
```

**Surprise verified live — detach pruned the policy-managed workloads.**
The entire `acm-policy-demo` namespace on spoke (policy-created ConfigMap,
`demo-hello` helm release installed by the application-manager addon, ESO
demo objects) was REMOVED during detach, along with the replicated policies
and even the policy CRDs. Do not assume policy-deployed workloads survive a
detach: anything the application-manager addon installed is uninstalled with
the addon, and policy-created objects were pruned with their policies. If a
managed cluster's workloads must survive re-homing to a new hub, they must
come from GitOps/Argo (cluster-local reconciliation), not from hub-pushed
addons — this observation drives the Phase 2 design.

### 1.3 Create the MultiClusterHub

Only after 1.2 is fully clean (the `local-cluster` self-import creates a
klusterlet named `klusterlet`, which would collide with the old one):

```console
$ oc --context spoke apply -f manifests/20-multiclusterhub.yaml
multiclusterhub.operator.open-cluster-management.io/multiclusterhub created
```

`availabilityConfig: Basic` because spoke is SNO (single replicas; the
default High doubles replicas for no benefit on one node).

### 1.4 Verify spoke is a self-managing hub

Observed install timeline on SNO (19.5 CPU / 95Gi allocatable): MCE CR
appeared ~6 min after MCH creation; `local-cluster` self-import
Joined/Available at ~7 min; **MCH `Running` at 10m20s**.

```console
$ oc --context spoke get mch -n open-cluster-management
NAME              STATUS    AGE   CURRENTVERSION   DESIREDVERSION   MESSAGE
multiclusterhub   Running   10m   2.17.0           2.17.0           All hub components ready.

$ oc --context spoke get managedclusters
NAME            HUB ACCEPTED   MANAGED CLUSTER URLS                JOINED   AVAILABLE   AGE
local-cluster   true           https://api.spoke.k8socp.com:6443   True     True        3m44s

$ oc --context spoke get klusterlet          # new self-managed klusterlet
NAME         AGE
klusterlet   4m20s
```

Post-install footprint: 24 pods in `multicluster-engine`, 23 in
`open-cluster-management`, zero not-Running; node at 11% CPU / 42% memory
(up from 4% / 36%). The old hub is unaffected (`local-cluster` only, MCH
Running). ACM 2.17 has no separate console route — use the OpenShift
console's cluster switcher ("All Clusters" perspective) on
`console-openshift-console.apps.spoke.k8socp.com`.

**Phase 1 result: two independent, same-version (2.17.0) ACM hubs.**

## Phase 2 — Failover design (decision pending)

Doc research (citations in [research-notes.md](research-notes.md), verified
against the ACM 2.17 doc source) narrows the design space:

- **Hub backup/restore (active/passive)** — cluster-backup-operator +
  OADP/Velero into S3-compatible storage; passive hub restores continuously
  with `veleroManagedClustersBackupName: skip`, failover = flip to `latest`.
  Hard requirements verified: same ACM version + namespace + pre-installed
  operators on both hubs (2.17.0 parity ✔), S3 target (lab has none yet —
  TrueNAS/MinIO would work), and — because this lab's clusters are
  *imported*, not Hive-created — **ManagedServiceAccount auto-import**
  (`useManagedServiceAccount: true`) or every failover ends in
  `Pending Import`. The old hub must be shut down or defused
  (paused BackupSchedule + `disable-auto-import` annotation) before
  activation.
- **GitOps as source of truth (active/active)** — both hubs run OpenShift
  GitOps fed from the same git repo; ACM `GitOpsCluster` + `Placement`
  auto-registers managed clusters into Argo (secrets minted from rotated
  ManagedServiceAccount tokens — no manual `argocd cluster add`). Hub loss
  is benign for running workloads (verified in docs AND observed live:
  spoke's workloads ran untouched through hub's outage today); the
  **pull-model** Argo addon keeps even *syncing* alive during hub loss,
  at the cost of centralized status only.
- **Manual re-import (no preparation)** — the baseline DR story: detach +
  re-import each cluster to the survivor. Today's live exercise measured
  exactly this path: clean detach ~4.5 min, and the hard lesson that
  **hub-pushed addon/policy workloads are pruned on detach** — only
  git-reconciled (or out-of-band) workloads survive re-homing.

The Phase 1 observation is the load-bearing argument: anything delivered by
hub addons (application-manager helm releases, `pruneObjectBehavior`
policies) dies with the hub relationship, while GitOps-delivered state is
cluster-local and survives. A failover design should therefore put workloads
in git delivered by Argo (pull model preferred), and use hub backup/restore
only for the hub's *own* state (cluster inventory, policies, placements).

(to be finalized and verified live — candidate: sage imported into the spoke
hub as the test subject, hub simulating the failed datacenter)

### 2a. S3-compatible backup storage (verified)

The customer runs ROSA and will use real AWS S3. The lab stand-in must be
(a) S3-compatible for the same OADP/Velero `aws` provider config, (b)
external to every cluster (the docs require the storage location reachable
from all hubs at all times — and it must survive the hub failure we
simulate), and (c) license-clean. **MinIO and Garage are AGPL — excluded.**
Chosen: **SeaweedFS** (Apache-2.0), from the TrueNAS **stable** catalog
train (chart 1.2.32, SeaweedFS 4.41, maintained by iX), on the existing NAS
that both cluster nodes verifiably reach.

Result, verified live:

- Endpoint `https://truenas.skrzypek.dev:30304` — TLS with the NAS's
  existing **Let's Encrypt** cert, already trusted by RHCOS on both nodes
  (`curl` exit 0, no caCert needed).
- Identity `velero` via `weed shell s3.configure` (persisted in the filer);
  anonymous requests correctly denied (403 from both cluster nodes).
- Bucket `acm-backups`; signed PUT/GET round-trip returns 200/200 with
  intact content.
- OADP mapping (Phase 2b): `s3Url: https://truenas.skrzypek.dev:30304`,
  bucket `acm-backups`, `s3ForcePathStyle: "true"`. On ROSA the identical
  DPA drops `s3Url`/`s3ForcePathStyle` and uses real S3 + STS.

Two live gotchas the docs won't tell you (details in
[the S3 runbook](docs/runbooks/truenas-seaweedfs-s3/README.md)):

1. **RHCOS `curl` 7.76 `--aws-sigv4` is buggy** — it returns
   `SignatureDoesNotMatch` against a perfectly healthy endpoint
   (canonicalization bugs fixed in later curl). Verify with curl ≥ 8 or an
   SDK; Velero (aws-sdk-go) is unaffected.
2. **SeaweedFS volume-slot exhaustion**: with the default 30GB
   `volumeSizeLimitMB` and ~234G free, only ~7 volume slots exist and the
   default collection pre-claims all of them at first start — the first
   bucket PUT fails 500 "No writable volumes". Lowering the limit to 5GB
   (`app.update`) freed ~46 slots and fixed it.

### 2b. Let's Encrypt serving certs on all three clusters (verified)

Prerequisite hygiene for the failover work (and standard practice on ROSA,
where API/ingress certs are managed for you): every cluster serves publicly
trusted certs on both the apps wildcard and the API, so importing clusters
and wiring Argo needs no custom-CA plumbing.

- cert-manager (Red Hat build, `stable-v1` → v1.20.0) on all three clusters;
  `ClusterIssuer letsencrypt-prod` with Cloudflare DNS-01
  (`manifests/31-letsencrypt-issuer.yaml`; the Cloudflare key lives in
  secret `cloudflare-api-key` in `cert-manager`, never in git).
- Two Certificates per cluster (`manifests/32-cluster-certs.yaml`):
  `*.apps.<c>.k8socp.com` → `openshift-ingress/apps-wildcard-tls` and
  `api.<c>.k8socp.com` → `openshift-config/api-tls`. **A single
  `*.<c>.k8socp.com` wildcard would NOT work** — console lives at
  `console-openshift-console.apps.<c>...`, two labels below it.
- Patches: IngressController `default` `spec.defaultCertificate`, APIServer
  `cluster` `spec.servingCerts.namedCertificates`.
- The whole flow is scripted and was verified end-to-end on sage:
  `scripts/cluster-le-certs.sh <cluster>`.

Observed timings/gotchas, verified live:

1. DNS-01 issuance was fast (~90 s for all four hub+spoke certs). The
   kube-apiserver static-pod rollout after the APIServer patch is the slow
   part on SNO (~5–15 min, brief API blips).
2. **Hub already ran cert-manager** (service-mesh CA hierarchy). Applying a
   second OperatorGroup to `cert-manager-operator` put the CSV into
   `Failed/TooManyOperatorGroups`; deleting the duplicate OG let it
   self-recover to `Succeeded`. Check for an existing install first.
3. After the API serves LE, kubeconfigs that pin the internal CA
   (`certificate-authority-data`) fail TLS. Fix: `oc config unset
   clusters.<name>.certificate-authority-data` — client-cert auth keeps
   working (`system:admin`), server trust moves to the system store.
4. **ACM is untouched by the swap**: the klusterlet's hub kubeconfig points
   at `https://kubernetes.default.svc:443` (internal CA), so `local-cluster`
   stayed Joined/Available on both hubs through the API cert change.
