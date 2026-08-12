---
leave-behind: v1
state-scope: acm-active-passive-dr
status: current
---

# ACM active/passive DR posture leave-behind

## Operability

### State and access

Durable state spans the three k8socp.com clusters (contexts `hub`, `spoke`,
`sage` in `~/.kube/config`, client-cert auth; API CAs unpinned — LE-trusted)
and the SeaweedFS S3 store on TrueNAS (see the `truenas-seaweedfs-s3`
runbook; S3 keys in `~/.acm-failover-s3-creds`, chmod 600).

- **hub = ACTIVE ACM 2.17 hub**: manages `local-cluster` + `sage`
  (imported, all addons Available); `BackupSchedule schedule-acm`
  (`*/30 * * * *`, `veleroTtl 72h`, `useManagedServiceAccount: true`) in
  `open-cluster-management-backup`; GitOps wiring in `openshift-gitops`
  (`GitOpsCluster gitops-cluster`, Placements `gitops-clusters` +
  `hello-failover-placement`, ConfigMap `acm-placement`, ApplicationSet
  `hello-failover`).
- **spoke = PASSIVE hub**: `Restore restore-acm-passive-sync`
  (managedClusters `skip`, credentials/resources `latest`,
  `syncRestoreWithNewBackups: true`, interval 10m) — carries hub's policies,
  credentials, cluster namespaces; claims NO managed cluster while passive.
- **sage = workload cluster**: runs OpenShift GitOps (operator, like both
  hubs, channel `latest`); pull-model Application `hello-failover-sage`
  synced by its LOCAL Argo from
  `https://github.com/shpwrck/acm-gitops-failover` (`apps/hello-failover`,
  branch main); app namespace `hello-failover` labeled
  `argocd.argoproj.io/managed-by=openshift-gitops` (operator-minted
  namespace-scoped RBAC). Route:
  `https://hello-failover-hello-failover.apps.sage.k8socp.com`.
- Both hubs: `cluster-backup` MCH component enabled, OADP in
  `open-cluster-management-backup`, secret `cloud-credentials`, DPA
  `acm-dpa` → `https://truenas.skrzypek.dev:30304`, bucket `acm-backups`,
  prefix `acm`, `checksumAlgorithm: ""`.
- Git repo `github.com/shpwrck/acm-gitops-failover` (= local
  `~/acm-failover-guide`, remote `origin`) holds ALL manifests
  (`manifests/`, numbered in apply order), the demo app (`apps/`), scripts,
  the verified guide (`README.md`), and these runbooks. NO secret values in
  git (verified by scan before first push).

### Template map

~/acm-failover-guide/manifests/40-import-sage.yaml -> hub ManagedCluster sage + KlusterletAddonConfig (auto-import secret out-of-band)
~/acm-failover-guide/manifests/50-dpa.yaml -> DPA acm-dpa on BOTH hubs (ns open-cluster-management-backup)
~/acm-failover-guide/manifests/55-backupschedule.yaml -> hub BackupSchedule schedule-acm (ACTIVE hub only)
~/acm-failover-guide/manifests/56-restore-passive.yaml -> spoke Restore restore-acm-passive-sync (PASSIVE posture)
~/acm-failover-guide/manifests/57-restore-activate.yaml -> spoke Restore restore-acm-activate (FAILOVER action; not applied)
~/acm-failover-guide/manifests/61-gitops-integration.yaml -> hub GitOpsCluster + Placements + acm-placement ConfigMap
~/acm-failover-guide/manifests/62-appset-pull.yaml -> hub ApplicationSet hello-failover (pull model)
~/acm-failover-guide/apps/hello-failover/ -> sage ns hello-failover (Deployment/ConfigMap/Service/Route via sage-local Argo)

### Re-run

All applies are idempotent (`oc --context <c> apply -f <file>`). Rebuild
order on a fresh pair: import clusters (40), enable `cluster-backup` MCH
component on both, secret + DPA (50) on both, BackupSchedule (55) on ACTIVE
only, passive Restore (56) on PASSIVE only, GitOps operator (60) on all
three, integration (61) + AppSet (62) on ACTIVE. Prerequisite checks that
MUST pass first (each broke once, live):

```bash
oc --context <hub> get ns open-cluster-management-global-set   # must exist (addon rollout)
oc --context <hub> get managedserviceaccount -A                # auto-import-account per imported cluster
oc --context <spoke-cluster> get crd routes.route.openshift.io # must NOT exist (gitopsaddon relic)
```

### Verify and recover

```bash
oc --context hub get backupschedule,backup -n open-cluster-management-backup   # schedule Enabled, backups Completed
oc --context spoke get restore -n open-cluster-management-backup               # phase Enabled (sync mode)
oc --context spoke get managedclusters                                         # local-cluster ONLY while passive
oc --context sage get applications.argoproj.io -A                              # hello-failover-sage Synced/Healthy
curl -s https://hello-failover-hello-failover.apps.sage.k8socp.com | grep REVISION
```

Failure paths: GitOpsCluster `ClusterRegistrationFailed` → check the MSA
token chain (global-set ns, addons, tokenSecretRef). Argo
`ComparisonError ... openapi` → duplicate Route CRD (delete it; backups in
`backups/`). `SyncFailed routes forbidden` → managed-by label missing on the
app namespace. App `OutOfSync` on Route only → ignoreDifferences (already in
the AppSet). BackupCollision on the schedule → both hubs wrote the same
location; pause one. Recovery of the whole posture = re-run from git (this
repo is the source of truth; only secrets are out-of-band).

## Decision log

### Decisions

- Active/passive hub DR (documented ACM pattern) + git-as-source-of-truth
  pull-model GitOps for workloads: hub state fails over via
  backup/restore; workloads never depend on a live hub. Chosen over pure
  active/active (no public reference architecture) and over push model
  (dies with the hub).
- `useManagedServiceAccount: true` is load-bearing: all clusters here are
  IMPORTED, and without MSA tokens an activation restore ends in
  `Pending Import`. The token chain was silently broken (missing global-set
  ns on hub) and was only caught because GitOpsCluster uses the same chain —
  promoted to a DR pre-flight check.
- Namespace-scoped Argo RBAC via `managedNamespaceMetadata` managed-by
  label (user choice over the docs' cluster-admin CRB).
- Route `ignoreDifferences` in the AppSet template rather than pinning
  `spec.host` in git (ApplicationSet targets multiple clusters).
- Stray gitopsaddon Route CRDs deleted from sage AND spoke with user
  approval (spoke's was undetonated; a failover-time detonation on the
  passive hub was the risk being removed). Hub never had it.
- Backup cadence 30 min / TTL 72h: lab-friendly iteration speed; RPO for a
  real customer is a business decision (note in guide).

### How to drive it

Change workloads by committing to `apps/` in the git repo — sage syncs
within ~3 min (or annotate the Application `argocd.argoproj.io/refresh`).
Change DR wiring by editing `manifests/` + `oc apply` to the right cluster
(active vs passive matters for 55/56/57), then commit+push in the same
change. Watch the posture with the Verify block. The NEXT planned change is
the failover exercise itself: shut hub down, delete the passive Restore,
apply 57 on spoke, verify sage re-homes (MSA auto-import) and the app keeps
serving/syncing throughout; then fail back per the docs' return-to-primary
procedure. Record timings and any new gotcha in `README.md` §3 and update
this runbook's roles afterward (spoke becomes active).
