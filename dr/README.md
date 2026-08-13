# Git-driven DR roles (paths 2 & 4)

**Status: FLIP VERIFIED LIVE 2026-08-13** (path-2 disaster exercise,
[runbook](../docs/runbooks/dr-failover-gitops/README.md), two attempts —
[exercise records](../docs/exercises.md) §3.5). V0/V2 closed with wiring evidence earlier that day; the
exercise closed V1 (FALSIFIED as designed — hence the two-PR
choreography below), V3 (benign, prune won), and V4 (measured). V5 stays
open until spoke's next demote.

## Mechanism

Each hub's DR role (active = BackupSchedule, passive = sync Restore) is
git state under `dr/<hub>/`, reconciled by **that hub's own local Argo
CD** — bootstrapped once, imperatively, per hub
(`dr/bootstrap/dr-role-<hub>.yaml`). The reconciler survives the *other*
hub's death by construction, which is the property that makes git-driven
failover possible at all: after a disaster, the surviving hub is both the
decision's subject and its executor.

**Failover = TWO pull requests** (activation, then promotion — the
one-PR version is FALSIFIED, see below):

1. **PR-A (activation).** Branch. In `dr/<survivor>/kustomization.yaml`,
   set `resources` to ONLY the activation one-shot: copy
   `dr/templates/restore-activate.template.yaml` to
   `dr/<survivor>/restore-activate-<UTCSTAMP>.yaml` (unique name — see the
   template header for why) and make it the sole resources entry —
   dropping `../roles/passive`, NOT adding `../roles/active`.
2. Open PR-A. **The PR review IS the split-brain guard**: the reviewer
   (or a CI check) must verify the old active hub's API is actually dead —
   the same B.2 gate as the manual path, moved into the merge decision.
3. Merge PR-A. The survivor's local Argo syncs (≤3 min poll, or annotate
   `dr-role` with `argocd.argoproj.io/refresh=normal` to cut the wait),
   prunes the passive Restore first (`PruneFirst=true`), applies the
   activation one-shot, and the machinery from the verified manual path
   takes over — restore `Finished`, MSA auto-import, re-home.
4. **PR-B (promotion), only after the claim is verified** (managed
   clusters `Joined/Available` on the survivor): add `../roles/active`
   back above the activation file in the overlay. Its merge delivers the
   BackupSchedule — the git-driven equivalent of manual F.1, and like it,
   deliberately AFTER activation.
5. Post-activation hygiene (exercise records §3.3 — delete the restored
   `auto-import-account` secrets once clusters are imported) stays a
   gated imperative step; see "Imperative residue" below.

**Why two PRs (falsified live, 2026-08-13 path-2 attempt 1):** a single
PR that flips straight to `../roles/active` delivers the BackupSchedule
and the activation Restore in the SAME sync, and two verified failure
modes follow. (1) The backup operator **ignores a Restore while any
BackupSchedule is active** ("This resource is ignored because
BackupSchedule resource schedule-acm is currently active") — the
activation is refused, and because a Restore is one-shot, re-applying
the identical spec later is a silent no-op. (2) Worse, the premature
schedule immediately fires a full backup set from the not-yet-active
survivor, writing its **passive (empty-fleet) state over the bucket's
`latest`** — after which even a correctly re-run activation restore
"succeeds" while restoring nothing. Both bit in one run; the split is
load-bearing, not style.

**Failback/demote = the mirror PR** (can be merged while the dead hub is
still down): flip the dead hub's overlay to `../roles/passive` and delete
the old `restore-activate-*.yaml` file from it. When the hub boots, its
local Argo syncs current truth directly: prunes its stale BackupSchedule
(automating the manual G.2 defuse) and applies the passive restore (G.4).
The BackupCollision guard remains as defense-in-depth underneath.

## Imperative residue (deliberate, documented)

Pretending everything is declarative is how operators get burned. These
stay imperative, with their safety gates:

- **Bootstrap** (`dr/bootstrap/`): once per hub, by hand, RBAC FIRST
  (`dr-role-rbac.yaml`, then `dr-role-<hub>.yaml`). Verified 2026-08-13:
  the default openshift-gitops controller cannot touch the ACM backup
  CRs, and the operator's `managed-by` label trick does NOT fix it (its
  minted role is an API-group allowlist that omits
  `cluster.open-cluster-management.io` — checked with `oc auth can-i`).
  The explicit two-resource Role is both the fix and the tighter
  statement of what git-driven DR may touch. Bonus finding: a sync that
  exhausted its retries while RBAC was missing stays Failed — Argo does
  not re-try the same revision on its own; trigger a fresh operation
  (`oc patch applications.argoproj.io dr-role -n openshift-gitops
  --type merge -p '{"operation":{"sync":{}}}'`) after fixing
  permissions.
- **Stale ManagedCluster deletion on a returned hub** (manual path G.3):
  runtime state, not git state, and it carries the exercise's one
  dangerous gate — `Available: Unknown` first, *never* elapsed time
  ("if the status is not Unknown, your workloads are uninstalled").
- **Post-activation MSA secret cleanup** (exercise records §3.3): conditional on
  observed `TokenReported: False`; scriptable, not declarable.

## Coexistence with manual operation (VERIFIED constraint)

Once this wiring is live, **manual role surgery on a hub is fought by its
reconciler**: selfHeal recreated a manually-deleted passive Restore in
**6 seconds** (observed 2026-08-13, 16:00:22Z→16:00:28Z). Consequences:

- Manual paths (1/3) now REQUIRE the break-glass suspend first (path-1
  runbook D.0): null out `syncPolicy.automated` on the operated hub's
  `dr-role`, operate, re-align git to the new reality, only then
  re-enable automation.
- This is the customer lesson in miniature: git-driven and imperative
  operation don't compose on the same resources — pick one as
  authoritative and make the other an explicit, documented exception.

## Why each hub's dr-role Application must never be backed up

ACM's resource backups demonstrably include argoproj objects in
`openshift-gitops` (the ApplicationSet restores cross-hub — observed both
directions). A `dr-role` Application restored onto the other hub would
make that hub reconcile the WRONG role directory — split-brain delivered
by the backup system itself. Hence the non-negotiable
`velero.io/exclude-from-backup: "true"` label on both bootstrap
Applications.

## Verification ledger

Closed 2026-08-13 (wiring, no disaster required):

- **V0 — Bootstrap + adoption (added during verification):** dr-role apps
  reach `Synced/Healthy` on both hubs and ADOPT the live
  BackupSchedule/Restore (creation timestamps unchanged: 14:46:37Z /
  14:59:20Z) rather than recreating them. Required the RBAC bootstrap
  (above) discovered in the same session.
- **V2 — Backup exclusion: VERIFIED.** Instance list of
  `acm-resources-schedule-20260813153034` contains
  `openshift-gitops/hello-failover-sage` (Application),
  `openshift-gitops/hello-failover` (ApplicationSet), the AppProject and
  ArgoCD CR — and NO `dr-role`, which existed in the same namespace at
  backup time. Delivery resources ride the backup; the role reconciler
  does not. (Checked via `oc -n open-cluster-management-backup exec
  deploy/velero -- /velero backup describe <name> --details` — no local
  CLI needed.) Re-confirmed on `…160034` after the push app went live:
  `hello-failover-push-sage` + ApplicationSet `hello-failover-push`
  INCLUDED (push delivery fails over), `dr-role` still absent — the
  opposite-treatments design, proven both ways.

Closed 2026-08-13 by the path-2 disaster exercise (exercise records §3.5):

- **V1 — PruneFirst ordering: FALSIFIED, twice, two different ways.**
  Attempt 1 (one-PR flip to `../roles/active`): the role's BackupSchedule
  arrived in the same sync and the operator ignored the activation
  entirely, then the premature schedule poisoned the bucket's `latest`
  (details in "Why two PRs" above). Attempt 2 (activation-only PR-A):
  PruneFirst DID prune the passive Restore, but the activation one-shot
  was evaluated first and permanently ignored ("only one Restore honored
  at a time" — `FinishedWithErrors`, restore ran nothing). **Verified
  recovery, now the canonical D'.3 step: delete the ignored one-shot;
  selfHeal re-creates it (6 s) and the fresh evaluation runs clean —
  delete→`Finished`→claim took 11 s live.** The predicted fallback (two-PR
  choreography) is now the documented design.
- **V3 — Boot-time demote race: VERIFIED benign, prune won.** Hub booted
  ~18:09Z still holding active-role state (demote PR merged 18:09:29Z
  while it was down); sage read `Unknown` at 18:13:08Z; hub's own Argo
  natural-poll sync pruned the stale BackupSchedule at 18:13:29Z before
  it ever fired a backup or a collision, and the passive restore was
  `Enabled` by 18:13:39Z — manual G.2+G.4 fully automated. **Path 4
  observed the OTHER order** (collision 18:51:30Z → prune 18:51:41Z):
  benign both ways, as designed — the guard freezes, the prune cleans.
- **V4 — Measured RTO delta:** merge→Argo sync ≈5 s with the refresh
  annotation (18:02:09→18:02:14Z); clean-path machinery merge→claim is
  ≈20 s (restore create→`Finished`→`Joined/Available` observed at 11 s).
  Attempt 2's 6-minute merge→claim wall clock was V1 detection+recovery,
  not machinery. The audit trail costs tens of seconds, not minutes.

Open:

- **V5 — Restore names accumulating:** confirm demote-PR file removal
  prunes the inert Finished restores — observe at spoke's next demote
  (path-4 failback). Note from attempt 1: an activation restore
  re-created by hand (`oc apply`) is NOT Argo-tracked and must be deleted
  by hand; only Argo-created objects get pruned by the demote PR.
