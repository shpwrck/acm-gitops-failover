# ACM & OpenShift GitOps Failover

What losing an ACM hub costs, and how to get it back — proven live, not
argued. Hub state rides active/passive backup-restore through a shared
S3 bucket; workloads ride pull-model GitOps straight from git; the hubs
never talk to each other. Everything in this repo was run against a
real three-cluster lab on 2026-08-12/13: every command executed, every
timing observed, and all four cells of the delivery × operation matrix
closed with live measurements.

This README is the map. The design rationale, build record, exercise
evidence, and operator procedures each live in their own document below.

## Environment

| Cluster | API | Shape | Role |
| --- | --- | --- | --- |
| hub-x | api.hub-x.k8socp.com | SNO, OCP 4.21 | ACM 2.17.0 hub — currently **passive** |
| hub-y | api.hub-y.k8socp.com | SNO, OCP 4.21 | ACM 2.17.0 hub — currently **active** (manages spoke) |
| spoke | api.spoke.k8socp.com | SNO, OCP 4.21 | workload cluster (pull-model GitOps) |

Roles are symmetric and have swapped in every exercise; the standing
posture, with its verify and recover blocks, is the
[posture runbook](docs/runbooks/acm-active-passive-dr/README.md).

**Naming.** Clusters are referred to generically: `hub-x` and `hub-y`
are the two ACM hubs, `spoke` is the workload cluster. The committed
lab files predate the rename and keep the original names — `dr/hub/`
is hub-x's role overlay, `dr/spoke/` is hub-y's,
`manifests/40-import-sage.yaml` imports spoke, and the runbook
directory `spoke-acm-hub` is hub-y's build record. Command outputs in
the docs are the real recorded outputs with only the cluster names
substituted.

## The four paths

Failover can be *operated* two ways — an operator with a runbook, or a
pull request whose review is the split-brain gate — and workloads can be
*delivered* two ways — each cluster pulls from git, or the hub's Argo
pushes. All four combinations are verified; the records live in
[docs/exercises.md](docs/exercises.md):

| Path | Delivery | Operation | Runbook | Record | Verdict |
| --- | --- | --- | --- | --- | --- |
| 1 | Pull | Manual | [dr-failover-exercise](docs/runbooks/dr-failover-exercise/README.md) | §3, §3.4 | verified both directions: ≈10 s re-home, zero downtime, deploys land mid-outage |
| 2 | Pull | Git-driven (PR) | [dr-failover-gitops](docs/runbooks/dr-failover-gitops/README.md) | §3.5 | two-PR choreography (one-PR flip falsified live); merge→claim ≈20 s; zero downtime |
| 3 | Push | Manual | [dr-failover-push-manual](docs/runbooks/dr-failover-push-manual/README.md) | §3.6 | push delivery RTO 2:53 vs pull's ~2.5 min poll-only; app stayed up throughout |
| 4 | Push | Git-driven (PR) | [dr-failover-push-gitops](docs/runbooks/dr-failover-push-gitops/README.md) | §3.7 | push RTO 2:45 — the PR beat the manual sibling (merge→claim 28 s); audit trail free |

Why the halves differ — and why there is deliberately **no fifth,
fully-autonomous path** — is argued in [docs/design.md](docs/design.md).

## Where everything lives

| Document | What it holds |
| --- | --- |
| [docs/design.md](docs/design.md) | The two-layer design, the four-path comparison, primary sources |
| [docs/build.md](docs/build.md) | The verified build: second hub, S3 store, backup layer + GitOps wiring |
| [docs/exercises.md](docs/exercises.md) | Exercise records §3–§3.7: timelines, findings, measured RTOs |
| [dr/](dr/README.md) | Git-driven DR roles (paths 2/4): mechanism, two-PR rationale, verification ledger |
| [research-notes.md](research-notes.md) | Annotated bibliography — every documentation claim with its exact anchor |

Runbooks — operator scripts, command / rationale / success / failure
per step:

| Runbook | Scope |
| --- | --- |
| [dr-failover-exercise](docs/runbooks/dr-failover-exercise/README.md) | Path 1: the full manual exercise — the spine the other paths delta against |
| [dr-failover-gitops](docs/runbooks/dr-failover-gitops/README.md) | Path 2: failover as two pull requests |
| [dr-failover-push-manual](docs/runbooks/dr-failover-push-manual/README.md) | Path 3: manual failover with push delivery under measurement |
| [dr-failover-push-gitops](docs/runbooks/dr-failover-push-gitops/README.md) | Path 4: the composition of paths 2 + 3 |
| [acm-active-passive-dr](docs/runbooks/acm-active-passive-dr/README.md) | The standing posture: state, template map, verify and recover |
| [spoke-acm-hub](docs/runbooks/spoke-acm-hub/README.md) | How hub-y became a standalone ACM hub |
| [truenas-seaweedfs-s3](docs/runbooks/truenas-seaweedfs-s3/README.md) | The lab's S3-compatible backup store |

## Repo layout

- `manifests/` — every CR, numbered in apply order
- `apps/` — the demo apps (`hello-failover` pull, `hello-failover-push` push)
- `dr/` — per-hub DR role overlays + bootstrap, reconciled by each hub's own Argo
- `backups/` — pre-deletion copies of removed relic CRDs
- `docs/` — the documents and runbooks above
