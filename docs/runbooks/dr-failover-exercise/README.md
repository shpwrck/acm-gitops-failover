# DR failover exercise runbook — command / rationale / success / failure

Operator-facing script for the full active/passive hub failover exercise:
pre-flight, disaster, activation, verification, new-primary duties, and
failback-as-role-swap. Every step gives the command, why it exists, what
success looks like, and the failure modes with recovery. The *posture*
this exercises (what is deployed where and why) lives in
[`acm-active-passive-dr`](../acm-active-passive-dr/README.md); the
verified narrative with timings is the repo
[README](../../../README.md) §3.

## Conventions

The posture is symmetric — set these once and every command below works in
either direction (values shown are the 2026-08-13 exercise):

```bash
export ACTIVE=spoke      # hub about to "die"
export PASSIVE=hub       # hub that will activate
export MANAGED=sage      # workload cluster that re-homes
export APP_URL=https://hello-failover-hello-failover.apps.sage.k8socp.com
```

- All timestamps UTC (`date -u`) so probe logs and cluster conditions
  correlate.
- Never skip a **Gate** line — each phase's gate is the condition that
  makes the next phase safe.
- Evidence artifacts: `~/probe-<date>.log` (availability),
  `~/hub-pointer-<date>.log` (re-home), plus pasted command outputs.

## Phase 0 — Pre-flight (read-only except the repair)

### 0.1 Posture sanity

```bash
oc --context $ACTIVE  get backupschedule,backup -n open-cluster-management-backup | head
oc --context $ACTIVE  get managedclusters
oc --context $PASSIVE get restore -n open-cluster-management-backup
oc --context $PASSIVE get managedclusters
```

**Why:** Confirms the roles are what you think they are before you kill
anything. The activation procedure assumes exactly one active hub (schedule
`Enabled`, owns `$MANAGED`) and one passive hub (restore `Enabled` in sync
mode, owns only `local-cluster`).
**Success:** Active: `schedule-acm Enabled`, recent backups `Completed`,
`local-cluster` + `$MANAGED` both `True/True`. Passive:
`restore-acm-passive-sync Enabled`, `local-cluster` only.
**Failure:** Passive lists `$MANAGED` → you have two hubs claiming one
cluster (split-brain posture); stop and resolve before any exercise.
Restore not `Enabled` → passive sync is dead; fix before proceeding (a
failover with a stale passive restores stale state).

### 0.2 MSA token chain — the load-bearing check

```bash
oc --context $ACTIVE get managedserviceaccount -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TOKEN-REPORTED:.status.conditions[?(@.type=="TokenReported")].status,EXPIRES:.status.expirationTimestamp'
```

**Why:** With imported clusters, activation reaches `$MANAGED` using the
ManagedServiceAccount token carried in the backup. If that token is
missing, expired, or frozen, failover ends in `Pending Import` — the
single most likely way this whole architecture fails. `TokenReported` must
be checked explicitly: a Velero-restored-but-frozen secret passes the
weaker "does a token exist" checks while rotation is already dead
(README §3.3, found live 2026-08-13).
**Success:** Every `auto-import-account` row: `TOKEN-REPORTED: True`,
expiry comfortably in the future (rotation validity is 144h; expect
several days out).
**Failure:** `False` with `cannot set an ownerRef on a resource you can't
delete` → the restored secret from a previous activation was never cleaned
up. Repair (safe ONLY when the cluster is already imported and
`managed-serviceaccount` addon `Available`):

```bash
oc --context $ACTIVE delete secret auto-import-account -n $MANAGED
sleep 30
oc --context $ACTIVE get managedserviceaccount auto-import-account -n $MANAGED \
  -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status}{" | "}{.status.expirationTimestamp}{"\n"}'
# expect: True | <now + 144h>
oc --context $ACTIVE get secret auto-import-account -n $MANAGED \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
# expect: ManagedServiceAccount   (controller-owned; the frozen copy had none)
```

### 0.3 A backup newer than every fix

```bash
oc --context $ACTIVE get backup -n open-cluster-management-backup \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,START:.status.startTimestamp' | tail -6
```

**Why:** Failover restores `latest`. Any repair (0.2 included) is not
DR-protected until a credentials backup taken *after* it reaches
`Completed` — the backup cadence (30 min here) is the repair-to-protection
lag, and the same number that anchors the RPO conversation.
**Success:** An `acm-credentials-schedule-*` set with `START` later than
your newest change, `PHASE: Completed`.
**Failure:** No new set past its cron slot → check
`oc --context $ACTIVE get schedules.velero.io -n open-cluster-management-backup`
(`LAST-BACKUP` distinguishes "hasn't fired yet" from "fired and stalled").
Note: after a cluster cold start the first backup fires off-cadence as a
catch-up, then the cron reasserts — off-slot timestamps right after a
power-on are normal.

### 0.4 Remaining static checks

```bash
oc --context $PASSIVE get ns open-cluster-management-global-set -o name   # must exist
oc --context $PASSIVE get crd routes.route.openshift.io                    # must be NotFound
oc --context $PASSIVE get pods -n openshift-gitops --no-headers | awk '{print $1,$3}'
oc --context $PASSIVE get backupstoragelocation -n open-cluster-management-backup
```

**Why (in order):** (1) the global-set namespace is where the
`managed-serviceaccount`/`cluster-proxy`/`work-manager` addons install
from — missing it silently breaks the whole MSA chain on the new hub;
(2) a stray gitopsaddon Route CRD 503s the aggregated API and wedges Argo
cluster caches at the worst possible moment; (3) the new hub must run the
same GitOps operator so restored wiring lands on a working Argo; (4) the
passive hub must already reach the shared bucket.
**Success:** namespace exists / CRD `NotFound` / all Argo pods `Running` /
BSL `Available`.
**Failure:** Each has its fix in the
[posture runbook](../acm-active-passive-dr/README.md) failure paths;
resolve before the exercise — all four are cheap now and expensive
mid-outage.

**Gate:** 0.1–0.4 all green → proceed.

## Phase A — Baseline and probes

### A.1 Availability probe (own terminal, runs through the whole exercise)

```bash
while true; do echo "$(date -u +%FT%TZ) $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 $APP_URL)"; sleep 10; done | tee -a ~/probe-$(date -u +%Y%m%d).log
```

**Why:** The architecture's core claim — workloads decoupled from hub
liveness — is only provable by an independent observer running before,
during, and after the disaster. `--max-time 5` forces hung connections to
log as failures instead of masquerading as slow successes.
**Success:** Unbroken `200`s for the entire exercise.
**Failure:** Any non-200 during the exercise is a finding — timestamp it
and correlate (a non-200 *after* the exercise window may just be your lab
powering down; check before writing it up as a DR failure).

### A.2 Hub-pointer probe (second terminal)

```bash
while true; do echo "$(date -u +%FT%TZ) $(oc --context $MANAGED get secret bootstrap-hub-kubeconfig -n open-cluster-management-agent -o jsonpath='{.data.kubeconfig}' --request-timeout=5s 2>/dev/null | base64 -d | awk '/server:/{print $2}')"; sleep 10; done | tee -a ~/hub-pointer-$(date -u +%Y%m%d).log
```

**Why:** Timestamps the exact second `$MANAGED`'s klusterlet re-points
from the dead hub to the new one — the managed-cluster half of your RTO,
measured instead of estimated. It also quietly proves the managed cluster
stays fully inspectable with no hub alive (the probe reads `$MANAGED`'s
own API).
**Success:** Steady old-hub URL now; flip to the new hub URL during Phase
D; no gaps.
**Failure:** Pointer never flips after activation `Finished` → the import
didn't reach the agent; go to D's failure modes.
**Expectation to set:** the pointer does NOT move when the active hub
dies — only when the new hub's activation claims the cluster. A long
stretch of old-hub entries mid-outage is correct.

### A.3 Baseline revision

```bash
curl -s $APP_URL | grep -i revision
```

**Why:** Records what the app serves *before* the mid-outage deploy, so
the Phase C flip is unambiguous.
**Success:** Current revision noted (e.g. `v2`).

**Gate:** both probes ticking + baseline noted → clear to kill the active
hub.

## Phase B — Disaster

### B.1 Power off the active hub

Out-of-band action (hypervisor/BMC/plug) — there is deliberately no `oc`
command here.

**Why:** A real datacenter loss gives no warning and no clean shutdown;
killing the API out-of-band is the honest simulation. Do NOT cordon/drain
first — that would be a migration, not a disaster.
**Success:**

```bash
curl -sk --max-time 5 https://api.$ACTIVE.k8socp.com:6443/version || echo DEAD
```

prints `DEAD` (connection refused/timeout).
**Failure:** API still answers → it isn't dead; activating the passive hub
now creates two live hubs fighting over `$MANAGED` (the activation
manifest's header warns exactly this). Verify death before Phase D.

### B.2 Confirm the workload does not care

```bash
tail -3 ~/probe-$(date -u +%Y%m%d).log
```

**Why:** The first customer-visible datapoint: hub dead, app serving.
("Some features stop working, even if all managed clusters still work" —
the docs' promise, observed.)
**Success:** `200`s continuing after B.1's timestamp.

## Phase C — Mid-outage deploy (optional but the best demo beat)

### C.1 Push a new revision with no hub alive

```bash
# in the git repo: bump REVISION in apps/hello-failover/configmap.yaml, then
git add apps/hello-failover/configmap.yaml && git commit -m "REVISION vN mid-outage" && git push
```

**Why:** Proves deployments flow git → cluster with zero hub involvement:
the hub orchestrates *placement*, never delivery. A deploy that lands
while no hub exists is the pull model's entire argument, made visible.
**Success:** Within ~3 min the availability probe's URL serves the new
revision (`curl -s $APP_URL | grep -i revision`). Sage's local Argo can
also be nudged: annotate the Application with
`argocd.argoproj.io/refresh=normal`.
**Failure:** App never updates → check `$MANAGED`'s local Argo
(`oc --context $MANAGED get applications.argoproj.io -A`) — this is
cluster-local GitOps debugging, unrelated to the dead hub.

## Phase D — Activate the passive hub

### D.1 Remove the passive-sync restore

```bash
oc --context $PASSIVE delete restore restore-acm-passive-sync -n open-cluster-management-backup
```

**Why:** The backup operator honors one Restore at a time; the passive
sync (managedClusters: `skip`) must go before the activation restore
(managedClusters: `latest`) can run. This ordering is the actual "big red
button" moment.
**Success:** `deleted`.
**Failure:** NotFound → passive sync was never running; note it (posture
drift) and continue — activation does not depend on it.

### D.2 Apply the activation restore

```bash
oc --context $PASSIVE apply -f manifests/57-restore-activate.yaml
oc --context $PASSIVE get restore restore-acm-activate -n open-cluster-management-backup -w
```

**Why:** `veleroManagedClustersBackupName: latest` is the one field that
distinguishes activation from passive sync — restoring the managed-cluster
resources is what makes this hub claim the fleet.
`cleanupBeforeRestore: CleanupRestored` clears previously-synced copies so
the restore lands clean.
**Success:** Phase reaches `Finished` (observed 2026-08-12: ~37 s).
**Failure:** `FinishedWithErrors` → read
`oc --context $PASSIVE describe restore restore-acm-activate -n open-cluster-management-backup`
and the velero pod logs in the same namespace; do not re-apply blindly
(the restore is idempotent but the error tells you which resource class
failed).

### D.3 Watch the claim land

```bash
oc --context $PASSIVE get managedclusters -w
```

**Why:** This is auto-import doing its job: the restored MSA token lets
the new hub create the import on `$MANAGED` without any human touching the
managed cluster.
**Success:** `$MANAGED` appears, then `Joined/Available True/True`
(observed ≤37 s from activation). The A.2 probe flips in the same window —
note both timestamps.
**Failure:** Stuck in `Pending Import` → the MSA token in the restored
backup was invalid/expired/frozen: exactly what pre-flight 0.2 exists to
prevent. Recovery mid-exercise: create a classic auto-import secret on the
new hub using a `$MANAGED` admin kubeconfig (documented manual import),
then fix the token chain per 0.2 afterwards.

**Gate:** `$MANAGED` `True/True` on `$PASSIVE` → the failover has
happened. Everything after this is verification and duties.

## Phase E — Verify, then clean up the restored token secret

### E.1 Full addon surface

```bash
oc --context $PASSIVE get managedclusteraddon -n $MANAGED
```

**Why:** `Joined/Available` proves the klusterlet; the addons prove the
full management plane (policy, search, proxy, MSA) re-established itself.
**Success:** All addons `Available: True` within a few minutes.
**Failure:** `managed-serviceaccount` missing/degraded → global-set
namespace check (0.4) on the new hub; others degraded → give them ~5 min
before digging, addon rollout is eventually consistent.

### E.2 Re-home evidence

```bash
grep -v "$(printf 'api.%s' $ACTIVE)" ~/hub-pointer-$(date -u +%Y%m%d).log | head -3
tail -3 ~/probe-$(date -u +%Y%m%d).log
```

**Why:** The two probe logs are the exercise's proof: the first flip
timestamp minus the D.2 apply timestamp is your measured management-plane
RTO; the availability log across the same window is the zero-downtime
claim.
**Success:** Pointer log shows the new hub URL; availability log shows
unbroken 200s.

### E.3 Post-activation hygiene — the restored MSA secret (README §3.3)

```bash
oc --context $PASSIVE get managedserviceaccount auto-import-account -n $MANAGED \
  -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status}{"\n"}'
# expect False with the ownerRef error → then:
oc --context $PASSIVE delete secret auto-import-account -n $MANAGED
sleep 30
oc --context $PASSIVE get managedserviceaccount auto-import-account -n $MANAGED \
  -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status}{" | "}{.status.expirationTimestamp}{"\n"}'
```

**Why:** The restored secret just did its job (D.3) and is now a
liability: the new hub's MSA controller cannot adopt a Velero-restored
secret, so rotation silently freezes and the NEXT failover dies at token
expiry. Load-bearing during activation, disposable after — delete it only
now, never before D.3.
**Success:** `True | <now + 144h>`.
**Failure:** Still `False` after a minute → check the
`managed-serviceaccount` addon is `Available` (E.1) — the re-mint is
performed by the addon agent, not the hub.

## Phase F — New-primary duties

### F.1 Start backups on the new active hub

```bash
oc --context $PASSIVE apply -f manifests/55-backupschedule.yaml
oc --context $PASSIVE get backupschedule,backup -n open-cluster-management-backup
```

**Why:** Failover is deliberately manual and so is this: until a
BackupSchedule runs HERE, the fleet state that just changed hands is
unprotected — and E.3's fresh token is not in any backup. ACM's
`backup-restore-enabled` policy exists purely to nag about this step.
**Success:** Schedule `Enabled`; first full set `Completed` within ~1 min
of its first fire; a credentials backup newer than E.3's fix.
**Failure:** `BackupCollision` → the OLD hub is somehow alive and still
writing to the bucket — you have a split-brain: kill it properly, delete
its schedule, then re-check.

### F.2 GitOps wiring came back with the restore

```bash
oc --context $PASSIVE get gitopscluster,placement -n openshift-gitops
oc --context $PASSIVE get applicationset -n openshift-gitops
oc --context $PASSIVE get applications.argoproj.io -A
```

**Why:** The resources backup carries the GitOpsCluster, Placements, and
ApplicationSet — restoring them re-registers `$MANAGED` into the new
hub's Argo (via the same MSA chain) and resumes pull-model propagation of
*new* placement decisions. Always `applications.argoproj.io`, never bare
`application` (ACM's `app.k8s.io` CRD shadows it).
**Success:** GitOpsCluster `successful`, ApplicationSet present, app
propagated.
**Failure:** `ClusterRegistrationFailed` → MSA token chain again (E.3/0.2
order: condition, then secret ownership).

**Gate:** F.1 first set `Completed` → the new posture is protected;
failback may begin whenever the old hub returns.

## Phase G — Failback as role swap

### G.1 Power the old hub back on; wait out the lease

```bash
oc --context $ACTIVE get managedclusters -w   # $ACTIVE = the RETURNED hub
```

**Why:** The returned hub wakes with a STALE worldview — it still lists
`$MANAGED` as `True/True` for the first ~2–4 min until the klusterlet
lease (which now heartbeats to the OTHER hub) expires.
**Success:** `$MANAGED` flips to `Available: Unknown`.
**Failure — the one dangerous moment of the whole exercise:** deleting the
ManagedCluster while it still reads `True` triggers a live detach and
**uninstalls the agent + hub-delivered workloads from `$MANAGED`** ("If
the status is not Unknown, your workloads are uninstalled" — the docs'
exact warning). If in doubt, wait; `Unknown` costs nothing.

### G.2 Defuse the returned hub's backup schedule

```bash
oc --context $ACTIVE get backupschedule -n open-cluster-management-backup
# expect: BackupCollision (it saw the new hub's newer backups in the shared bucket)
oc --context $ACTIVE delete backupschedule schedule-acm -n open-cluster-management-backup
```

**Why:** Two hubs writing one bucket corrupts `latest` for every future
restore. The collision guard freezes the returned hub's schedule
automatically (observed live ≤4 min after power-on) — but frozen is not
gone: delete it so the defusal is permanent and auditable.
**Success:** Schedule shows `BackupCollision`, then deletes cleanly.
**Failure:** Schedule still `Enabled` and writing → verify which backup is
newest in the bucket before ANY future restore; delete the schedule
immediately.

### G.3 Drop the stale claim

```bash
oc --context $ACTIVE delete managedcluster $MANAGED    # ONLY in Unknown (G.1)
```

**Why:** The returned hub's `ManagedCluster` object is a leftover claim on
a cluster that now belongs to the other hub. In `Unknown` state the
klusterlet is not listening to this hub, so the delete only removes
hub-side bookkeeping (observed: 15 s, zero stuck finalizers).
**Success:** Object gone in seconds; `$MANAGED` untouched (probe log
unbroken).
**Failure:** Delete hangs on finalizers → the cluster was NOT in `Unknown`
(see G.1's warning); investigate `$MANAGED`'s agent state immediately.

### G.4 Demote to passive

```bash
oc --context $ACTIVE apply -f manifests/56-restore-passive.yaml
oc --context $ACTIVE get restore -n open-cluster-management-backup
```

**Why:** `veleroManagedClustersBackupName: skip` + sync mode = this hub
continuously ingests the new active's backups without ever claiming the
fleet — a warm standby ready to be the next Phase D. The posture is now
symmetric again, roles swapped.
**Success:** `restore-acm-passive-sync` reaches `Enabled` ("restore will
continue to sync with new backups"); managedclusters shows
`local-cluster` only.
**Failure:** Restore `Error` → check the BSL on this hub (0.4) — after a
power-off the object store connection is the usual suspect.

**Gate:** G.4 `Enabled` → exercise complete.

## Phase H — Evidence and docs

- Summarize both probe logs (window, request count, failure count, flip
  timestamp) into the exercise record.
- Update the [posture runbook](../acm-active-passive-dr/README.md) header
  if the roles swapped (it states who is active NOW).
- Update README §3 with the new timings; commit everything —
  the repo IS the DR plan; an undocumented exercise never happened.
