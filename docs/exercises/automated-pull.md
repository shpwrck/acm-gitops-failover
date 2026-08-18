# Automated Pull Path — exercise record (verified live, 2026-08-13)

The git-driven flip run twice against the restored posture (hub-x active,
hub-y passive), driven by the
[`dr-failover-gitops` runbook](../runbooks/dr-failover-gitops/README.md).
Kill variant both times: `shutdown -r +1` (self-recovering graceful
reboot — no out-of-band dependency; SNO stays API-dead ~8 min).

**Attempt 1 (17:32–17:57Z) — falsified the one-PR design.** Kill
17:32:04Z; API dead 17:33:23Z; `REVISION v4` committed hubless 17:34:09Z;
failover PR #1 merged 17:35:26Z after the death-gate review. Then two
failure modes in one run: the active role's BackupSchedule arrived in the
same Argo sync as the activation Restore, and the operator **ignored the
restore** ("This resource is ignored because BackupSchedule resource
schedule-acm is currently active"); the premature schedule then
immediately wrote hub-y's **passive state over the bucket's `latest`**,
so a re-run restore "succeeded" restoring nothing. hub-x rebooted back
with spoke untouched; revert PR #2 restored the symmetric posture; hub-x's
schedule (selfHeal-recreated after deleting the collision-frozen object)
healed `latest` within a minute. Zero downtime throughout. The fix —
**failover = activation PR-A, then promotion PR-B** — landed as 96c22ab.

**Attempt 2 (18:00–18:15Z) — verified with the two-PR choreography:**

| Clock (UTC) | T+ | Event |
| --- | --- | --- |
| 18:00:12 | 0:00 | hub-x killed (scheduled reboot; API dead 18:01:28) |
| 18:01:51 | 1:39 | `REVISION v5` committed+pushed, no hub alive (served by spoke ~3 min later) |
| 18:02:09 | 1:57 | **PR-A merged** (activation-only; death-gate evidence in review comment) |
| 18:02:14 | 2:02 | hub-y's Argo synced (refresh annotation): passive Restore pruned — but the activation one-shot was evaluated first and permanently ignored (V1 race, "only one Restore honored at a time") |
| 18:07:58 | 7:46 | V1 recovery: ignored one-shot deleted; selfHeal re-created it in 6 s |
| 18:08:09 | 7:57 | restore `Finished`; **spoke `Joined/Available` on hub-y** (pointer flip 18:08:11 — delete→claim 11 s) |
| 18:09:05 | 8:53 | **promotion PR-B merged** → BackupSchedule; first full set `Completed` (18:09:54) |
| 18:09:29 | 9:17 | **demote PR merged while hub-x still down** |
| 18:13:29 | — | returned hub's Argo pruned its stale schedule before it fired anything (V3 benign); passive restore `Enabled` 18:13:39 |
| 18:14:06 | — | G.3/G.5 residue on hub-x; 18:14:53 [MSA token](msa-token-hygiene.md) re-mint on hub-y (third consecutive reproduction — it is systematic) |

- **Availability: zero non-200s** in both probe logs (pull and push apps)
  across both attempts — two hub deaths, no workload blip.
- **The machinery is tens of seconds; the audit trail is the cost.**
  Merge→sync ≈5 s (refresh annotation), restore→claim 11 s. Attempt 2's
  6-minute merge→claim wall clock was V1 *detection and recovery* — now a
  documented 30-second runbook step (delete the ignored one-shot; never
  hand-apply).
- Verdict details: [dr/README.md](../../dr/README.md) verification ledger
  (V1 falsified→fixed, V3 benign, V4 measured; V5 open until hub-y's
  next demote).
