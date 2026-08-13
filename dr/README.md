# Git-driven DR roles (paths 2 & 4)

**Status: AUTHORED 2026-08-13, NOT YET VERIFIED LIVE.** The design encodes
everything the two verified manual exercises taught (README §3, §3.4); the
open items below must be burned down by the path-2 exercise
([runbook](../docs/runbooks/dr-failover-gitops/README.md)) before any
claim here is treated as proven.

## Mechanism

Each hub's DR role (active = BackupSchedule, passive = sync Restore) is
git state under `dr/<hub>/`, reconciled by **that hub's own local Argo
CD** — bootstrapped once, imperatively, per hub
(`dr/bootstrap/dr-role-<hub>.yaml`). The reconciler survives the *other*
hub's death by construction, which is the property that makes git-driven
failover possible at all: after a disaster, the surviving hub is both the
decision's subject and its executor.

**Failover = a pull request:**

1. Branch. In `dr/<survivor>/kustomization.yaml`, point `resources` at
   `../roles/active`. Copy
   `dr/templates/restore-activate.template.yaml` to
   `dr/<survivor>/restore-activate-<UTCSTAMP>.yaml` (unique name — see the
   template header for why) and add it to the overlay's resources.
2. Open the PR. **The PR review IS the split-brain guard**: the reviewer
   (or a CI check) must verify the old active hub's API is actually dead —
   the same B.2 gate as the manual path, moved into the merge decision.
3. Merge. The survivor's local Argo syncs (≤3 min poll, or annotate
   `dr-role` with `argocd.argoproj.io/refresh=normal` to cut the wait),
   prunes the passive Restore first (`PruneFirst=true`), applies the
   activation one-shot, and the machinery from the verified manual path
   takes over — restore `Finished`, MSA auto-import, re-home.
4. Post-activation hygiene (README §3.3 — delete the restored
   `auto-import-account` secrets once clusters are imported) stays a
   gated imperative step; see "Imperative residue" below.

**Failback/demote = the mirror PR** (can be merged while the dead hub is
still down): flip the dead hub's overlay to `../roles/passive` and delete
the old `restore-activate-*.yaml` file from it. When the hub boots, its
local Argo syncs current truth directly: prunes its stale BackupSchedule
(automating the manual G.2 defuse) and applies the passive restore (G.4).
The BackupCollision guard remains as defense-in-depth underneath.

## Imperative residue (deliberate, documented)

Pretending everything is declarative is how operators get burned. These
stay imperative, with their safety gates:

- **Bootstrap** (`dr/bootstrap/`): once per hub, by hand. See file
  headers.
- **Stale ManagedCluster deletion on a returned hub** (manual path G.3):
  runtime state, not git state, and it carries the exercise's one
  dangerous gate — `Available: Unknown` first, *never* elapsed time
  ("if the status is not Unknown, your workloads are uninstalled").
- **Post-activation MSA secret cleanup** (README §3.3): conditional on
  observed `TokenReported: False`; scriptable, not declarable.

## Why each hub's dr-role Application must never be backed up

ACM's resource backups demonstrably include argoproj objects in
`openshift-gitops` (the ApplicationSet restores cross-hub — observed both
directions). A `dr-role` Application restored onto the other hub would
make that hub reconcile the WRONG role directory — split-brain delivered
by the backup system itself. Hence the non-negotiable
`velero.io/exclude-from-backup: "true"` label on both bootstrap
Applications.

## Open verification items (path-2 exercise burns these down)

- **V1 — PruneFirst ordering:** confirm a single role-flip PR removes the
  passive Restore before the activation Restore is applied ("only one
  Restore honored at a time"). Fallback if it misbehaves: two-PR
  choreography (demote-then-activate).
- **V2 — Backup exclusion:** confirm the `dr-role` Applications do NOT
  appear in any backup (`velero backup describe --details` on a fresh
  set), and that generated/synced role resources restore harmlessly.
- **V3 — Boot-time demote race:** returned hub syncing the demote overlay
  while its stale BackupSchedule sits in `BackupCollision` — expected
  benign in either order; observe it once.
- **V4 — Measured RTO delta:** merge→re-home vs the manual path's ≈10 s
  (expected: + PR merge + Argo poll (≤3 min; refresh-annotation or a git
  webhook cuts it), which is the price of an audit trail and a review
  gate).
- **V5 — Restore names accumulating:** confirm demote-PR file removal
  prunes the inert Finished restores as expected.
