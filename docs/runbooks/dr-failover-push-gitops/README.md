# Automated Push Path — DR exercise runbook: GitOps operation, push delivery

**Status: EXERCISE VERIFIED LIVE 2026-08-13 18:43–18:53Z**
([exercise record](../../exercises/automated-push.md), run after both parents'
exercises the same day). **Measured push
delivery RTO: 2 min 45 s** — the composed path BEAT the Manual Push
Path's 2:53 because the PR flow's decision-to-claim (28 s, V1 recovery
included) undercut the manual path's operator latency; the audit trail
cost nothing. V3's boot race was observed in the collision-first order
(collision 18:51:30Z → prune 18:51:41Z), completing both orders across
the automated paths. This path is a COMPOSITION:
run the [Automated Pull Path runbook](../dr-failover-gitops/README.md) (git-driven
role flip) with the [Manual Push Path runbook](../dr-failover-push-manual/README.md)
delivery checks layered in. Only the interplay is documented here —
everything else is deliberately NOT duplicated, so the composed runbooks
can't drift.

## Prerequisites

The Automated Pull Path's Phase P (dr-role bootstrap + backup-exclusion
check) AND the Manual Push Path's Phase P (push appset + discovered
RBAC). Both must have passed their
own verification exercises first — do not run this path as the first live
test of either mechanism; a composed failure is twice as hard to
attribute.

## The composed exercise

| Phase | Take from | Layer in |
| --- | --- | --- |
| 0/A | Automated Pull Path (pre-flight + dr-role check) | Manual Push Path's second probe (push app) |
| B | Manual Pull Path (kill + death gate) | — |
| C | Manual Push Path C' (push deploy does NOT land; timestamp it) | pull deploy DOES land (Manual Pull Path C) — same window |
| D | Automated Pull Path D' (failover PR; review = death gate; merge = decision) | — |
| E | Manual Pull Path E + [MSA hygiene](../../exercises/msa-token-hygiene.md) FIRST | Manual Push Path E' (delivery resurrection; measure delivery RTO) |
| F | Automated Pull Path (F.1 automatic via role flip) | Manual Push Path's appset/secret checks |
| G | Automated Pull Path G' (demote PR + imperative residue) | — |
| H | evidence + V-verdicts | the four-path comparison row (below) |

## Interplay notes (what is unique to this path)

- **Delivery RTO gains the operation's latency.** The Manual Push Path
  measures activation→first-push; this path adds merge→sync ahead of it
  (the Automated Pull Path's V4 delta). Expected total: PR merge + Argo poll (≤3 min, refresh cuts it)
  + ≈10 s machinery + secret re-mint + first push. This is the
  slowest-to-recover cell of the matrix — and the most auditable. Say
  both sentences together; that's the trade.
- **Two Argo populations, opposite DR treatments, same namespace.** On
  each hub's `openshift-gitops`: the push ApplicationSet MUST ride the
  backup/restore (that's how delivery fails over), while `dr-role` MUST
  NOT (that's how split-brain is prevented). The exclusion label is doing
  precision work here — the Automated Pull Path's P.2 check is mandatory
  pre-flight in this path, every time.
- **One [MSA token](../../exercises/msa-token-hygiene.md) chain, three
  dependents.** After activation, the repaired
  token feeds auto-import (the Manual Pull Path's claim machinery),
  the GitOpsCluster secret (push delivery), and the next backup. E's
  hygiene step is therefore ordered FIRST in this path — before judging
  any delivery failure as a defect of this path, confirm
  `TokenReported: True`.

## H — the deliverable

The four-path comparison table (README, "The four paths") gets its final column filled
from this run: identical outage, four measured recoveries. That artifact
— not any single path — is the reason the repo holds all four.
