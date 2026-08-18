# Failover design

Why the architecture looks the way it does: two independent layers, so
that losing the management hub costs neither workloads nor — with the
right delivery choice — deployments. The verified build steps are in
[build.md](build.md); the live proof is in [exercises/](exercises/).

## Two layers

## Phase 2 — Failover design

The design follows the pattern the public sources converge on — two layers:

- **Hub state: active/passive backup-restore.** This is Red Hat's
  productized hub-DR architecture: one primary, N passive hubs continuously
  restoring from shared S3-compatible storage, deliberate manual failover.
  Documented in the ACM Business Continuity guide (["Configuring
  active-passive hub
  cluster"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#active-passive-config),
  ["Disaster
  recovery"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#disaster-recovery))
  and the [RHACM high availability and disaster recovery blog series
  (part 1)](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-1)
  ([part 2](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-2),
  [part 3](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-3),
  and the [backup-and-restore hub clusters
  blog](https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes)).
  Because this lab's clusters are *imported* (not Hive-created),
  [**ManagedServiceAccount auto-import** is effectively
  mandatory](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-imported-managed-clusters)
  (`useManagedServiceAccount: true`) — [without it every failover ends in
  `Pending Import`](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#auto-connect-clusters-msa).
- **Workloads: git as source of truth, pull-model GitOps.** Even Red Hat's
  [pull-model announcement
  blog](https://www.redhat.com/en/blog/introducing-the-argo-cd-application-pull-controller-for-red-hat-advanced-cluster-management)
  concedes "the hub cluster itself still represents a potential single
  point of failure" — so workloads must not depend on any hub. With the
  [pull-model
  architecture](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#arch-pull),
  each managed cluster's local Argo CD syncs from git independently; hub
  loss stops only propagation of *new* ApplicationSet decisions and status
  aggregation. Argo CD itself [never prunes without explicit
  `prune: true`](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/),
  and [its state is rebuildable from
  git](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/).
- The two layers composed are exactly Red Hat's November 2025 reference:
  [Argo CD Disaster Recovery strategy using RHACM and
  OADP](https://www.redhat.com/en/blog/argo-cd-disaster-recovery-strategy-using-red-hat-advanced-cluster-management-and-oadp).

The Phase 1 observation is the load-bearing argument for the second layer:
anything delivered by hub addons dies with the hub relationship, while
GitOps-delivered state is cluster-local and survives. Hub backup/restore
protects only the hub's *own* state (cluster inventory, policies,
placements, the GitOps wiring itself).

## The four paths

The repo carries the full 2×2 of delivery model × DR operation — all
four cells verified live ([exercise records](exercises/); the summary
table is in the [README](../README.md)). How
the halves differ, in one line each:

- **Pull vs push** is *what a hub outage costs delivery*: nothing (spoke
  syncs git itself — proven in every exercise — v2 through v7 all landed hubless) vs a
  delivery outage lasting until the new hub's Argo resumes pushing
  (the Manual Push Path measures it). It is also *what the hub is worth to an
  attacker*: push runs on an ACM-minted credential whose managed-cluster
  SA is cluster-admin-equivalent (verified — Manual Push Path runbook P.2), so a
  compromised hub Argo is admin on every cluster it pushes to; pull
  keeps the hub credential-free for delivery and the app's RBAC
  namespace-scoped.
- **Manual vs git-driven** is *what a failover decision looks like*: an
  operator with a runbook (≈10 s of machinery after seconds of typing)
  vs a pull request whose review is the split-brain gate and whose merge
  history is the audit log (expected cost: + merge + Argo poll; measured
  by the Automated Pull Path's V4).

Why there is no fifth, fully-autonomous path: hub failover is
deliberately a human decision. A passive-side monitor cannot distinguish
"active hub died" from "network partition," and with MSA auto-import an
activation actively re-points the fleet's klusterlets — automating a
false positive moves the fleet onto a second live hub. `BackupCollision`
guards the bucket, not cluster claims; going autonomous safely requires a
quorum witness/fencing, and the architecture has already made hub
downtime cheap (workloads run and — on pull — deploy hubless). Automate
the detection, the pre-flight, and the execution; keep the decision
human. The automated paths' PR gate is exactly that boundary drawn in git.

Delivery infrastructure shared by the push paths:
[manifests/63-appset-push.yaml](../manifests/63-appset-push.yaml) +
[apps/hello-failover-push/](../apps/hello-failover-push/) (separate
namespace — both models coexist through one outage). Role-flip
infrastructure for the automated paths: [dr/](../dr/README.md).

## Sources

Primary documentation (ACM 2.17; every claim above links to its exact
section — the annotated fact-by-fact bibliography with anchors is in
[research-notes.md](../research-notes.md)):

- [Business continuity (backup/restore, active-passive, disaster recovery)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index)
- [Clusters (import, detach, cleanup procedures)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index)
- [GitOps (GitOpsCluster, push/pull models, gitops addon)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index)
- [Install (MultiClusterHub advanced configuration, sizing)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index)
- [Argo CD: automated sync/prune/self-heal](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/), [cluster bootstrapping (app-of-apps)](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/), [declarative cluster secrets](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters), [disaster recovery](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/)

Red Hat blogs (architecture endorsements):

- [RHACM: High availability and disaster recovery — part 1](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-1), [part 2](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-2), [part 3](https://www.redhat.com/en/blog/rhacm-high-availability-and-disaster-recovery-part-3)
- [Backup and Restore Hub Clusters with RHACM](https://www.redhat.com/en/blog/backup-and-restore-hub-clusters-with-red-hat-advanced-cluster-management-for-kubernetes)
- [Argo CD Disaster Recovery strategy using RHACM and OADP](https://www.redhat.com/en/blog/argo-cd-disaster-recovery-strategy-using-red-hat-advanced-cluster-management-and-oadp) — the composed two-layer architecture this guide implements
- [Introducing the Argo CD Application Pull Controller for RHACM](https://www.redhat.com/en/blog/introducing-the-argo-cd-application-pull-controller-for-red-hat-advanced-cluster-management)
- [Using the Argo CD Agent with OpenShift GitOps](https://developers.redhat.com/blog/2025/10/06/using-argo-cd-agent-openshift-gitops) — the Tech Preview evolution of the pull model
- [stolostron/cluster-backup-operator](https://github.com/stolostron/cluster-backup-operator)
