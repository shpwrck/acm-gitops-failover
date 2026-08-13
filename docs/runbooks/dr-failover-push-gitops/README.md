# Path 4 — DR exercise runbook: GitOps operation, push delivery

**Status: EXERCISE VERIFIED LIVE 2026-08-13 18:43–18:53Z** (README §3.7,
run after both parents' exercises the same day). **Measured push
delivery RTO: 2 min 45 s** — the composed path BEAT manual path 3's
2:53 because the PR flow's decision-to-claim (28 s, V1 recovery
included) undercut the manual path's operator latency; the audit trail
cost nothing. V3's boot race was observed in the collision-first order
(collision 18:51:30Z → prune 18:51:41Z), completing both orders across
paths 2 and 4. This path is a COMPOSITION:
run the [path-2 runbook](../dr-failover-gitops/README.md) (git-driven
role flip) with the [path-3 runbook](../dr-failover-push-manual/README.md)
delivery checks layered in. Only the interplay is documented here —
everything else is deliberately NOT duplicated, so the composed runbooks
can't drift.

## Prerequisites

Path 2's Phase P (dr-role bootstrap + backup-exclusion check) AND path
3's Phase P (push appset + discovered RBAC). Both must have passed their
own verification exercises first — do not run path 4 as the first live
test of either mechanism; a composed failure is twice as hard to
attribute.

## The composed exercise

| Phase | Take from | Layer in |
| --- | --- | --- |
| 0/A | path 2 (pre-flight + dr-role check) | path 3's second probe (push app) |
| B | path 1 (kill + death gate) | — |
| C | path 3 C' (push deploy does NOT land; timestamp it) | pull deploy DOES land (path 1 C) — same window |
| D | path 2 D' (failover PR; review = death gate; merge = decision) | — |
| E | path 1 E + §3.3 hygiene FIRST | path 3 E' (delivery resurrection; measure delivery RTO) |
| F | path 2 (F.1 automatic via role flip) | path 3's appset/secret checks |
| G | path 2 G' (demote PR + imperative residue) | — |
| H | evidence + V-verdicts | the four-path comparison row (below) |

## Interplay notes (what is unique to path 4)

- **Delivery RTO gains the operation's latency.** Path 3 measures
  activation→first-push; path 4 adds merge→sync ahead of it (path 2's V4
  delta). Expected total: PR merge + Argo poll (≤3 min, refresh cuts it)
  + ≈10 s machinery + secret re-mint + first push. This is the
  slowest-to-recover cell of the matrix — and the most auditable. Say
  both sentences together; that's the trade.
- **Two Argo populations, opposite DR treatments, same namespace.** On
  each hub's `openshift-gitops`: the push ApplicationSet MUST ride the
  backup/restore (that's how delivery fails over), while `dr-role` MUST
  NOT (that's how split-brain is prevented). The exclusion label is doing
  precision work here — path 2's P.2 check is mandatory pre-flight in
  this path, every time.
- **One §3.3 chain, three dependents.** After activation, the repaired
  MSA token feeds auto-import (path 1), the GitOpsCluster secret (push
  delivery), and the next backup. E's hygiene step is therefore ordered
  FIRST in this path — before judging any delivery failure as a path-4
  defect, confirm `TokenReported: True`.

## H — the deliverable

The four-path comparison table (README §4) gets its final column filled
from this run: identical outage, four measured recoveries. That artifact
— not any single path — is the reason the repo holds all four.
