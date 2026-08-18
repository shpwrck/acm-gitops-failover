# Automated Push Path — DR exercise runbook: GitOps operation, push delivery

This path is a COMPOSITION:
run the [Automated Pull Path runbook](../dr-failover-pull-gitops/README.md) (git-driven
role flip) with the [Manual Push Path runbook](../dr-failover-push-manual/README.md)
delivery checks layered in. Only the interplay is documented here —
everything else is deliberately NOT duplicated, so the composed runbooks
can't drift. The measured run is the
[exercise record](../../exercises/automated-push.md).

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
| F | Automated Pull Path F' (promotion PR-B) | Manual Push Path's appset/secret checks |
| G | Automated Pull Path G' (demote PR + imperative residue) | — |
| H | evidence + V-verdicts | the four-path comparison row (below) |

## Interplay notes (what is unique to this path)

- **Delivery RTO gains the operation's latency.** The RTO clock starts
  at the C' commit, not at the merge — the decision latency (author,
  review, merge: ~1 min) is inside the measured number. Expected
  components, each observed live: decision latency + merge→sync
  (refresh cuts the ≤3 min poll to seconds) + the V1 recovery when it
  fires (~30 s — D' treats it as the expected first outcome) + ≈10 s
  claim machinery + cluster-secret re-mint (~1 min) + first push
  (~30 s) + route content propagation (~1 min). This is the
  slowest-to-recover cell of the matrix — and the most auditable. Say
  both sentences together; that's the trade.
- **Two Argo populations, opposite DR treatments, same namespace.** On
  each hub's `openshift-gitops`: the push ApplicationSet MUST ride the
  backup/restore (that's how delivery fails over), while `dr-role` MUST
  NOT (that's how split-brain is prevented). The exclusion label is doing
  precision work here — the Automated Pull Path's P.2 check is mandatory
  pre-flight in this path, every time.
- **One [MSA token](../../exercises/msa-token-hygiene.md) family, three
  dependents.** After activation, MSA tokens feed auto-import (the
  Manual Pull Path's claim machinery), the GitOpsCluster secret (push
  delivery — via the separate `application-manager` MSA, which the
  addon re-mints on its own), and the next backup. E's
  hygiene step is ordered FIRST as triage discipline — delivery usually
  resurrects regardless (verified, with timestamps) — but before
  judging any delivery failure as a defect of this path, confirm
  `TokenReported: True`.
- **Cross-path residue.** The demote PR's prune reaps only
  Argo-tracked one-shots. If the hub being demoted was last activated
  MANUALLY, its fixed-name `restore-acm-activate` is untracked — delete
  it by hand during G (verified live), or the next manual activation on
  that hub silently no-ops.

## H — the deliverable

The four-path comparison table (README, "The four paths") is this
exercise's deliverable: identical outage, four measured recoveries. The
measured numbers — and which sibling "wins" — vary run to run; keep the
table's Verdict column tied to the run it cites. That artifact
— not any single path — is the reason the repo holds all four.
