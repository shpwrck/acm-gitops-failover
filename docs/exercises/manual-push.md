# Manual Push Path — exercise record (verified live, 2026-08-13)

Manual failover with the push app under test (ACTIVE=hub-y, PASSIVE=hub-x),
run 18:30–18:40Z, driven by the
[`dr-failover-push-manual` runbook](../runbooks/dr-failover-push-manual/README.md):

| Clock (UTC) | Event |
| --- | --- |
| 18:30:19 | pre-flight 0.3 gate: credentials set newer than the [MSA token fix](msa-token-hygiene.md) `Completed` — the fix's protection lag was 15.5 min, the RPO number live |
| 18:30:38 | hub-y killed (self-recovering variant); API dead 18:31:57 |
| 18:32:15 | **C' inverted teaching moment**: push `v2` + pull `v6` committed, no active hub — push RTO clock starts |
| 18:32:26 | D.0 break-glass on hub-x (suspend `dr-role`) — D.1's delete then held (no 6 s selfHeal resurrection) |
| 18:32:53 | D.2 manual activation applied → spoke `Joined/Available` on hub-x 18:33:03 (**10 s**, pointer flip same second) |
| 18:34:37 | MSA token re-minted ([MSA hygiene](msa-token-hygiene.md)), GitOps cluster secret re-minted (1→2) |
| 18:34:48 | pull route serves `v6` — ordinary poll latency, zero outage term |
| 18:35:08 | push app `Synced`, **route serves `v2` — push delivery RTO 2 min 53 s** |
| 18:35:41 | F.1 schedule on hub-x; first set `Completed` immediately (fresh token captured) |
| 18:36:43 | hub-y returns (~4.8 min down), stale `spoke True/True`, dr-role reasserting active |
| 18:37:34 | operator-at-return break-glass: hub-y's `dr-role` suspended before touching role objects |
| 18:39:06 / 18:39:16 | spoke lease expires (`Unknown`) / **`BackupCollision` freezes hub-y's schedule — third observation, froze before writing a byte** |
| 18:39:28–18:40:04 | G.2/G.3/G.4/G.5 residue; hub-y passive-sync `Enabled` |
| be20031 | git re-aligned to manual reality (D.0 afterwards-contract), both dr-roles re-enabled — **adoption verified** (object creation timestamps preserved) |

- **The number the path exists for:** push delivery RTO **2:53** =
  operator decision latency (38 s) + activation (10 s) + MSA/cluster-secret
  chain (~95 s) + appset sync and push (~30 s). The pull app's same-window
  "RTO" was its ~2.5 min poll — structurally zero outage contribution. In a
  real disaster the operator term dominates: pull stays flat while push
  grows with every minute of decision time.
- **Both apps served continuously** — the push app's Argo dying uninstalls
  nothing (customers doubt this; the probe log is the receipt).
- The E' resurrection chain was observed strictly ordered: MSA token →
  cluster secret → app sync → route flip; [MSA
  hygiene](msa-token-hygiene.md) stays FIRST (the
  push credential is the same MSA family).
