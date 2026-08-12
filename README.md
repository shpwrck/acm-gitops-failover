# ACM & OpenShift GitOps Failover Guide

Verified live against the `k8socp.com` lab (contexts `hub`, `spoke`, `sage`)
on 2026-08-12. Every command in this guide was actually run; outputs shown are
real. Work in progress — sections are added as they are verified.

## Environment

| Cluster | API | OCP | Shape | Role (before) | Role (after) |
| --- | --- | --- | --- | --- | --- |
| hub | api.hub.k8socp.com | — | — | ACM 2.17.0 hub (`local-cluster` + `spoke` managed) | ACM hub |
| spoke | api.spoke.k8socp.com | 4.21.20 | SNO (1 node, all roles) | ACM managed cluster of hub | standalone ACM 2.17.0 hub |
| sage | api.sage.k8socp.com | — | — | powered off during this exercise | — |

Facts recorded from the live environment before the change:

- `spoke` was imported into hub 33 days ago; klusterlet in **Singleton** mode
  (`deployOption.mode: Singleton`), `clusterName: spoke`, agent namespaces
  `open-cluster-management-agent`, `-agent-addon`, `open-cluster-management-policies`.
- Enabled addons on spoke: `application-manager`, `cert-policy-controller`,
  `config-policy-controller`, `governance-policy-framework`, `klusterlet-addon-search`.
- Hub pushed 13 replicated policies to spoke (`acm-policy-research.*`,
  `rhcl-ossm-policy.*`) — see `~/acm-policy-research` for that demo's runbook.
- OpenShift GitOps is NOT installed on spoke. The `openshift-gitops(-operator)`
  namespaces on spoke exist but are empty shells created by ACM's GitOps addon
  (`apps.open-cluster-management.io/gitopsaddon: "true"` label).
- Spoke catalog offers ACM channels release-2.15/2.16/2.17; hub runs MCH 2.17.0,
  so release-2.17 was chosen for version parity (a hard requirement if ACM
  hub backup/restore is ever used between the two hubs).

## Phase 1 — Make `spoke` a standalone ACM hub

### 1.1 Install the ACM operator (safe while still attached)

Installing the *operator* does not conflict with the klusterlet; only the
`MultiClusterHub` (which self-imports `local-cluster` and would collide with
the existing `klusterlet` CR) must wait until after detach.

```console
$ oc --context spoke apply -f manifests/10-acm-operator.yaml
namespace/open-cluster-management created
operatorgroup.operators.coreos.com/open-cluster-management created
subscription.operators.coreos.com/advanced-cluster-management created
```

Verified: CSV `advanced-cluster-management.v2.17.0` reached `Succeeded` in
~3 minutes.

### 1.2 Detach spoke from the old hub

(placeholder — being executed; clean detach = delete the `ManagedCluster` on
the hub, which deletes the `…-spoke-klusterlet(-crds)` ManifestWorks, and the
work agent uninstalls itself. Verification: klusterlet CR, agent namespaces,
and replicated policies disappear from spoke.)

Detach leaves policy-*created* resources on spoke orphaned but intact
(namespace `acm-policy-demo`: ConfigMap `gated-by-health`, helm release
`demo-hello`, ESO demo objects). This is expected: ConfigurationPolicy does
not prune on detach unless `pruneObjectBehavior` was set.

### 1.3 Create the MultiClusterHub

(placeholder — `manifests/20-multiclusterhub.yaml`, `availabilityConfig:
Basic` because spoke is SNO.)

### 1.4 Verify spoke is a self-managing hub

(placeholder — MCH phase Running, `local-cluster` ManagedCluster
Joined/Available.)

## Phase 2 — Failover design (options under evaluation)

To be written after Phase 1: candidate approaches are
(a) two independent hubs with git as the source of truth (active/active,
GitOps re-targets workloads), (b) ACM cluster-backup-operator + OADP
hub restore (active/passive), (c) manual re-import of managed clusters to
the surviving hub. The choice will be verified live, including what happens
to `sage` as a managed cluster during a hub outage.
