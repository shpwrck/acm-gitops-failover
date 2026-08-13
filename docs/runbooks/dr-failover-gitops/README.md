# Path 2 — DR exercise runbook: GitOps operation, pull delivery

**Status: UNVERIFIED — authored 2026-08-13.** Same command / rationale /
success / failure format as the verified
[path-1 runbook](../dr-failover-exercise/README.md); this document is a
DELTA — phases not listed here run exactly as path 1 wrote them (and
path 1 verified them twice). The mechanism being exercised is
[`dr/README.md`](../../../dr/README.md); its open items V1–V5 are burned
down here.

Conventions as path 1 (`$ACTIVE`/`$PASSIVE`/`$MANAGED`, UTC, probes).

## Phase P — One-time prerequisites (before the first path-2 exercise)

### P.1 Bootstrap each hub's dr-role Application

```bash
oc --context hub   apply -f dr/bootstrap/dr-role-hub.yaml
oc --context spoke apply -f dr/bootstrap/dr-role-spoke.yaml
oc --context hub   get application dr-role -n openshift-gitops
oc --context spoke get application dr-role -n openshift-gitops
```

**Why:** Each hub's own Argo must reconcile its own role — the applier of
a failover cannot be the hub that just died. Imperative once, declarative
forever after.
**Success:** Both `Synced/Healthy`; cluster state unchanged (the overlays
encode the CURRENT posture — bootstrap is adoption, not change; Argo
adopts the existing BackupSchedule/Restore objects since specs are
identical).
**Failure:** `OutOfSync` with a diff on adoption → the live object drifted
from `manifests/` (the two copies are supposed to be identical) —
reconcile the drift BEFORE trusting git-driven ops.

### P.2 Confirm the backup exclusion works (V2)

```bash
velero backup describe <newest-acm-resources-backup> --details -n open-cluster-management-backup | grep -i 'dr-role' || echo "EXCLUDED — correct"
```

**Why:** If `dr-role` ever lands in a backup, a future restore delivers
split-brain (the other hub reconciling the wrong role dir). This check
must pass once before the posture is trusted, and belongs in pre-flight
thereafter.
**Success:** `EXCLUDED — correct` on a backup taken AFTER P.1.
**Failure:** The app appears in the backup → stop; fix the label before
anything else.

## Phase 0/A/B/C — as path 1, plus one pre-flight line

Run path-1 Phases 0, A, B, C unchanged (MSA check, probes, out-of-band or
`oc debug` kill, death gate, mid-outage v-next push — pull delivery still
works hubless; that claim is already verified). Add to pre-flight:

```bash
oc --context $PASSIVE get application dr-role -n openshift-gitops -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

**Why:** The survivor's reconciler is about to become the failover's
executor; a broken dr-role app discovered mid-outage is a failed exercise.
**Success:** `Synced Healthy`.

## Phase D' — Failover as a pull request

### D'.1 Author the role-flip PR

```bash
git checkout -b failover-$(date -u +%Y%m%d%H%M)
# 1. dr/$PASSIVE/kustomization.yaml: resources -> ../roles/active
# 2. cp dr/templates/restore-activate.template.yaml \
#      dr/$PASSIVE/restore-activate-$(date -u +%Y%m%d%H%M).yaml
#    …replace <UTCSTAMP> in metadata.name, add the file to resources
git add dr/ && git commit -m "FAILOVER: activate $PASSIVE ($ACTIVE dead $(date -u +%FT%TZ))" && git push -u origin HEAD
# open the PR
```

**Why:** The change is the entire failover, reviewable as a diff: role
flip + one uniquely-named activation one-shot (the G.5 lesson baked into
the filename). Nothing else. The dead hub's overlay is NOT touched yet —
demotion is a separate, later decision, exactly as in the manual path.
**Success:** PR shows a two-file diff.
**Failure:** Anything else in the diff → wrong branch base or stray edits;
a failover PR must be minimal enough to review in seconds.

### D'.2 Review = the split-brain gate; merge = the decision

```bash
curl -sk --max-time 5 https://api.$ACTIVE.k8socp.com:6443/version || echo DEAD   # reviewer runs this
```

**Why:** The manual path's B.2 gate moves into the merge decision — the
reviewer verifies death, and the merge commit records who decided, when,
on what evidence. (CI running this same check as a required status turns
the guard into machinery; note it as an enhancement, don't block on it.)
**Success:** `DEAD` → merge.
**Failure:** JSON answer → the active hub LIVES; close the PR. Merging
here is the split-brain path 1 warns about, with better bookkeeping.

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
**Failure:** Activation `Error` mentioning an existing restore → V1
failed; delete the passive Restore by hand, let selfHeal re-apply the
activation, and file the two-PR choreography as the fix. Record it.

## Phase E/F — as path 1, minus F.1

Path-1 E (verify + §3.3 MSA hygiene) unchanged. F.1 is now AUTOMATIC —
the BackupSchedule arrived with the role flip; verify it `Enabled` and
its first set `Completed` (fires immediately — verified path 1). F.2
unchanged.

## Phase G' — Demote as the mirror PR

### G'.1 Author + merge the demote PR (dead hub still off is fine)

```bash
git checkout -b demote-$(date -u +%Y%m%d%H%M)
# 1. dr/$ACTIVE/kustomization.yaml: resources -> ../roles/passive
# 2. git rm dr/$ACTIVE/restore-activate-*.yaml   (if any — V5 housekeeping)
git add -A dr/ && git commit -m "DEMOTE: $ACTIVE to passive" && git push -u origin HEAD
# PR + merge — review gate here is posture correctness, not death
```

**Why:** Merging while the hub is down means it boots into current truth:
its Argo prunes the stale BackupSchedule (automating manual G.2) and
applies the passive Restore (manual G.4). V3 observes the boot-time race
(collision-fire vs prune) — expected benign in either order.
**Success:** After the hub boots: `dr-role` `Synced`, exactly one restore
(`restore-acm-passive-sync` `Enabled`), no BackupSchedule.
**Failure:** Sync stuck on the pruned schedule → record for V3 and delete
it by hand; the underlying BackupCollision guard has already frozen it
regardless (verified path 1, both directions).

### G'.2 The imperative residue — exactly as path 1 G.1 + G.3

Wait for `$MANAGED` to read `Available: Unknown` on the returned hub
(path-1 G.1's gate, including its warning — this is still the one
dangerous moment), then delete the stale ManagedCluster (G.3). No PR
represents this: it is runtime state, and the gate is a live reading.

## Phase H — evidence, V-item verdicts (V1–V5), timings into README §3.5,
role comments in `dr/*/kustomization.yaml` updated to match the new truth.
