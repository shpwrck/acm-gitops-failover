# The experimental build

What the exercises ran against — the clusters, versions, storage, and
wiring — so the environment can be roughly approximated as a
prerequisite for recreating them. Why it is built this way is
[design.md](design.md); the operator procedures are the
[runbooks](runbooks/); the measured results are the
[exercise records](exercises/).

## Clusters

| Cluster | Role | Shape | Version |
| --- | --- | --- | --- |
| hub-x | ACM hub | SNO | OCP 4.21 |
| hub-y | ACM hub | SNO | OCP 4.21 |
| spoke | workload cluster | SNO | OCP 4.21 |

- Hub sizing (observed): SNO with 19.5 CPU / 95 Gi allocatable ran the
  full hub at ~11% CPU / 42% memory (~47 pods across
  `multicluster-engine` + `open-cluster-management`).
  `availabilityConfig: Basic` on the MultiClusterHub is [the install
  docs' explicit guidance for single-node
  OpenShift](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index#advanced-config-hub).
- This build's API endpoints serve publicly trusted certs. With
  self-signed certs, include `certificate-authority-data` in the import
  kubeconfig and the CA in the DPA's `objectStorage.caCert`.

## Software and versions

| Component | Version | Where | Notes |
| --- | --- | --- | --- |
| ACM | 2.17.0 | both hubs | [Same version on both hubs is a hard backup/restore requirement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#enabling-backup-operator-clusters) |
| `cluster-backup` MCH component | with ACM | both hubs | Enabled [via the MCH component override](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index#advanced-config-hub); OADP auto-installs in `open-cluster-management-backup` |
| OpenShift GitOps operator | channel `latest` | all three clusters | [Identical operators on both hubs is a restore-hub requirement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prepare-new-hub) |
| SeaweedFS | 4.41 (chart 1.2.32) | NAS, outside the clusters | Apache-2.0 (MinIO and Garage are AGPL — excluded); on ROSA/AWS use real S3 instead |

## Network and storage

- **S3-compatible store, external to every cluster, reachable from both
  hubs** — [the backup operator needs OADP and an S3-compatible
  location](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#backup-restore-architecture),
  and ["active and passive hub clusters are connected to the same
  storage
  location"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#active-passive-config).
  This build: SeaweedFS at `https://truenas.example.com:30304`, bucket
  `acm-backups`, identity `velero`, and in the DPA
  `s3ForcePathStyle: "true"` + `checksumAlgorithm: ""`. On ROSA/AWS the
  identical DPA drops `s3Url`/`s3ForcePathStyle`. Store build details:
  [the S3 runbook](runbooks/truenas-seaweedfs-s3/README.md).
- **A git host reachable from every cluster** (this repository): the
  spoke's local Argo pulls the apps from it, and each hub's local Argo
  reconciles its DR role overlay (`dr/`) from it.
- **The hubs never talk to each other** — their only shared state is
  the bucket.
- **Push delivery needs no extra ingress**: the hub's Argo reaches the
  spoke through ACM's cluster-proxy tunnel.
- Verifying the S3 endpoint by hand needs **curl ≥ 8** (RHCOS's curl
  7.76 `--aws-sigv4` is buggy and returns `SignatureDoesNotMatch`
  against a healthy endpoint); Velero itself is unaffected.

## Wiring — `manifests/` in apply order

Committed filenames keep the original lab names
(`40-import-sage.yaml` imports spoke; `backups/route-crd-{spoke,sage}.yaml`
are the gotcha #3 CRD backups).

| Manifest | Target | Purpose |
| --- | --- | --- |
| `10-acm-operator.yaml` | second hub | ACM operator |
| `20-multiclusterhub.yaml` | second hub | MultiClusterHub (`availabilityConfig: Basic`) |
| `40-import-sage.yaml` | active hub | Import spoke ([auto-import-secret flow](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#importing-clusters-auto-import-secret); secret out-of-band) |
| `50-dpa.yaml` | both hubs | DataProtectionApplication → the S3 store |
| `55-backupschedule.yaml` | ACTIVE hub only | [BackupSchedule](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#using-backup-restore), every 30 min, `useManagedServiceAccount: true` — [effectively mandatory for imported clusters](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-imported-managed-clusters) |
| `56-restore-passive.yaml` | PASSIVE hub only | [Continuous sync restore](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-passive-resources-check-backups) |
| `57-restore-activate.yaml` | staged | The failover action — NOT applied in steady state |
| `60-gitops-operator.yaml` | all three clusters | OpenShift GitOps operator |
| `61-gitops-integration.yaml` | active hub | [GitOpsCluster + Placements](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#gitops-register) ([cluster secrets minted from rotated MSA tokens](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#secret-gitops)) |
| `62-appset-pull.yaml` | active hub | [Pull-model ApplicationSet](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#crd-pull-model) → `apps/hello-failover` |
| `63-appset-push.yaml` | active hub | Push-model ApplicationSet → `apps/hello-failover-push` |
| `dr/bootstrap/` | both hubs | dr-role RBAC + Application (the automated paths — see [dr/](../dr/README.md)) |

## Build-time gotchas

Each cost real time and each is invisible in the docs (numbering is
stable — other documents cite these by number):

1. **A missing `open-cluster-management-global-set` namespace on the
   hub** silently prevents the `managed-serviceaccount`/`cluster-proxy`/
   `work-manager` addons from reaching any cluster — no MSA tokens, so
   GitOpsCluster registration fails AND `useManagedServiceAccount`
   auto-import would fail at failover. Fix: recreate the namespace (MCE
   regenerates the binding/placement instantly). **DR pre-flight
   check:** `oc get managedserviceaccount -A` on the active hub must
   show `auto-import-account` per imported cluster WITH a
   `.status.tokenSecretRef` ([automatic import
   considerations](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#auto-import-considerations)).
2. On an ACM hub, bare `application` resolves to ACM's `app.k8s.io` CRD
   — always query `applications.argoproj.io` or you'll chase phantom
   disappearances.
3. **A stray `routes.route.openshift.io` CRD** (installed on former
   spokes by the old hub's GitOps addon) collides with the real
   aggregated Route API and 503s the cluster's entire `/openapi/v2`,
   wedging Argo's cluster cache (`ComparisonError: failed to load open
   api schema`). Delete the CRD (real Routes live in
   openshift-apiserver and are unaffected; backups in `backups/`).
   Check ALL former gitops-addon spokes.
4. **Route creation forbidden** for the spoke's Argo
   application-controller (`SyncFailed: routes ... is forbidden`) — [the
   pull-model RBAC
   prerequisite](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#prereqs-pull-model).
   Least-privilege fix (chosen): `managedNamespaceMetadata` labels the
   app namespace `argocd.argoproj.io/managed-by=openshift-gitops` and
   the GitOps operator mints namespace-scoped RoleBindings; the docs'
   alternative is a cluster-admin CRB for the controller SA.
5. **Routes are permanently OutOfSync without `ignoreDifferences`** for
   `/spec/host`, `/spec/wildcardPolicy`, `/spec/to/weight` (server-side
   defaults). An explicit host in git is wrong for ApplicationSets (it
   would pin one cluster's apps domain).
