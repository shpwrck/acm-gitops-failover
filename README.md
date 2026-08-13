# ACM & OpenShift GitOps Failover Guide

Verified live against the `k8socp.com` lab (contexts `hub`, `spoke`, `sage`)
on 2026-08-12. Every command in this guide was actually run; outputs and
timings shown are real. Claims from documentation are linked inline to the
official Red Hat docs and blogs — the full annotated bibliography (with
section anchors for every fact) is in [research-notes.md](research-notes.md),
and the primary sources are listed in [Sources](#sources) below.

## Environment

| Cluster | API | OCP | Shape | Role (start) | Role (end) |
| --- | --- | --- | --- | --- | --- |
| hub | api.hub.k8socp.com | 4.21.20 | SNO | ACM 2.17.0 hub (managed `local-cluster` + `spoke`) | **passive** hub |
| spoke | api.spoke.k8socp.com | 4.21.20 | SNO | ACM managed cluster of hub | **active** ACM 2.17.0 hub (manages `sage`) |
| sage | api.sage.k8socp.com | 4.21.20 | SNO | off | workload cluster (pull-model GitOps) |

Facts recorded from the live environment before the change:

- `spoke` was imported into hub 33 days ago; klusterlet in **Singleton** mode
  (`deployOption.mode: Singleton`), `clusterName: spoke`, agent namespaces
  `open-cluster-management-agent`, `-agent-addon`, `open-cluster-management-policies`.
- Enabled addons on spoke: `application-manager`, `cert-policy-controller`,
  `config-policy-controller`, `governance-policy-framework`, `klusterlet-addon-search`.
- Hub pushed 13 replicated policies to spoke (`acm-policy-research.*`,
  `rhcl-ossm-policy.*`).
- OpenShift GitOps was NOT installed anywhere. The `openshift-gitops(-operator)`
  namespaces on spoke existed but were empty shells created by ACM's GitOps addon
  (`apps.open-cluster-management.io/gitopsaddon: "true"` label).
- Spoke's catalog offers ACM channels release-2.15/2.16/2.17; hub ran MCH 2.17.0,
  so release-2.17 was chosen for version parity — a hard requirement for hub
  backup/restore: ["Ensure that the restore hub cluster uses the same ACM
  version that the backup hub cluster uses"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#enabling-backup-operator-clusters).

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

Detaching is [documented as deleting the `ManagedCluster` from the
hub](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#remove-managed-cluster).
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

**Total: ~4.5 minutes** from delete to fully clean on both sides. (If the
hub had been dead, the manual spoke-side cleanup is also documented:
["Removing remaining resources after removing a
cluster"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#removing-a-cluster-from-management-in-special-cases).)

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
the addon, and policy-created objects (here carrying
`pruneObjectBehavior: DeleteIfCreated`) were pruned with their policies. If
a managed cluster's workloads must survive re-homing to a new hub, they must
come from GitOps/Argo (cluster-local reconciliation), not from hub-pushed
addons — this observation drives the Phase 2 design.

### 1.3 Create the MultiClusterHub

Only after 1.2 is fully clean (the `local-cluster` self-import creates a
klusterlet named `klusterlet`, which would collide with the old one):

```console
$ oc --context spoke apply -f manifests/20-multiclusterhub.yaml
multiclusterhub.operator.open-cluster-management.io/multiclusterhub created
```

`availabilityConfig: Basic` because spoke is SNO — [the install docs'
explicit guidance for single-node
OpenShift](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index#advanced-config-hub).

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
(up from 4% / 36%). The old hub is unaffected. ACM 2.17 has no separate
console route — use the OpenShift console's cluster switcher ("All
Clusters" perspective).

**Phase 1 result: two independent, same-version (2.17.0) ACM hubs.**

## Phase 2 — Failover design

The design follows the pattern the public sources converge on — two layers:

- **Hub state: active/passive backup-restore.** This is Red Hat's
  productized hub-DR architecture: one primary, N passive hubs continuously
  restoring from shared S3-compatible storage, deliberate manual failover.
  Documented in the ACM Business Continuity guide (["Configuring
  active-passive hub
  cluster"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#active-passive-config),
  ["Disaster
  recovery"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#disaster-recovery))
  and the [RHACM high availability and disaster recovery blog series
  (part 1)](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-1)
  ([part 2](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-2),
  [part 3](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-3),
  and the [backup-and-restore hub clusters
  blog](https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes)).
  Because this lab's clusters are *imported* (not Hive-created),
  [**ManagedServiceAccount auto-import** is effectively
  mandatory](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-imported-managed-clusters)
  (`useManagedServiceAccount: true`) — [without it every failover ends in
  `Pending Import`](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#auto-connect-clusters-msa).
- **Workloads: git as source of truth, pull-model GitOps.** Even Red Hat's
  [pull-model announcement
  blog](https://www.redhat.com/en/blog/introducing-the-argo-cd-application-pull-controller-for-red-hat-advanced-cluster-management)
  concedes "the hub cluster itself still represents a potential single
  point of failure" — so workloads must not depend on any hub. With the
  [pull-model
  architecture](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#arch-pull),
  each managed cluster's local Argo CD syncs from git independently; hub
  loss stops only propagation of *new* ApplicationSet decisions and status
  aggregation. Argo CD itself [never prunes without explicit
  `prune: true`](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/),
  and [its state is rebuildable from
  git](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/).
- The two layers composed are exactly Red Hat's November 2025 reference:
  [Argo CD Disaster Recovery strategy using RHACM and
  OADP](https://www.redhat.com/en/blog/argo-cd-disaster-recovery-strategy-using-red-hat-advanced-cluster-management-and-oadp).

The Phase 1 observation is the load-bearing argument for the second layer:
anything delivered by hub addons dies with the hub relationship, while
GitOps-delivered state is cluster-local and survives. Hub backup/restore
protects only the hub's *own* state (cluster inventory, policies,
placements, the GitOps wiring itself).

### 2a. S3-compatible backup storage (verified)

The customer runs ROSA and will use real AWS S3. The lab stand-in must be
(a) S3-compatible for the same OADP/Velero `aws` provider config ([the
backup operator depends on OADP and an S3-compatible
location](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#backup-restore-architecture)),
(b) external to every cluster — ["active and passive hub clusters are
connected to the same storage
location"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#active-passive-config),
and it must survive the hub failure we simulate — and (c) license-clean.
**MinIO and Garage are AGPL — excluded.** Chosen: **SeaweedFS**
(Apache-2.0), from the TrueNAS **stable** catalog train (chart 1.2.32,
SeaweedFS 4.41), on the existing NAS that both cluster nodes verifiably
reach.

Result, verified live:

- Endpoint `https://truenas.skrzypek.dev:30304`. (This NAS happens to serve
  a publicly trusted cert; with a self-signed endpoint, put the CA in the
  DPA's `objectStorage.caCert` instead.)
- Identity `velero` via `weed shell s3.configure` (persisted in the filer);
  anonymous requests correctly denied (403 from both cluster nodes).
- Bucket `acm-backups`; signed PUT/GET round-trip returns 200/200 with
  intact content.
- OADP mapping (§2b): `s3Url: https://truenas.skrzypek.dev:30304`, bucket
  `acm-backups`, `s3ForcePathStyle: "true"`. On ROSA the identical DPA
  drops `s3Url`/`s3ForcePathStyle` and uses real S3 + STS.

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

### 2b. Import sage + backup layer + GitOps pull model (verified)

**Import** ([auto-import-secret
flow](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#importing-clusters-auto-import-secret);
`manifests/40-import-sage.yaml` + secret): sage went `Joined/Available` in
**under 15 seconds**; all five addons Available within minutes. (This lab's
API endpoints serve publicly trusted certs, so the import kubeconfig
carried no CA data; include `certificate-authority-data` if yours are
self-signed.)

**Backup layer**: `cluster-backup` enabled [via the MCH component
override](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index#advanced-config-hub)
on both hubs (OADP auto-installs in `open-cluster-management-backup` per
[the enablement
docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#enabling-backup-operator-clusters));
`cloud-credentials` + `manifests/50-dpa.yaml` on both — **both
BackupStorageLocations went `Available` in ~10 s** against SeaweedFS
(`checksumAlgorithm: ""`, first try). Hub ran
`manifests/55-backupschedule.yaml` ([BackupSchedule
docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#using-backup-restore);
every 30 min, `useManagedServiceAccount: true`); the first backup set (5
backups) completed in <1 min, ~187 KB in the bucket. Spoke ran
`manifests/56-restore-passive.yaml` ([passive restore with
sync](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-passive-resources-check-backups))
— the first passive sync restored hub's 11 policies, credentials, and
cluster namespaces onto spoke **without claiming any managed cluster**
(verified). Failover is staged as `manifests/57-restore-activate.yaml`.

**GitOps pull model**: GitOps operator on all three clusters (identical
operators on both hubs is a [restore-hub
requirement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prepare-new-hub));
[`GitOpsCluster` +
Placement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#gitops-register)
on the active hub registers `local-cluster` + `sage` into Argo ([cluster
secrets minted from rotated ManagedServiceAccount
tokens](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#secret-gitops)
— no manual `argocd cluster add`); a [pull-model
ApplicationSet](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#crd-pull-model)
delivers `hello-failover` to sage, whose local Argo syncs it from
`github.com/shpwrck/acm-gitops-failover`. End state verified:
`Synced/Healthy`, route serving `REVISION v1`.

Five live gotchas — each cost real time and each is invisible in the docs:

1. **Hub's `open-cluster-management-global-set` namespace was missing**, so
   the `managed-serviceaccount`/`cluster-proxy`/`work-manager` addons (which
   install via the `global` Placement there) never reached any cluster — no
   MSA tokens existed. This broke GitOpsCluster registration AND would have
   silently broken `useManagedServiceAccount` auto-import at failover
   (backups carried a token-less `auto-import-account`). Fix: recreate the
   namespace — MCE regenerates the binding/placement instantly.
   **DR pre-flight check:** `oc get managedserviceaccount -A` on the active
   hub must show `auto-import-account` per imported cluster WITH a
   `.status.tokenSecretRef` (see [automatic import
   considerations](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#auto-import-considerations)
   — the token must be valid at restore time).
2. On an ACM hub, bare `application` resolves to ACM's `app.k8s.io` CRD —
   always query `applications.argoproj.io` or you'll chase phantom
   disappearances.
3. **A stray `routes.route.openshift.io` CRD** (labeled
   `apps.open-cluster-management.io/gitopsaddon` — installed on spokes by
   the old hub's GitOps addon) collided with the real aggregated Route API
   and 503'd sage's entire `/openapi/v2`, wedging Argo's cluster cache
   (`ComparisonError: failed to load open api schema`). The failure is
   timing-dependent: spoke carried the same CRD undetonated. Fix: delete the
   CRD (real Routes live in openshift-apiserver and are unaffected; backups
   in `backups/`). Check ALL former gitops-addon spokes for this.
4. **Route creation forbidden** for the spoke's Argo application-controller
   (`SyncFailed: routes ... is forbidden`) — [the pull-model RBAC
   prerequisite](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#prereqs-pull-model).
   Least-privilege fix (chosen): `managedNamespaceMetadata` labels the app
   namespace `argocd.argoproj.io/managed-by=openshift-gitops` and the
   GitOps operator mints namespace-scoped RoleBindings; the docs'
   alternative is a cluster-admin CRB for the controller SA.
5. **Routes are permanently OutOfSync without `ignoreDifferences`** for
   `/spec/host`, `/spec/wildcardPolicy`, `/spec/to/weight` (server-side
   defaults). An explicit host in git is wrong for ApplicationSets (it would
   pin one cluster's apps domain).

## Phase 3 — The DR exercise (verified live, 2026-08-12)

Pre-flight (all checks passed; the full checklist is in the
`acm-active-passive-dr` runbook): the load-bearing one is the MSA token —
`oc get managedserviceaccount auto-import-account -n <cluster>` on the
active hub must show `.status.tokenSecretRef`, an unexpired
`.status.expirationTimestamp`, **and `TokenReported: True`** (§3.3 — a
restored-but-frozen secret passes the weaker checks), and a backup must
have COMPLETED after that token existed. Bonus data point: the whole posture had just survived a full
three-cluster cold start with zero intervention (backups resumed, passive
sync resumed, app kept serving).

Timeline (hub = active, spoke = passive, sage = workloads):

| Clock | T+ | Event |
| --- | --- | --- |
| 15:22:32 | 0:00 | hub powered off (API dead) — datacenter loss |
| 15:23:38 | 1:06 | `REVISION v2` committed+pushed to git, no hub alive |
| 15:24:12 | 1:40 | on spoke: passive `Restore` deleted, `57-restore-activate.yaml` applied ([activation restore docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-activation-resources)) |
| 15:24:49 | 2:17 | activation `Finished`; **sage Import/Joined/Available on spoke** (MSA auto-import ≤37 s) |
| 15:25:52 | 3:20 | spoke regenerated the app ManifestWork; **route serving v2** |

- **App availability: 100%** — a 10-second probe never failed once through
  hub death, failover, and re-home. ([Hub loss is benign for managed
  clusters](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#backup-intro):
  "some features stop working, even if all managed clusters still work" —
  observed.)
- **Mid-outage deploys work**: sage's local Argo pulled v2 from git while
  NO hub existed — [the pull model's whole
  point](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#arch-pull),
  observed.
- Proof of re-home: sage's `bootstrap-hub-kubeconfig` now points at
  `https://api.spoke.k8socp.com:6443`; all 8 addons Available on the new
  hub.
- Post-failover step (documented, easy to forget): [create the
  `BackupSchedule` on the NEW
  primary](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#disaster-recovery)
  — failover is deliberately manual, and ACM's `backup-restore-enabled`
  policy exists to nag if you forget. Done at 15:2x.
- ROSA translation: identical procedure; the S3 bucket is real S3, and the
  hubs' `DataProtectionApplication` loses only the `s3Url`/`s3ForcePathStyle`
  lines.

### 3.2 Failback as role swap (verified live)

The role swap was chosen over the [documented return-to-primary
mirror](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-data-initial-hub):
the ex-primary comes back as the NEW passive, leaving the posture symmetric
and the exercise repeatable in the opposite direction.

| Clock | Event |
| --- | --- |
| 15:31:54 | hub API back; its view of sage still STALE (`True/True`) |
| ~15:34 | sage lease expired on hub → `Available=Unknown` |
| ≤15:36 | **`BackupCollision` fired on hub's old BackupSchedule** — it saw spoke's newer backup in the shared bucket, from a different cluster id, and froze itself ([the documented collision guard](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prevent-backup-collision)) |
| 15:36:24 | defuse: old `BackupSchedule` deleted; stale `ManagedCluster sage` deleted — [safe ONLY in `Unknown`: "If the status is not Unknown, your workloads are uninstalled from the managed cluster"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#keep-hub-active-restore-clean) |
| 15:36:57 | hub-side cleanup complete — **15 s, zero stuck finalizers** |
| 15:38:45 | passive `Restore` applied and `Enabled` — hub is the new passive |

~7 minutes from hub power-on to symmetric posture; sage and its app were
untouched throughout (availability probe: still zero failures across
failover AND failback). Probe footnote: the raw probe log (15:22–16:08)
shows failures beginning at 15:46:20 — that is the lab being powered off
for the day, 7+ minutes after failback completed, not a DR event; every
probe during the exercise window succeeded.

Caveats verified/noted:

- Wait out the lease: the returning hub shows moved clusters as `True` for
  the first ~2–4 minutes. Do NOT delete the ManagedCluster until it reads
  `Unknown`.
- Velero skips pre-existing same-name resources on restore, which is why
  [the docs prefer a CLEAN passive
  hub](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prepare-new-hub).
  Harmless here: the ex-primary's leftover GitOps wiring is byte-identical
  to the backup content (both from the same git commits). On a real re-used
  hub, audit leftovers first.
- End state: spoke ACTIVE (sage + backups), hub PASSIVE (continuous
  restore), git the only workload source of truth. Re-running the exercise
  in the reverse direction is the same §3 procedure with the roles renamed.

### 3.3 Post-activation hygiene: the restored MSA token secret (found 2026-08-13)

Pre-flighting the reverse exercise the next morning surfaced a silent
failure the 2026-08-12 activation had left behind on the new active hub
(spoke): the `auto-import-account` ManagedServiceAccount for sage reported

```
TokenReported: False — failed to update the token secret: secrets
"auto-import-account" is forbidden: cannot set an ownerRef on a resource
you can't delete
```

with `.status.tokenSecretRef` empty — token rotation had been frozen since
the activation itself (condition timestamp 2026-08-12T19:25:28Z, within a
minute of the activation restore finishing).

Mechanics: the activation restore brings the hub-side token secret back as
a plain Velero object — correct token, but no `ownerReferences` (its
`velero.io/backup-name`/`velero.io/restore-name` labels give it away).
When the `managed-serviceaccount` addon then starts against the new hub
and tries to adopt the secret so it can rotate it, [Kubernetes' ownership
admission
control](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#ownerreferencespermissionenforcement)
rejects the ownerReference update. The addon itself stays `Available`;
only rotation dies. Nothing pages: the restored token keeps working until
its 144h validity expires (here 2026-08-18T15:40Z — it had been minted by
the old hub hours before it died), and only the NEXT failover fails — in
`Pending Import`, days later, with the original cause long out of the
logs.

The timing rule, now a standard runbook step:

- **During activation the restored secret is load-bearing.** It is the
  credential auto-import uses to reach the managed cluster. Never delete
  it before the cluster shows `Joined/Available`.
- **After activation it is disposable.** Once the cluster is imported and
  `managed-serviceaccount` is `Available`, delete the restored copy; the
  addon re-mints it within seconds under its own ownership, unfreezing
  rotation. Verified live (fix at 14:10:47Z):

  ```console
  $ oc --context spoke delete secret auto-import-account -n sage
  $ oc --context spoke get managedserviceaccount auto-import-account -n sage \
      -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status}{" | "}{.status.expirationTimestamp}{"\n"}'
  True | 2026-08-19T14:10:47Z
  $ oc --context spoke get secret auto-import-account -n sage \
      -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
  ManagedServiceAccount        # controller-owned again (restored copy had none)
  ```

- **The fix is not DR-protected until the next credentials backup
  completes.** Observed live: fix at 14:10:47Z, newest credentials backup
  14:00:23Z — the bucket kept serving the frozen token as `latest` until
  the 14:30Z set landed. Any hub-state repair inherits the backup cadence
  (here 30 min) as its protection lag — the same number that anchors the
  customer RPO conversation.
- **On the passive hub the same restored secrets are harmless** — the sync
  restore keeps overwriting them and nothing there tries to adopt them.
  This cleanup applies only to a hub that just *activated*.

The §3 pre-flight is upgraded accordingly: check the `TokenReported`
condition, not just `tokenSecretRef`/expiry — a restored-but-frozen secret
can pass the weaker checks while rotation is already dead:

```console
$ oc --context <active-hub> get managedserviceaccount -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TOKEN-REPORTED:.status.conditions[?(@.type=="TokenReported")].status,EXPIRES:.status.expirationTimestamp'
```

### 3.4 The reverse exercise (verified live, 2026-08-13)

The whole §3 procedure run in the opposite direction the next day — spoke
(active since §3) killed, hub activated, role-swap failback — driven
end-to-end from the
[`dr-failover-exercise` runbook](docs/runbooks/dr-failover-exercise/README.md),
which this run validated step by step. Two deliberate differences from §3:
pre-flight found and fixed the frozen MSA rotation first (§3.3 — fix
14:10:47Z, protecting credentials backup `Completed` 14:30:21Z), and the
disaster was a clean host shutdown through the API
(`oc --context spoke debug node/spoke -- chroot /host shutdown -h 1`) —
gentler on SNO etcd than a power cut; the variant belongs in the exercise
record because a customer will ask.

| Clock (UTC) | T+ | Event |
| --- | --- | --- |
| 14:34:12 | 0:00 | spoke halted (scheduled shutdown fired; API dead within the minute) |
| ~14:35:30 | ~1:20 | `REVISION v3` committed+pushed to git, no active hub alive |
| ~14:39 | ~5:00 | sage serving v3 (its local Argo's normal poll; hub still passive) |
| 14:42:09 | 7:57 | on hub: passive restore deleted, activation restore created |
| 14:42:19 | 8:07 | **sage re-homed** — bootstrap pointer flip observed (10 s probe granularity) |
| ≤14:43 | ~9:00 | sage `Joined/Available` on hub; all 8 addons `Available` |
| 14:45:44 | — | §3.3 reproduced on hub: `TokenReported: False` → restored secret deleted → re-minted `True` |
| 14:46:38 | — | `BackupSchedule` applied on hub; first full set fired immediately, `Completed` in seconds |
| +~15 min | — | spoke powered on: sage already `Unknown` (lease long expired), `BackupCollision` fired (hub id `4331cb00…` vs spoke id `88d1a668…`), stale schedule + `ManagedCluster` + activation restore deleted, passive restore `Enabled` |

- **Availability: 0 non-200 responses across the entire window**
  (`grep -cv ' 200$'` over the 10 s probe log = 0) — zero downtime in this
  direction too, through kill, mid-outage deploy, activation, and
  failback.
- **Decision-to-re-home ≈10 s** (activation restore 14:42:09 → pointer
  flip 14:42:19). The 8-minute T+ total is dominated by the deliberate
  mid-outage-deploy demonstration, not by the machinery.
- New findings, all folded into the exercise runbook:
  - **§3.3 is systematic, not a one-off**: the freshly-activated hub
    reproduced the frozen `TokenReported` exactly as predicted, and the
    same fix worked — post-activation secret cleanup is a permanent step.
  - A new `BackupSchedule` fires its first full backup set immediately on
    creation (no wait for the cron slot), so the new active hub's
    repair-to-protection lag at failover is under a minute.
  - The backup operator stamps an `acm-restore-clusters-<ts>` safety
    backup at activation time — expected artifact, not an anomaly.
  - **A demoted hub keeps its `Finished` `restore-acm-activate` — delete
    it during demotion.** Left in place, the NEXT activation's `oc apply`
    of the same manifest is a silent no-op (identical spec, nothing
    re-triggers): a "successful" apply and no failover, at the worst
    possible moment.
  - A hub that was down longer than the lease window wakes with its moved
    clusters already `Unknown` — the 2–4 minute wait applies only to short
    outages.
- End state: **hub ACTIVE, spoke PASSIVE, sage untouched — the original
  posture, restored by exercising the DR machinery in both directions on
  consecutive days.**

## 4. The four paths

The repo carries the full 2×2 of delivery model × DR operation, so the
choice can be made on evidence rather than doctrine:

| Path | Delivery | Operation | Runbook | Status |
| --- | --- | --- | --- | --- |
| 1 | Pull | Manual | [dr-failover-exercise](docs/runbooks/dr-failover-exercise/README.md) | **VERIFIED** both directions (§3, §3.4): ≈10 s re-home, zero downtime, deploys land mid-outage |
| 2 | Pull | Git-driven (PR) | [dr-failover-gitops](docs/runbooks/dr-failover-gitops/README.md) | Authored, UNVERIFIED (open items: [dr/README.md](dr/README.md) V1–V5) |
| 3 | Push | Manual | [dr-failover-push-manual](docs/runbooks/dr-failover-push-manual/README.md) | Authored, UNVERIFIED (key unknown: push RBAC — discovered, not guessed, in its P.2) |
| 4 | Push | Git-driven (PR) | [dr-failover-push-gitops](docs/runbooks/dr-failover-push-gitops/README.md) | Authored, UNVERIFIED (composition of 2+3; run last) |

How the halves differ, in one line each:

- **Pull vs push** is *what a hub outage costs delivery*: nothing (sage
  syncs git itself — proven, v2 and v3 both landed hubless) vs a
  delivery outage lasting until the new hub's Argo resumes pushing
  (path 3 measures it).
- **Manual vs git-driven** is *what a failover decision looks like*: an
  operator with a runbook (≈10 s of machinery after seconds of typing)
  vs a pull request whose review is the split-brain gate and whose merge
  history is the audit log (expected cost: + merge + Argo poll; measured
  by path 2's V4).

Why there is no fifth, fully-autonomous path: hub failover is
deliberately a human decision. A passive-side monitor cannot distinguish
"active hub died" from "network partition," and with MSA auto-import an
activation actively re-points the fleet's klusterlets — automating a
false positive moves the fleet onto a second live hub. `BackupCollision`
guards the bucket, not cluster claims; going autonomous safely requires a
quorum witness/fencing, and the architecture has already made hub
downtime cheap (workloads run and — on pull — deploy hubless). Automate
the detection, the pre-flight, and the execution; keep the decision
human. Path 2/4's PR gate is exactly that boundary drawn in git.

Delivery infrastructure shared by paths 3/4:
[manifests/63-appset-push.yaml](manifests/63-appset-push.yaml) +
[apps/hello-failover-push/](apps/hello-failover-push/) (separate
namespace — both models coexist through one outage). Role-flip
infrastructure for paths 2/4: [dr/](dr/README.md).

## Sources

Primary documentation (ACM 2.17; every claim above links to its exact
section — the annotated fact-by-fact bibliography with anchors is in
[research-notes.md](research-notes.md)):

- [Business continuity (backup/restore, active-passive, disaster recovery)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index)
- [Clusters (import, detach, cleanup procedures)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index)
- [GitOps (GitOpsCluster, push/pull models, gitops addon)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index)
- [Install (MultiClusterHub advanced configuration, sizing)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index)
- [Argo CD: automated sync/prune/self-heal](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/), [cluster bootstrapping (app-of-apps)](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/), [declarative cluster secrets](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters), [disaster recovery](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/)

Red Hat blogs (architecture endorsements):

- [RHACM: High availability and disaster recovery — part 1](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-1), [part 2](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-2), [part 3](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-3)
- [Backup and Restore Hub Clusters with RHACM](https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes)
- [Argo CD Disaster Recovery strategy using RHACM and OADP](https://www.redhat.com/en/blog/argo-cd-disaster-recovery-strategy-using-red-hat-advanced-cluster-management-and-oadp) — the composed two-layer architecture this guide implements
- [Introducing the Argo CD Application Pull Controller for RHACM](https://www.redhat.com/en/blog/introducing-the-argo-cd-application-pull-controller-for-red-hat-advanced-cluster-management)
- [Using the Argo CD Agent with OpenShift GitOps](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops) — the Tech Preview evolution of the pull model
- [stolostron/cluster-backup-operator](https://github.com/stolostron/cluster-backup-operator)
