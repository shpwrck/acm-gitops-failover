# Git-driven DR roles (paths 2 & 4)

**Status: WIRING VERIFIED LIVE 2026-08-13** (bootstrap, adoption, RBAC,
backup exclusion — V2 closed with instance-level evidence). The
role-FLIP items (V1, V3, V4, V5) still require the path-2 disaster
exercise ([runbook](../docs/runbooks/dr-failover-gitops/README.md));
until then, flip claims are design, not proof.

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
- **Post-activation MSA secret cleanup** (README §3.3): conditional on
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

Open — require the path-2 disaster exercise:

- **V1 — PruneFirst ordering:** confirm a single role-flip PR removes the
  passive Restore before the activation Restore is applied ("only one
  Restore honored at a time"). Fallback if it misbehaves: two-PR
  choreography (demote-then-activate).
- **V3 — Boot-time demote race:** returned hub syncing the demote overlay
  while its stale BackupSchedule sits in `BackupCollision` — expected
  benign in either order; observe it once.
- **V4 — Measured RTO delta:** merge→re-home vs the manual path's ≈10 s
  (expected: + PR merge + Argo poll (≤3 min; refresh-annotation or a git
  webhook cuts it), which is the price of an audit trail and a review
  gate).
- **V5 — Restore names accumulating:** confirm demote-PR file removal
  prunes the inert Finished restores as expected.
