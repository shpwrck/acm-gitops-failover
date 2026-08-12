---
leave-behind: v1
state-scope: spoke-acm-hub
status: current
---

# Spoke standalone ACM hub leave-behind

## Operability

### State and access

Durable state lives on the `spoke` OpenShift cluster (SNO, OCP 4.21.20,
api.spoke.k8socp.com), reached via kubeconfig context `spoke` in
`~/.kube/config` (cluster-admin `kube-admin` credentials embedded there; no
other secret store involved). The former hub is context `hub`
(api.hub.k8socp.com, MCH 2.17.0); `sage` exists but was powered off.

- Spoke, namespace `open-cluster-management`: OperatorGroup
  `open-cluster-management`, Subscription `advanced-cluster-management`
  (channel `release-2.17`, redhat-operators), CSV
  `advanced-cluster-management.v2.17.0` (Succeeded). A `MultiClusterHub`
  named `multiclusterhub` is created here once detach completes
  (`manifests/20-multiclusterhub.yaml`, `availabilityConfig: Basic`).
- Detach from old hub: `ManagedCluster spoke` deleted on `hub` context
  2026-08-12; klusterlet + agent namespaces self-remove on spoke. Until that
  finishes, do NOT create the MultiClusterHub (klusterlet name collision with
  local-cluster self-import).
- Orphaned on spoke by the detach (intentionally left): namespace
  `acm-policy-demo` demo resources formerly enforced by hub policies; see
  `~/acm-policy-research/docs/runbooks/acm-policy-research-demo/README.md`
  (that runbook's "policies enforced on spoke" claims are stale after this
  detach).

### Template map

~/acm-failover-guide/manifests/10-acm-operator.yaml -> spoke ns open-cluster-management + OperatorGroup + Subscription advanced-cluster-management (release-2.17)
~/acm-failover-guide/manifests/20-multiclusterhub.yaml -> spoke MultiClusterHub multiclusterhub in ns open-cluster-management (post-detach)

### Re-run

Prerequisites: context `spoke` reachable with cluster-admin; spoke NOT a
managed cluster of any hub (no `klusterlet` CR).

```bash
oc --context spoke apply -f ~/acm-failover-guide/manifests/10-acm-operator.yaml
# wait for CSV advanced-cluster-management.v2.17.0 = Succeeded, then:
oc --context spoke apply -f ~/acm-failover-guide/manifests/20-multiclusterhub.yaml
```

Both applies are idempotent/convergent. Detach re-run (only if re-attached):
`oc --context hub delete managedcluster spoke` and wait for the klusterlet
and `open-cluster-management-agent*`/`open-cluster-management-policies`
namespaces to disappear from spoke.

### Verify and recover

```bash
oc --context spoke get csv -n open-cluster-management        # ACM CSV Succeeded
oc --context spoke get mch -n open-cluster-management        # phase Running (expected end state)
oc --context spoke get managedclusters                       # local-cluster Joined/Available
oc --context spoke get klusterlet                            # exactly one, self-managed local-cluster (post-MCH)
```

Failure paths: MCH stuck Installing → check operand pods in
`open-cluster-management` and `multicluster-engine` namespaces for Pending
(SNO resource pressure; node has ~19.5 CPU / 95Gi allocatable, was at 4%/36%
before install). Detach stuck → inspect `ManagedCluster` finalizers on hub
and `appliedmanifestworks` on spoke. Rollback: delete the MultiClusterHub CR,
wait for operand teardown, delete the Subscription/CSV, then re-import spoke
into the old hub from the hub console (Import cluster → auto-import).

## Decision log

### Decisions

- Spoke becomes its OWN ACM 2.17 hub (user decision) instead of remaining a
  managed cluster of `hub` — first step of an ACM/GitOps failover exercise
  whose deliverable is `~/acm-failover-guide/README.md`.
- Channel `release-2.17` chosen to match the old hub's MCH 2.17.0 exactly:
  ACM hub backup/restore (a Phase-2 failover candidate) requires matching
  versions between hubs.
- Load-bearing order: ACM *operator* install may precede detach, but
  `MultiClusterHub` creation MUST follow completed detach — local-cluster
  self-import creates a klusterlet named `klusterlet`, which is the same name
  the old hub's import installed (Singleton mode).
- `availabilityConfig: Basic` on the MCH because spoke is single-node; the
  default High would double replicas for no benefit on SNO.
- Clean detach (delete ManagedCluster on hub) chosen over spoke-side manual
  klusterlet removal: the hub was down at first (flapping, then user restart)
  but returned, so the supported path was available. The manual path is
  documented in the guide as the hub-dead DR variant.

### How to drive it

Edit manifests under `~/acm-failover-guide/manifests/`, apply with
`oc --context spoke apply -f <file>`, verify with the commands in "Verify and
recover", and record every verified step (with real outputs) in
`~/acm-failover-guide/README.md` — that guide is the product; this runbook is
the operator map. When the MCH reaches Running and `local-cluster` joins,
update this runbook's status lines and proceed to Phase 2 (failover design:
two-hub + git-as-source-of-truth vs cluster-backup-operator restore;
research notes land in `~/acm-failover-guide/research-notes.md`). Commit
guide + runbook changes in `~/acm-failover-guide` (git repo, local only).
