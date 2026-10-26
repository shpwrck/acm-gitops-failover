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
In October 2026 all four were run again on a different lab, with ACM
2.17.3 (see [October 2026 re-validation](#october-2026-re-validation)).

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

## October 2026 re-validation

A second lab, built from [build.md](build.md) with only these documents:
three single-node OpenShift 4.21 clusters, ACM 2.17.3 on both hubs,
OpenShift GitOps 1.22, and an S3-compatible store outside the clusters.
The first run was done by hand on 2026-10-21 (manual pull and push,
hub-x powered off): activation to claim 11 s, the hubless deploy served
in 3:30, and 0 failed samples out of 178. On 2026-10-22 four more runs
used [`hack/dr.sh`](../hack/dr.sh), alternating the hub that dies, each
with both demo apps deployed and probed. On 2026-10-23 the lab was
removed with [`hack/teardown.sh --full`](build.md#tearing-it-down) and
rebuilt from the bare clusters with [`hack/build.sh`](build.md#the-scripted-build)
in 53 minutes, and two more git-driven runs followed. On 2026-10-26 a
manual and a git-driven run checked the scripts after their readability
review. Every outage was a power-off by hand.

| Run | Path | Hub that died | To claim | To all addons | To push delivery back | Pull deploy, no hub | Push delivery RTO | Failed samples from the cut on |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Manual | hub-y | 11 s | 42 s | 2:33 | 1:11 | 4:23 | 0 |
| 2 | Git-driven | hub-x | 27 s | 1:53 | 3:04 | 1:44 | 6:31 | 0 |
| 3 | Manual | hub-y | 12 s | 1:43 | 2:23 | 6:23 | 9:12 | 0 |
| 4 | Git-driven | hub-x | 28 s | 55 s | 2:16 | 0:26 | 4:57 | 0 |
| 5 | Git-driven | hub-y | 28 s | 50 s | 2:07 | 0:27 | 3:45 | 1 (a probe timeout, below) |
| 6 | Git-driven | hub-x | 27 s | 1:55 | 3:14 | 2:46 | 9:56 | 0 |
| 7 | Manual | hub-y | 12 s | 40 s | 1:42 | 2:19 | 4:42 | 0 |
| 8 | Git-driven | hub-x | 28 s | 56 s | 2:14 | 4:18 | 7:28 | 0 |

"To" columns count from the activation restore's apply (manual) or the
PR-A merge (git-driven). From run 7 on, the script waits for Continue
between stages, and the times leave that wait out, as the script's own
summary does. The git-driven claims include the activation race of
finding 3, which fired on every git-driven run and cost about 16 s. Each
probe sampled every 10 s, 72 to 308 samples per app per run.
The series has two failed samples, both pull-app probe timeouts (curl's
5 s limit, logged as `000`) while the push app answered through the same
router in the same second. One came in run 2, 32 minutes before the
cut, in an attempt that was stopped and started again. The other came in
run 5, 7 s after the claim. The pull app's pod, route and endpoints did
not change around it, and the next sample was 200, so it was the
probe's side (a slow lookup or connect from the workstation), not the
app. Since then the probe logs curl's exit code and timings on every
failed sample.

The push delivery RTO counts from the mid-outage commit, and the runbook
waits for the pull app to serve that commit (C.1) before the failover
starts, so the RTO includes that wait. In run 3 the spoke's Argo CD took
5:33 to notice the commit, which is within its defaults: a refresh every
2 minutes plus up to 1 minute of jitter, a branch resolution cached for
up to 3 minutes, then about 1 minute for the ConfigMap volume. Hubless
pull delivery therefore takes anywhere from under a minute to about 6.5
minutes; the "to push delivery back" column is the part DR controls.

Other timings from these runs:

- Human review took 0:24 to 3:22 per PR in the git-driven runs (one
  demote PR waited 8:53 for its merge).
- The returned hub read the moved cluster as `Unknown` 3:14 to 3:48
  after its API answered again.
- A whole run, from the probes starting to rejoin done, took 12 to 33
  minutes; most of the spread is the wait for a cut time between backup
  slots, and when the PRs were merged.

## Findings

These are the behaviors the runs uncovered. Each one is already built into
the runbooks; this list says why the runbooks look the way they do.

1. **Activation silently freezes ManagedServiceAccount token rotation.**
   The restored `auto-import-account` secret cannot be adopted by the new
   hub's controller, so the token stops rotating and the *next* failover
   fails days later in `Pending Import`. Reproduced on every activation
   on ACM 2.17.0; fixed by deleting the restored secret after the claim
   lands. On ACM 2.17.3 (the October runs) the controller adopted and
   rotated the restored secret within about a minute on all nine
   activations, so step E.3 checks which case it is before deleting
   anything. Details: [msa-token-hygiene.md](msa-token-hygiene.md).
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
11. **A hub's first backup set after a cold boot can fail.** After the
    lab was powered on, the active hub's catch-up set failed because the
    cluster's DNS refused the S3 lookup while it was still settling; the
    next scheduled set completed. Pre-flight (0.3) reads the newest
    credentials backup, so right after a power-on, wait for the next
    :00/:30 set before starting an exercise.
