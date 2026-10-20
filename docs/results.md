# Verification results

What the four failover paths measured when they were run live, and what
those runs taught. The procedures are the [runbooks](runbooks/); the
environment is described in [build.md](build.md).

## Test environment

- Three single-node OpenShift 4.21 clusters: two ACM 2.17.0 hubs (hub-x,
  hub-y) and one workload cluster (spoke).
- OpenShift GitOps 1.21 on all three; OADP installed by ACM's
  `cluster-backup` component on both hubs.
- An S3-compatible store (SeaweedFS) outside the clusters, backups every
  30 minutes.
- Hub "disasters" were a power-off or a scheduled `shutdown` on the hub's
  only node (see runbook step B.1 for the variants).
- Availability was measured by a probe hitting each demo app's route every
  10 seconds for the whole exercise.

Each path was run in August 2026 and then re-run end to end on 2026-08-18
by an operator with no prior context, following only these documents.

## Measured results

**Availability: zero non-200 responses on either demo app in any run.**
Through every hub death, failover and failback, workloads on the spoke
never noticed the hub going away.

| Path | Runs | Re-home (activation to spoke `Joined/Available` on the new hub) | Deploy during the outage | Notes |
| --- | --- | --- | --- | --- |
| [Manual pull](runbooks/dr-failover-pull-manual/README.md) | 3 (both directions, then re-run) | 10–39 s | Landed hubless, in the spoke's normal Argo poll (about 2–4 min) | Whole exercise, pre-flight to symmetric posture: about 37 min |
| [Git-driven pull](runbooks/dr-failover-pull-gitops/README.md) | 3 (one falsified the one-PR design, then two clean) | PR-A merge to claim 20–72 s, including the activation-race recovery | Landed hubless, as above | Merge to Argo sync about 5 s with the refresh annotation |
| [Manual push](runbooks/dr-failover-push-manual/README.md) | 2 | 10–16 s | **Did not land until the new hub pushed it: push delivery RTO 2:53 and 4:59** | The pull app in the same window updated after its normal poll |
| [Git-driven push](runbooks/dr-failover-push-gitops/README.md) | 2 | PR-A merge to claim 28–50 s, including the recovery | **Push delivery RTO 2:45 and 4:11** | Faster than the manual push run on the same day, both times |

Push delivery RTO is the time from a commit made while the hub is down to
the push app's route serving it. It breaks down into the operator's
decision time, activation (about 10 s), the `application-manager`
ManagedServiceAccount and Argo cluster secret being re-minted on the new
hub (about 1–1.5 min), the first push sync, and the ConfigMap change
reaching the pod (up to about 1 min). The pull model has no equivalent
cost: its deploys never depend on a hub.

Other timings worth knowing:

- An activation `Restore` reaches `Finished` in 7–37 s.
- A new `BackupSchedule` fires its first full backup set immediately (no
  wait for the cron slot), and it completes in under a minute.
- A returned hub reads the moved cluster as `True/True` for about 2–4
  minutes, until the klusterlet's lease expires; after a longer outage it
  wakes up already reading `Unknown`.
- Failback as a role swap (the returned hub becomes the new passive) took
  about 7 minutes from power-on.

## Findings

These are the behaviors the runs uncovered. Each one is already built into
the runbooks; this list says why the runbooks look the way they do.

1. **Activation silently freezes ManagedServiceAccount token rotation.**
   The restored `auto-import-account` secret cannot be adopted by the new
   hub's controller, so the token stops rotating and the *next* failover
   fails days later in `Pending Import`. Reproduced on every activation;
   fixed by deleting the restored secret after the claim lands. Details:
   [msa-token-hygiene.md](msa-token-hygiene.md).
2. **A one-PR git-driven failover does not work.** Delivering the
   `BackupSchedule` and the activation `Restore` in the same sync makes
   the backup operator ignore the restore, and the premature schedule then
   writes the survivor's empty-fleet passive state over the bucket's
   `latest`. Hence the two-PR choreography in [dr/README.md](../dr/README.md).
3. **`PruneFirst` does not win the activation race.** Argo prunes the
   passive restore first, but the operator can evaluate the new activation
   before the prune completes and ignore it (`FinishedWithErrors`). Deleting
   the ignored one-shot lets selfHeal re-create it, and the fresh object
   runs clean in about 10 s. This fired on every two-PR run, so the
   runbook treats it as the expected outcome.
4. **A `Restore` is one-shot.** Re-applying an activation restore whose
   name already exists in `Finished` state is a silent no-op. Git-driven
   activations use time-stamped names, and the demote PR's prune reaps
   them; a hand-applied activation restore is not tracked by Argo and has
   to be deleted by hand.
5. **selfHeal fights manual operation.** With the `dr-role` Application
   live, a manually deleted passive restore came back in 6 seconds. The
   manual runbooks therefore suspend automation first (step D.0) and
   re-align git before turning it back on.
6. **`BackupCollision` guards the bucket, but not instantly.** A returned
   old hub freezes its own schedule when it sees the new hub's backups,
   usually triggered by the activation marker within minutes of boot. One
   returned hub still landed a catch-up backup set before freezing, so the
   runbook deletes the schedule rather than relying on the freeze. Whether
   the freeze or the demote PR's prune came first, the outcome was benign.
7. **Deleting a stale `ManagedCluster` is the one dangerous step.** On the
   returned hub it is safe only once the cluster reads
   `Available: Unknown`; deleting it while it still reads `True` detaches
   the cluster and uninstalls its hub-delivered workloads.
8. **The push model's convenience is a cluster-admin credential.** Push
   delivery uses the `application-manager` ManagedServiceAccount, whose
   managed-cluster service account is bound to a cluster-admin-equivalent
   role, and it tunnels through the cluster-proxy addon. A compromised hub
   Argo is admin on every cluster it pushes to; the pull model keeps the
   hub free of delivery credentials.
9. **The backup-exclusion label works at instance level.** Backups
   contained the demo Applications and ApplicationSets (so push delivery
   fails over) and never the `dr-role` Application in the same namespace.
10. **A failed Argo sync is not retried on the same revision.** After
    fixing missing RBAC, the `dr-role` app stayed `Failed` until a fresh
    sync operation was triggered (see [dr/README.md](../dr/README.md)).
