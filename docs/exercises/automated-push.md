# Automated Push Path — exercise record (verified live, 2026-08-13)

The full composition — git-driven operation with push delivery under
measurement (ACTIVE=hub-x, PASSIVE=hub-y), run 18:43–18:53Z, closing the
2×2:

| Clock (UTC) | Event |
| --- | --- |
| 18:43:48 | hub-x killed (self-recovering variant); API dead 18:45:06 |
| 18:45:11 | push `v3` (RTO clock) + pull `v7` committed, no active hub |
| 18:45:31 | **PR-A merged** (death-gate evidence in review) |
| 18:45:37 | V1 race detected in 6 s (`ignored … passive-sync currently active`) — now a routine step |
| 18:45:48→59 | recovery delete → selfHeal re-run → **spoke `True/True` on hub-y; merge→claim 28 s total** |
| 18:46:54 | [MSA token](msa-token-hygiene.md) + cluster-secret re-mint (fourth consecutive reproduction) |
| 18:47:56 | **push route serves `v3` — delivery RTO 2 min 45 s**, beating the Manual Push Path's 2:53 |
| 18:48:30 / 18:48:38 | promotion PR-B merged (first backup set `Completed` 18:48:42) / demote PR merged, hub-x still down |
| 18:51:30→41 | returned hub-x: **`BackupCollision` first, prune 10 s later** — V3's other order, benign both ways across the automated paths |
| 18:52:11 / 18:52:41 | spoke `Unknown` on hub-x / pull `v7` serving (one slow ~7.5 min poll cycle — jitter, not outage) |
| 18:53:00 | G.3 stale-claim delete — posture symmetric: hub-y ACTIVE, hub-x PASSIVE |

- **The matrix's slowest cell beat its manual sibling**: PR merge→claim
  took 28 s (V1 recovery included), less than the Manual Push Path's 38 s operator
  typing latency — so the audit trail was free. In a real disaster the
  decision dominates both, and the PR *is* the decision record.
- Probe verdict for the whole day — the [reverse
  exercise](manual-pull.md) plus three exercises, four hub
  deaths: **zero non-200 responses on either app** (710+ samples each).

## Re-verified 2026-08-18

The composed exercise re-run end-to-end (hub-x active → hub-y
activated) by an operator with no prior context — closing the matrix a
second time, in a single day, with all four cells re-verified and the
lab ending in the posture the day started with. Zero non-200s on both
apps (92 samples each).

- **Push delivery RTO 4:11** — beating the same-day manual sibling's
  4:59, just as the 2026-08-13 pair did at 2:45 vs 2:53. The
  "audit-trail-is-free" claim held within each same-day pair; absolute
  numbers vary run to run (this one includes ~60 s of PR decision
  latency, the ~29 s V1 recovery, and ~59 s of route content
  propagation — the decomposition now in the runbook's interplay note).
- Merge→claim ≈50 s including the V1 recovery (the race fired on the
  first sync tick, exactly as documented; recovery 29 s).
- PR-B merge → schedule `Enabled` + first full set `Completed` within
  32 s. Demote PR → returned hub healed 9 s after refresh —
  **prune-first this time; `BackupCollision` never fired**, though the
  returned hub landed one boot catch-up backup set in the ~4 min before
  the demote merged: the two-writer window the guard does not close
  instantly (benign here; the new active's newer set won `latest`).
- The [MSA token freeze](msa-token-hygiene.md) reproduced again — this
  time with the `TokenReported` condition entirely ABSENT rather than
  `False`; same signature (restored secret without `ownerReferences`),
  same fix, re-mint in the same second.
