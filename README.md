# ACM & OpenShift GitOps hub failover

A working reference for surviving the loss of a Red Hat Advanced Cluster
Management (ACM) hub when workloads are delivered by OpenShift GitOps
(Argo CD). Two hubs run active/passive, replicating hub state through
ACM backup and restore on a shared S3 bucket; workloads come from git.
The repo carries the manifests to build it, runbooks to fail over, and
the measured results of running every procedure live on ACM 2.17.

It covers the full matrix of how workloads are **delivered** (each
cluster pulls from git, or the hub's Argo CD pushes) and how a failover
is **operated** (an operator with a runbook, or a pull request whose
review is the split-brain gate).

## Architecture

```mermaid
flowchart TB
    git[("Git repository (this repo)")]
    subgraph hubx["hub-x (active)"]
        hubargo["Argo CD: ApplicationSets, dr-role"]
        schedule["BackupSchedule"]
    end
    s3[("S3 bucket (ACM backups)")]
    subgraph huby["hub-y (passive)"]
        hubyargo["Argo CD: dr-role"]
        restore["Restore (continuous sync)"]
    end
    subgraph spoke["spoke (workload cluster)"]
        klusterlet["klusterlet"]
        localargo["Local Argo CD"]
        apps["hello-failover apps"]
    end
    git -.->|"DR role: dr/hub-x"| hubargo
    git -.->|"DR role: dr/hub-y"| hubyargo
    git -->|"pull model: the spoke syncs itself"| localargo
    schedule -->|"backup every 30 min"| s3
    s3 -->|"restore passive data"| restore
    hubargo -->|"push model, via cluster-proxy"| apps
    localargo --> apps
    klusterlet -->|"registered to"| hubx
```

When hub-x dies, the workloads keep running. Failover activates hub-y's
restore: it claims the spoke (ManagedServiceAccount auto-import re-points
the klusterlet), takes over backups, and resumes push delivery. The pull
app never stops deploying, because the spoke syncs from git on its own.
The two hubs never talk to each other; the bucket is their only shared
state. Why it is built this way, and why there is deliberately no fully
automatic failover, is in [docs/design.md](docs/design.md).

## The four paths

| Delivery | Operation | Runbook | Result |
| --- | --- | --- | --- |
| Pull | Manual | [dr-failover-pull-manual](docs/runbooks/dr-failover-pull-manual/README.md) | Spoke re-homed 10–39 s after activation; deploys land with no hub alive; zero downtime |
| Pull | Git-driven (PR) | [dr-failover-pull-gitops](docs/runbooks/dr-failover-pull-gitops/README.md) | Two-PR choreography (the one-PR flip was falsified live); merge to claim 20–72 s; zero downtime |
| Push | Manual | [dr-failover-push-manual](docs/runbooks/dr-failover-push-manual/README.md) | Push delivery down until the new hub pushes: RTO 2:53–4:59; the app kept serving throughout |
| Push | Git-driven (PR) | [dr-failover-push-gitops](docs/runbooks/dr-failover-push-gitops/README.md) | Push RTO 2:45–4:11, faster than the manual push run on the same day; the PR history is the audit log |

Start with the Manual Pull Path: the other three runbooks are written as
deltas against it. Timings, conditions and the findings behind each
runbook step are in [docs/results.md](docs/results.md).

## Getting started

You need three OpenShift clusters (two that can run ACM 2.17 as hubs, and
one workload cluster; this repo was verified on OpenShift 4.21, so check
the ACM support matrix for other versions), an S3-compatible bucket both
hubs can reach, and a git repository every cluster can reach.

1. **Fork or copy this repo** and change the values below to match your
   environment.
2. **Build the environment** by following [docs/build.md](docs/build.md):
   it applies `manifests/` in numbered order and bootstraps `dr/`.
3. **Run a failover** with one of the runbooks above.

| Value | Where it is set | Default here |
| --- | --- | --- |
| Git repository URL | `repoURL` in `manifests/62-appset-pull.yaml`, `manifests/63-appset-push.yaml`, `dr/bootstrap/dr-role-hub-*.yaml` (CI fails if they disagree) | `https://github.com/redhat-na-ssa/acm-gitops-failover` |
| S3 endpoint, bucket, prefix, region | `manifests/50-dpa.yaml` | `https://s3.example.com`, `acm-backups`, `acm`, `us-east-1` |
| Workload cluster name | `manifests/40-import-spoke.yaml` and the `name: spoke` selector in `manifests/61-gitops-integration.yaml` | `spoke` |
| Hub names | `dr/hub-x/`, `dr/hub-y/` and `dr/bootstrap/dr-role-hub-{x,y}.yaml` (directory name and `path` must match) | `hub-x`, `hub-y` |
| kubeconfig contexts | the `export` lines at the top of each runbook | `hub-x`, `hub-y`, `spoke` |
| Hub replica mode | `availabilityConfig` in `manifests/20-multiclusterhub.yaml` | `Basic` (single-node hubs) |

## Repository layout

```
manifests/   every hub-side CR, numbered in apply order (docs/build.md)
apps/        the demo apps: hello-failover (pull) and hello-failover-push (push)
dr/          git-driven DR roles: one overlay per hub, the active/passive
             roles, the activation template, and the per-hub bootstrap
docs/        design, build, results, runbooks
hack/        validation scripts used locally and by CI
```

## Validation

`hack/validate.sh` checks everything that can be checked without
clusters, and runs on every pull request
([.github/workflows/validate.yaml](.github/workflows/validate.yaml)):

- yamllint, and `kustomize build` of every `dr/` overlay and role;
- strict schema validation of every manifest against the upstream CRDs
  for ACM 2.17, OADP, Argo CD, OLM and OpenShift routes, so a misspelled
  field fails;
- the repo's own invariants: the manual (`manifests/`) and git-driven
  (`dr/`) copies of each DR object are identical, both `dr-role`
  Applications keep their backup-exclusion label, each hub overlay
  renders a legal role, and every Argo source names the same repo;
- relative links in the docs resolve, and every Mermaid diagram renders.

It needs python3 with PyYAML, yamllint, kubeconform, kustomize (or
kubectl) and, for the diagram check, `mmdc` from
`@mermaid-js/mermaid-cli`. Live behavior can only be proven on clusters:
that is what the runbooks' exercises and [docs/results.md](docs/results.md)
are for.

## Documents

| Document | What it holds |
| --- | --- |
| [docs/design.md](docs/design.md) | The two-layer design, the delivery models, the four-path comparison, sources |
| [docs/build.md](docs/build.md) | Prerequisites, versions, the build in apply order, build-time gotchas |
| [docs/runbooks/](docs/runbooks/) | The four operator runbooks: command, rationale, success and failure for every step |
| [dr/README.md](dr/README.md) | How the git-driven DR roles work, and why failover takes two pull requests |
| [docs/results.md](docs/results.md) | Measured results and the findings behind the runbook steps |
| [docs/msa-token-hygiene.md](docs/msa-token-hygiene.md) | Why every activation needs the MSA token cleanup |
