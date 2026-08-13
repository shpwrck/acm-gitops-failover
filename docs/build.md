# The verified build

How the lab reached its steady state: `hub-y` promoted to a second,
same-version ACM hub, an S3-compatible backup store stood up on the
NAS, and the backup layer + pull-model GitOps wired on top. Every
command below was actually run (2026-08-12/13); outputs and timings are
real. The rationale for what gets built is [design.md](design.md); the
re-runnable operator scripts with verify/recover blocks are the
[runbooks](runbooks/). Cluster names are generic (hub-x, hub-y, spoke —
see the README's naming note); outputs are the real recorded outputs
with only the names substituted, and committed filenames
(`manifests/40-import-sage.yaml`, `backups/route-crd-{spoke,sage}.yaml`)
keep the original lab names.

## Starting point

Facts recorded from the live environment before the change:

- `hub-y` was imported into hub-x 33 days ago; klusterlet in **Singleton** mode
  (`deployOption.mode: Singleton`), `clusterName: hub-y`, agent namespaces
  `open-cluster-management-agent`, `-agent-addon`, `open-cluster-management-policies`.
- Enabled addons on hub-y: `application-manager`, `cert-policy-controller`,
  `config-policy-controller`, `governance-policy-framework`, `klusterlet-addon-search`.
- hub-x pushed 13 replicated policies to hub-y (`acm-policy-research.*`,
  `rhcl-ossm-policy.*`).
- OpenShift GitOps was NOT installed anywhere. The `openshift-gitops(-operator)`
  namespaces on hub-y existed but were empty shells created by ACM's GitOps addon
  (`apps.open-cluster-management.io/gitopsaddon: "true"` label).
- hub-y's catalog offers ACM channels release-2.15/2.16/2.17; hub-x ran MCH 2.17.0,
  so release-2.17 was chosen for version parity — a hard requirement for hub
  backup/restore: ["Ensure that the restore hub cluster uses the same ACM
  version that the backup hub cluster uses"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#enabling-backup-operator-clusters).

## Phase 1 — Make `hub-y` a standalone ACM hub

### 1.1 Install the ACM operator (safe while still attached)

Installing the *operator* does not conflict with the klusterlet; only the
`MultiClusterHub` (which self-imports `local-cluster` and would collide with
the existing `klusterlet` CR) must wait until after detach.

```console
$ oc --context hub-y apply -f manifests/10-acm-operator.yaml
namespace/open-cluster-management created
operatorgroup.operators.coreos.com/open-cluster-management created
subscription.operators.coreos.com/advanced-cluster-management created
```

Verified: CSV `advanced-cluster-management.v2.17.0` reached `Succeeded` in
~3 minutes.

### 1.2 Detach hub-y from the old hub

Detaching is [documented as deleting the `ManagedCluster` from the
hub](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#remove-managed-cluster).
Record the hub-side state first (what the detach must clean up):

```console
$ oc --context hub-x get manifestwork -n hub-y
NAME                                         AGE
addon-application-manager-deploy-0           33d
addon-cert-policy-controller-deploy-0        33d
addon-config-policy-controller-deploy-0      33d
addon-governance-policy-framework-deploy-0   33d
addon-search-collector-deploy-0              33d
hub-y-klusterlet                             33d
hub-y-klusterlet-crds                        33d
```

The clean detach is a single delete on the hub; four finalizers do the rest:

```console
$ oc --context hub-x delete managedcluster hub-y --wait=false
managedcluster.cluster.open-cluster-management.io "hub-y" deleted
# finalizers: resource-cleanup, managedcluster-import-controller cleanup,
#             api-resource-cleanup, manifestwork-cleanup
```

Observed sequence and timing (live, 2026-08-12):

1. `ManagedClusterImportSucceeded` flips to `False/ManagedClusterDetaching`;
   addon ManifestWorks are deleted one by one (~4 min for 5 addons).
2. `hub-y-klusterlet` + `hub-y-klusterlet-crds` ManifestWorks are deleted;
   the work agent uninstalls the klusterlet and all agent namespaces on
   hub-y (~30 s).
3. Hub-side namespace `hub-y` and the `ManagedCluster` object disappear.

**Total: ~4.5 minutes** from delete to fully clean on both sides. (If the
hub had been dead, the manual hub-y-side cleanup is also documented:
["Removing remaining resources after removing a
cluster"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#removing-a-cluster-from-management-in-special-cases).)

Verify on hub-y (all should come back empty / NotFound):

```console
$ oc --context hub-y get klusterlet
$ oc --context hub-y get ns | grep open-cluster-management
$ oc --context hub-y get crd | grep open-cluster-management
appliedmanifestworks.work.open-cluster-management.io   # harmless leftovers,
clusterclaims.cluster.open-cluster-management.io       # reused by the new hub
```

**Surprise verified live — detach pruned the policy-managed workloads.**
The entire `acm-policy-demo` namespace on hub-y (policy-created ConfigMap,
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
$ oc --context hub-y apply -f manifests/20-multiclusterhub.yaml
multiclusterhub.operator.open-cluster-management.io/multiclusterhub created
```

`availabilityConfig: Basic` because hub-y is SNO — [the install docs'
explicit guidance for single-node
OpenShift](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index#advanced-config-hub).

### 1.4 Verify hub-y is a self-managing hub

Observed install timeline on SNO (19.5 CPU / 95Gi allocatable): MCE CR
appeared ~6 min after MCH creation; `local-cluster` self-import
Joined/Available at ~7 min; **MCH `Running` at 10m20s**.

```console
$ oc --context hub-y get mch -n open-cluster-management
NAME              STATUS    AGE   CURRENTVERSION   DESIREDVERSION   MESSAGE
multiclusterhub   Running   10m   2.17.0           2.17.0           All hub components ready.

$ oc --context hub-y get managedclusters
NAME            HUB ACCEPTED   MANAGED CLUSTER URLS                JOINED   AVAILABLE   AGE
local-cluster   true           https://api.hub-y.k8socp.com:6443   True     True        3m44s

$ oc --context hub-y get klusterlet          # new self-managed klusterlet
NAME         AGE
klusterlet   4m20s
```

Post-install footprint: 24 pods in `multicluster-engine`, 23 in
`open-cluster-management`, zero not-Running; node at 11% CPU / 42% memory
(up from 4% / 36%). The old hub is unaffected. ACM 2.17 has no separate
console route — use the OpenShift console's cluster switcher ("All
Clusters" perspective).

**Phase 1 result: two independent, same-version (2.17.0) ACM hubs.**

## Phase 2a — S3-compatible backup storage (verified)

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
[the S3 runbook](runbooks/truenas-seaweedfs-s3/README.md)):

1. **RHCOS `curl` 7.76 `--aws-sigv4` is buggy** — it returns
   `SignatureDoesNotMatch` against a perfectly healthy endpoint
   (canonicalization bugs fixed in later curl). Verify with curl ≥ 8 or an
   SDK; Velero (aws-sdk-go) is unaffected.
2. **SeaweedFS volume-slot exhaustion**: with the default 30GB
   `volumeSizeLimitMB` and ~234G free, only ~7 volume slots exist and the
   default collection pre-claims all of them at first start — the first
   bucket PUT fails 500 "No writable volumes". Lowering the limit to 5GB
   (`app.update`) freed ~46 slots and fixed it.

## Phase 2b — Import spoke + backup layer + GitOps pull model (verified)

**Import** ([auto-import-secret
flow](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#importing-clusters-auto-import-secret);
`manifests/40-import-sage.yaml` + secret): spoke went `Joined/Available` in
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
(`checksumAlgorithm: ""`, first try). hub-x ran
`manifests/55-backupschedule.yaml` ([BackupSchedule
docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#using-backup-restore);
every 30 min, `useManagedServiceAccount: true`); the first backup set (5
backups) completed in <1 min, ~187 KB in the bucket. hub-y ran
`manifests/56-restore-passive.yaml` ([passive restore with
sync](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-passive-resources-check-backups))
— the first passive sync restored hub-x's 11 policies, credentials, and
cluster namespaces onto hub-y **without claiming any managed cluster**
(verified). Failover is staged as `manifests/57-restore-activate.yaml`.

**GitOps pull model**: GitOps operator on all three clusters (identical
operators on both hubs is a [restore-hub
requirement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prepare-new-hub));
[`GitOpsCluster` +
Placement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#gitops-register)
on the active hub registers `local-cluster` + `spoke` into Argo ([cluster
secrets minted from rotated ManagedServiceAccount
tokens](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#secret-gitops)
— no manual `argocd cluster add`); a [pull-model
ApplicationSet](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#crd-pull-model)
delivers `hello-failover` to spoke, whose local Argo syncs it from
`github.com/shpwrck/acm-gitops-failover`. End state verified:
`Synced/Healthy`, route serving `REVISION v1`.

Five live gotchas — each cost real time and each is invisible in the docs:

1. **hub-x's `open-cluster-management-global-set` namespace was missing**, so
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
   and 503'd spoke's entire `/openapi/v2`, wedging Argo's cluster cache
   (`ComparisonError: failed to load open api schema`). The failure is
   timing-dependent: hub-y carried the same CRD undetonated. Fix: delete the
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
