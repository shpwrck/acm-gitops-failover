---
leave-behind: v1
state-scope: acm-active-passive-dr
status: current
---

# ACM active/passive DR posture leave-behind

## Operability

### State and access

Durable state spans the three k8socp.com clusters (contexts `hub`, `spoke`,
`sage` in `~/.kube/config`, client-cert auth; kubeconfig cluster entries
carry no CA pins because the lab's API endpoints serve publicly trusted
certs — that cert setup is separate from this DR solution, tracked in the
local `~/k8socp-le-certs` repo)
and the SeaweedFS S3 store on TrueNAS (see the `truenas-seaweedfs-s3`
runbook; S3 keys in `~/.acm-failover-s3-creds`, chmod 600).

- **spoke = ACTIVE ACM 2.17 hub** (since the 2026-08-13 path-2 git-driven
  exercise, README §3.5 — activated by PR-A 18:02Z, claim 18:08:09Z):
  manages `local-cluster` + `sage` (all 8 addons Available);
  `BackupSchedule schedule-acm` delivered by promotion PR-B (git:
  `dr/spoke → ../roles/active` + activation one-shot
  `restore-activate-202608131800.yaml`, reconciled by spoke's own Argo);
  GitOps wiring restored from backup (`GitOpsCluster`, Placements,
  ApplicationSets `hello-failover` + `hello-failover-push`);
  post-activation MSA secret cleanup done (token re-minted 18:14:22Z —
  protected once the next credentials set completes).
- **hub = PASSIVE hub** (demoted via PR #5 merged while hub was down;
  on boot its Argo pruned the stale BackupSchedule before it fired — V3
  benign; git: `dr/hub → ../roles/passive`): `Restore
  restore-acm-passive-sync` `Enabled` (managedClusters `skip`,
  credentials/resources `latest`, `syncRestoreWithNewBackups: true`);
  stale `ManagedCluster sage` deleted in `Unknown` (G.3), stale manual
  `restore-acm-activate` deleted (G.5) — exactly one restore remains;
  claims NO managed cluster while passive.
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
~/acm-failover-guide/manifests/63-appset-push.yaml -> hub ApplicationSet hello-failover-push (push model; APPLIED+VERIFIED 2026-08-13)
~/acm-failover-guide/apps/hello-failover/ -> sage ns hello-failover (Deployment/ConfigMap/Service/Route via sage-local Argo)
~/acm-failover-guide/apps/hello-failover-push/ -> sage ns hello-failover-push (pushed by HUB's Argo via cluster-proxy; APPLIED+VERIFIED 2026-08-13)
~/acm-failover-guide/dr/bootstrap/ -> BOTH hubs: Role/RoleBinding dr-role-backup-operator + Application dr-role in openshift-gitops (velero-excluded; APPLIED+VERIFIED 2026-08-13)
~/acm-failover-guide/dr/{hub,spoke}/ -> per-hub git-driven DR role overlays (hub->active, spoke->passive), reconciled by each hub's LOCAL Argo

### Re-run

All applies are idempotent (`oc --context <c> apply -f <file>`). Rebuild
order on a fresh pair: import clusters (40), enable `cluster-backup` MCH
component on both, secret + DPA (50) on both, BackupSchedule (55) on ACTIVE
only (currently hub), passive Restore (56) on PASSIVE only (currently
spoke), GitOps operator (60) on all
three, integration (61) + AppSet (62) on ACTIVE. Prerequisite checks that
MUST pass first (each broke once, live):

```bash
oc --context <hub> get ns open-cluster-management-global-set   # must exist (addon rollout)
oc --context <hub> get managedserviceaccount -A                # auto-import-account per imported cluster
oc --context <spoke-cluster> get crd routes.route.openshift.io # must NOT exist (gitopsaddon relic)
```

### Verify and recover

```bash
oc --context hub get backupschedule,backup -n open-cluster-management-backup   # ACTIVE: schedule Enabled, backups Completed
oc --context spoke get restore -n open-cluster-management-backup               # PASSIVE: phase Enabled (sync mode), passive-sync ONLY
oc --context spoke get managedclusters                                         # local-cluster ONLY while passive
oc --context sage get applications.argoproj.io -A                              # hello-failover-sage Synced/Healthy
curl -s https://hello-failover-hello-failover.apps.sage.k8socp.com | grep REVISION
oc --context hub get managedserviceaccount auto-import-account -n sage \
  -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status}{"\n"}'  # ACTIVE: True (rotation live — README §3.3)
```

Failure paths: GitOpsCluster `ClusterRegistrationFailed` → check the MSA
token chain (global-set ns, addons, tokenSecretRef). Argo
`ComparisonError ... openapi` → duplicate Route CRD (delete it; backups in
`backups/`). `SyncFailed routes forbidden` → managed-by label missing on the
app namespace. App `OutOfSync` on Route only → ignoreDifferences (already in
the AppSet). BackupCollision on the schedule → both hubs wrote the same
location; pause one. MSA `TokenReported: False` with `cannot set an
ownerRef` → Velero-restored token secret from a past activation was never
cleaned up; rotation is frozen with a hard deadline at token expiry —
delete the secret (only on an already-imported cluster), the addon
re-mints it in seconds (README §3.3; found+fixed live 2026-08-13,
reproduced on hub post-activation the same day). Applying
`57-restore-activate.yaml` produces no activation → a `Finished`
`restore-acm-activate` from a previous activation still exists with an
identical spec, so the apply is a silent no-op — delete it first (now
exercise-runbook step G.5, done at demotion time). `oc`
to every lab API failing `x509: unknown authority` while `curl` succeeds
→ stale internal-CA pins re-appeared in `~/.kube/config` (these APIs
serve publicly trusted certs; entries must carry NO
`certificate-authority-data`) — back up the kubeconfig, then
`kubectl config unset clusters.<name>.certificate-authority-data` per
cluster (hit 2026-08-13 after the lab cold start). First backup after a
cluster cold start fires off-cadence (catch-up), then the cron reasserts —
off-slot timestamps right after power-on are normal, not a stall.
Recovery of the whole posture = re-run from git (this
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
change. Watch the posture with the Verify block. The DR exercise ran 2026-08-12
(README.md §3: failover 3m20s, zero downtime, v2 deployed mid-outage;
§3.2: role-swap failback ~7 min, BackupCollision observed live). The
REVERSE exercise ran 2026-08-13 (README.md §3.4: decision-to-re-home
≈10 s, zero downtime again, v3 deployed mid-outage, §3.3 reproduced on
hub, BackupCollision fired in the opposite direction) — restoring the
ORIGINAL hub-active/spoke-passive posture and validating the exercise
runbook end to end. The posture is symmetric: each exercise is the same
procedure with the roles renamed.
The full step-by-step exercise script — command / rationale / success /
failure per step, parameterized for either direction — is the
[`dr-failover-exercise`](../dr-failover-exercise/README.md) runbook.
After ANY activation, run its Phase E.3 (delete the restored
`auto-import-account` secret once the cluster is imported) — skipping it
is what silently froze token rotation after the 2026-08-12 exercise.
2026-08-13 (later): the repo carries FOUR paths (README §4 — delivery
pull/push × operation manual/gitops). Path 1 fully verified; paths 2/3
WIRING verified and LIVE on the clusters (dr-role apps + RBAC on both
hubs, push app serving on sage via hub's Argo through cluster-proxy) —
their disaster exercises (role-flip PR, delivery-RTO measurement) are the
remaining unverified halves; path 4 composes 2+3 and runs last. The
dr-role Applications carry `velero.io/exclude-from-backup` — verified
absent from backups while delivery resources ride along; never remove
that label (split-brain via restore). New failure paths from the wiring
verification: dr-role sync `Failed` after retry exhaustion needs an
explicit re-sync (`oc patch … '{"operation":{"sync":{}}}'`) — Argo won't
re-try the same revision; and the openshift-gitops controller writes ACM
backup CRs only via `dr/bootstrap/dr-role-rbac.yaml` (the managed-by
label does NOT grant it — verified with `auth can-i`).
