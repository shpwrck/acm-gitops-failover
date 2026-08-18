# ACM & OpenShift GitOps Failover

This repo describes how to handle failover of an ACM hub with
GitOps-delivered workloads, across the full matrix of workload delivery
(pull or push) and failover operation (manual runbook or pull request).
Hub state is replicated active/passive with backup-restore through a
shared S3 bucket; workloads are delivered by GitOps; this repo can
drive all four modes independently.

This README is the map. The design rationale, build record, exercise
records, and operator runbooks each live in their own document below.

## Environment

| Cluster | API | Shape | Role |
| --- | --- | --- | --- |
| hub-x | api.hub-x.example.com | SNO, OCP 4.21 | ACM 2.17.0 hub |
| hub-y | api.hub-y.example.com | SNO, OCP 4.21 | ACM 2.17.0 hub |
| spoke | api.spoke.example.com | SNO, OCP 4.21 | workload cluster |

The hub roles are interchangeable: failover can swap them back and
forth without any additional cleanup or reset in between.

## The four paths

Failover can be *operated* two ways — an operator with a runbook, or a
pull request whose review is the split-brain gate — and workloads can be
*delivered* two ways — each cluster pulls from git, or the hub's Argo
pushes. All four combinations are verified:

| Delivery | Operation | Runbook | Record | Verdict |
| --- | --- | --- | --- | --- |
| Pull | Manual | [dr-failover-exercise](docs/runbooks/dr-failover-exercise/README.md) | [exercise record](docs/exercises/manual-pull.md) | verified both directions: ≈10 s re-home, zero downtime, deploys land mid-outage |
| Pull | Git-driven (PR) | [dr-failover-gitops](docs/runbooks/dr-failover-gitops/README.md) | [exercise record](docs/exercises/automated-pull.md) | two-PR choreography (one-PR flip falsified live); merge→claim ≈20 s; zero downtime |
| Push | Manual | [dr-failover-push-manual](docs/runbooks/dr-failover-push-manual/README.md) | [exercise record](docs/exercises/manual-push.md) | push delivery RTO 2:53 vs pull's ~2.5 min poll-only; app stayed up throughout |
| Push | Git-driven (PR) | [dr-failover-push-gitops](docs/runbooks/dr-failover-push-gitops/README.md) | [exercise record](docs/exercises/automated-push.md) | push RTO 2:45 — the PR beat the manual sibling (merge→claim 28 s); audit trail free |

Why the halves differ — and why there is deliberately **no fifth,
fully-autonomous path** — is argued in [docs/design.md](docs/design.md).

## Where everything lives

| Document | What it holds |
| --- | --- |
| [docs/design.md](docs/design.md) | The two-layer design, the four-path comparison, primary sources |
| [docs/build.md](docs/build.md) | The verified build: second hub, S3 store, backup layer + GitOps wiring |
| [docs/exercises/](docs/exercises/) | Per-path exercise records: timelines, findings, measured RTOs |
| [dr/](dr/README.md) | Git-driven DR roles (the automated paths): mechanism, two-PR rationale, verification ledger |
| [research-notes.md](research-notes.md) | Annotated bibliography — every documentation claim with its exact anchor |

## Repo layout

- `manifests/` — every CR, numbered in apply order
- `apps/` — the demo apps (`hello-failover` pull, `hello-failover-push` push)
- `dr/` — per-hub DR role overlays + bootstrap, reconciled by each hub's own Argo
- `backups/` — pre-deletion copies of removed relic CRDs
- `docs/` — the documents and runbooks above
