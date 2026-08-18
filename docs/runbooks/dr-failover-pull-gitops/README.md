# Automated Pull Path — DR exercise runbook: GitOps operation, pull delivery

Same command / rationale / success / failure format as the
verified [Manual Pull Path runbook](../dr-failover-pull-manual/README.md); this
document is a DELTA — phases not listed here run exactly as the Manual
Pull Path wrote them (and that path verified them twice). The measured
timeline, including the falsified one-PR attempt, is the
[exercise record](../../exercises/automated-pull.md).

Conventions as the Manual Pull Path (`$ACTIVE`/`$PASSIVE`/`$MANAGED`, UTC, probes),
plus the overlay-dir mapping: the committed dirs keep the original lab
names (`dr/hub` = hub-x, `dr/spoke` = hub-y), so set both before
authoring any PR (values shown match the Manual Pull Path's exports):

```bash
export ACTIVE_DIR=dr/spoke   # $ACTIVE's overlay dir  (dr/hub if $ACTIVE=hub-x, dr/spoke if hub-y)
export PASSIVE_DIR=dr/hub    # $PASSIVE's overlay dir (dr/hub if $PASSIVE=hub-x, dr/spoke if hub-y)
```

## Phase P — One-time prerequisites

### P.0 RBAC first — the grant that makes git-driven DR possible

```bash
oc --context hub-x   apply -f dr/bootstrap/dr-role-rbac.yaml
oc --context hub-y apply -f dr/bootstrap/dr-role-rbac.yaml
oc --context hub-x auth can-i patch backupschedules.cluster.open-cluster-management.io \
  -n open-cluster-management-backup \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

**Why:** Discovered live: the default openshift-gitops
application-controller CANNOT write ACM backup CRs, and the operator's
`managed-by` label does NOT fix it (its minted role is an API-group
allowlist omitting `cluster.open-cluster-management.io` — verified with
`auth can-i` after labeling). The explicit Role grants exactly two
resource types in exactly one namespace — the fix and the security
statement in one file.

**Success:** `yes` from `auth can-i` on both hubs.

**Failure:** `no` → the RoleBinding subject doesn't match your Argo
instance's controller SA; check the SA name in the error message of a
failed sync and align.

### P.1 Bootstrap each hub's dr-role Application

```bash
oc --context hub-x   apply -f dr/bootstrap/dr-role-hub.yaml
oc --context hub-y apply -f dr/bootstrap/dr-role-spoke.yaml
oc --context hub-x   get applications.argoproj.io dr-role -n openshift-gitops
oc --context hub-y get applications.argoproj.io dr-role -n openshift-gitops
```

(The committed bootstrap filenames keep the original lab names:
`dr-role-hub.yaml` is hub-x's Application, `dr-role-spoke.yaml` is
hub-y's — likewise the `dr/hub/` and `dr/spoke/` overlay dirs.)

**Why:** Each hub's own Argo must reconcile its own role — the applier of
a failover cannot be the hub that just died. Imperative once, declarative
forever after. (`applications.argoproj.io`, never bare `application` —
ACM's CRD shadows it; yes, this bit us again during verification.)

**Success:** Both `Synced | Healthy`, and ADOPTION not
recreation — the live BackupSchedule (hub-x) and passive Restore (hub-y)
kept their original creationTimestamps through the first sync.

**Failure:** Sync `Failed` on RBAC → P.0 was skipped or landed late.
NOTE (observed live): a sync that exhausts its retries stays `Failed` —
Argo will NOT re-attempt the same revision by itself even with selfHeal.
After fixing the cause, trigger a fresh operation:

```bash
oc --context <hub> patch applications.argoproj.io dr-role -n openshift-gitops \
  --type merge -p '{"operation":{"sync":{}}}'
```

`OutOfSync` with a spec diff on adoption → the live object drifted from
`manifests/` (the copies are supposed to be identical); reconcile the
drift BEFORE trusting git-driven ops.

### P.2 Confirm the backup exclusion works

```bash
NEWEST=$(oc --context hub-x get backup -n open-cluster-management-backup \
  --sort-by=.metadata.creationTimestamp -o name | grep acm-resources-schedule | tail -1 | cut -d/ -f2)
oc --context hub-x -n open-cluster-management-backup exec deploy/velero -- \
  /velero backup describe "$NEWEST" --details | grep -A6 'v1alpha1/Application'
```

**Why:** If `dr-role` ever lands in a backup, a future restore delivers
split-brain (the other hub reconciling the wrong role dir). Exec'ing the
velero pod avoids needing a local CLI.

**Success:** the instance list shows the delivery resources
(`openshift-gitops/hello-failover-spoke`,
ApplicationSet `hello-failover`, AppProject, ArgoCD CR) and NO `dr-role`
— which existed in that namespace at backup time. Precision exclusion,
proven instance-level.

**Failure:** `dr-role` appears → stop; fix the label before anything
else.

## Phase 0/A/B/C — as the Manual Pull Path, plus one pre-flight line

Run the Manual Pull Path's Phases 0, A, B, C unchanged (MSA check, probes, out-of-band or
`oc debug` kill, death gate, mid-outage v-next push — pull delivery still
works hubless; that claim is already verified). Add to pre-flight:

```bash
oc --context $PASSIVE get application dr-role -n openshift-gitops -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

**Why:** The survivor's reconciler is about to become the failover's
executor; a broken dr-role app discovered mid-outage is a failed exercise.

**Success:** `Synced Healthy`.

## Phase D' — Failover as a pull request (PR-A: activation ONLY)

**FINDING (attempt 1, 2026-08-13): the one-PR flip straight to
`../roles/active` is FALSIFIED.** The role's BackupSchedule lands in the
same sync as the activation Restore; the operator ignores the Restore
while any schedule is active ("This resource is ignored because
BackupSchedule resource schedule-acm is currently active"), and the
premature schedule then overwrites the bucket's `latest` with the
survivor's passive (empty-fleet) state — after which even a re-run
activation "succeeds" restoring nothing. Recovery cost a full revert PR
and a bucket heal. Failover is therefore TWO PRs: D' (activation) and
F' (promotion).

### D'.1 Author the activation PR

```bash
git checkout -b failover-$(date -u +%Y%m%d%H%M)
# 1. cp dr/templates/restore-activate.template.yaml \
#      $PASSIVE_DIR/restore-activate-$(date -u +%Y%m%d%H%M).yaml
#    …replace <UTCSTAMP> in metadata.name
# 2. $PASSIVE_DIR/kustomization.yaml: resources -> ONLY the new
#    restore-activate-*.yaml (remove ../roles/passive; do NOT add
#    ../roles/active — that is F''s promotion PR, after the claim lands)
git add dr/ && git commit -m "FAILOVER: activate $PASSIVE ($ACTIVE dead $(date -u +%FT%TZ))" && git push -u origin HEAD
# open the PR
```

**Why:** The change is the entire failover *decision*, reviewable as a
diff: drop the passive role, add one uniquely-named activation one-shot
(the G.5 lesson baked into the filename). Nothing else — no
BackupSchedule until the fleet is claimed. The dead hub's overlay is NOT
touched yet — demotion is a separate, later decision, exactly as in the
manual path.

**Success:** PR shows a two-file diff whose kustomization lists exactly
one resource:

```bash
git diff --stat origin/main...HEAD   # expect: exactly the two files under $PASSIVE_DIR
```

**Failure:** `../roles/active` in the diff → you are re-running attempt
1's falsified choreography; fix before merge.

### D'.2 Review = the split-brain gate; merge = the decision

```bash
curl -sk --max-time 5 https://api.$ACTIVE.example.com:6443/version || echo DEAD   # reviewer runs this
```

**Why:** The manual path's B.2 gate moves into the merge decision — the
reviewer verifies death, and the merge commit records who decided, when,
on what evidence. (CI running this same check as a required status turns
the guard into machinery; note it as an enhancement, don't block on it.)

**Success:** `DEAD` → merge.

**Failure:** JSON answer → the active hub LIVES; close the PR. Merging
here is the split-brain the Manual Pull Path warns about, with better bookkeeping.

### D'.3 Let the survivor execute, and cut the poll wait

```bash
oc --context $PASSIVE annotate application dr-role -n openshift-gitops argocd.argoproj.io/refresh=normal --overwrite
oc --context $PASSIVE get restore -n open-cluster-management-backup -w
```

**Why:** Argo's ≤3 min poll is the only new latency vs the manual path
(V4); the refresh annotation removes most of it. PruneFirst should remove
the passive Restore before the activation applies (V1 — WATCH for this:
the passive restore should disappear, then the activation appear and run
to `Finished`).

**Success:** Passive restore pruned, `restore-acm-activate-<stamp>`
reaches `Finished`, then `$MANAGED` lands `Joined/Available` on
`$PASSIVE` (same ≈10 s machinery as verified).

**Failure (treat as the expected first outcome):** the activation lands
`FinishedWithErrors` with lastMessage
"ignored because Restore resource restore-acm-passive-sync is currently
active" — PruneFirst prunes the passive restore, but the operator
evaluates the activation before the prune completes, and a Restore is
one-shot: it stays dead. **Recovery (~30 s):** delete the ignored
activation Restore; selfHeal re-creates it within ~6 s and the fresh
object runs clean:

```bash
oc --context $PASSIVE delete restore restore-acm-activate-<stamp> -n open-cluster-management-backup
oc --context $PASSIVE get restore -n open-cluster-management-backup -w
# selfHeal re-creates the one-shot in seconds; expect it to reach Finished
```

Do NOT touch the passive restore (already pruned) and do NOT
`oc apply` the manifest by hand (a hand-applied object is untracked and
the demote PR's prune will never clean it — attempt-1 lesson).

## Phase E — as the Manual Pull Path

Manual Pull Path E (verify + [MSA hygiene](../../exercises/msa-token-hygiene.md)) unchanged.

## Phase F' — Promotion PR (PR-B): the git-driven F.1

```bash
git checkout -b promote-$(date -u +%Y%m%d%H%M)
# $PASSIVE_DIR/kustomization.yaml: resources ->
#   - ../roles/active
#   - restore-activate-<stamp>.yaml     (keep; demote PR removes it)
git add dr/ && git commit -m "PROMOTE: $PASSIVE to full active (claim verified)" && git push -u origin HEAD
# PR + merge — review gate: $MANAGED Joined/Available on $PASSIVE (paste it)
```

**Why:** Delivers the BackupSchedule only AFTER the claim landed — the
same ordering the manual path enforces with F.1, expressed in git. The
review gate is posture evidence, not death evidence.

**Success:** After merge+sync: schedule `Enabled`, the first full set
fires immediately and reaches `Completed` within ~1 min; no
`BackupCollision` (the old hub is dead or already demoted).

```bash
oc --context $PASSIVE get backupschedule,backup -n open-cluster-management-backup | head
# expect: schedule-acm Enabled; a full backup set Completed shortly after merge
```

**Failure:** Restore refused/ignored messages at THIS point → you merged
F' before D''s restore `Finished`; the operator's one-at-a-time rule
also applies to schedule-vs-restore — wait, then re-sync. F.2 unchanged
from the Manual Pull Path.

## Phase G' — Demote as the mirror PR

### G'.1 Author + merge the demote PR (dead hub still off is fine)

```bash
git checkout -b demote-$(date -u +%Y%m%d%H%M)
# 1. $ACTIVE_DIR/kustomization.yaml: resources -> ../roles/passive
# 2. git rm $ACTIVE_DIR/restore-activate-*.yaml   (if any — V5 housekeeping)
git add -A dr/ && git commit -m "DEMOTE: $ACTIVE to passive" && git push -u origin HEAD
# PR + merge — review gate here is posture correctness, not death
```

**Why:** Merging while the hub is down means it boots into current truth:
its Argo prunes the stale BackupSchedule (automating manual G.2) and
applies the passive Restore (manual G.4). V3 observes the boot-time race
(collision-fire vs prune) — expected benign in either order.

**Success:** After the hub boots: `dr-role` `Synced`, exactly one restore
(`restore-acm-passive-sync` `Enabled`), no BackupSchedule.

```bash
oc --context $ACTIVE get applications.argoproj.io dr-role -n openshift-gitops \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'   # expect: Synced Healthy
oc --context $ACTIVE get restore,backupschedule -n open-cluster-management-backup
# expect: restore-acm-passive-sync Enabled and NO BackupSchedule
```

**Failure:** Sync stuck on the pruned schedule → record for V3 and delete
it by hand; the underlying BackupCollision guard has already frozen it
regardless (verified in the Manual Pull Path, both directions).

### G'.2 The imperative residue — exactly as Manual Pull Path G.1 + G.3

Wait for `$MANAGED` to read `Available: Unknown` on the returned hub
(Manual Pull Path G.1's gate, including its warning — this is still the one
dangerous moment), then delete the stale ManagedCluster (G.3). No PR
represents this: it is runtime state, and the gate is a live reading.

```bash
oc --context $ACTIVE get managedclusters -w    # gate: $MANAGED reads Available=Unknown
oc --context $ACTIVE delete managedcluster $MANAGED
```

## Phase H — evidence, V-item verdicts (V1–V5), timings into the [exercise record](../../exercises/automated-pull.md),
role comments in `dr/*/kustomization.yaml` updated to match the new truth.
