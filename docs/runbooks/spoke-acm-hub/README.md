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
(api.hub.k8socp.com, its own MCH 2.17.0, now managing only `local-cluster`);
`sage` exists but was powered off throughout.

- Spoke, namespace `open-cluster-management`: OperatorGroup
  `open-cluster-management`, Subscription `advanced-cluster-management`
  (channel `release-2.17`, redhat-operators), CSV
  `advanced-cluster-management.v2.17.0`, and `MultiClusterHub`
  `multiclusterhub` (`availabilityConfig: Basic`) — **Running** since
  2026-08-12 (~10 min install). Namespace `multicluster-engine` holds the
  MCE operand. `local-cluster` is Joined/Available (self-managed klusterlet).
- Spoke was DETACHED from the old hub 2026-08-12 (clean detach: delete of
  `ManagedCluster spoke` on `hub`, ~4.5 min cascade). Side effect confirmed
  live: the detach pruned all hub-delivered workloads on spoke (namespace
  `acm-policy-demo`, policies, addons) — see
  `~/acm-policy-research/docs/runbooks/acm-policy-research-demo/README.md`.
- Console: no separate ACM route in 2.17 — OpenShift console
  (`console-openshift-console.apps.spoke.k8socp.com`) → "All Clusters"
  perspective.
- Deliverable this state serves: `~/acm-failover-guide/README.md` (the
  verified failover guide; Phase 2 design pending) and
  `research-notes.md` (doc citations) in the same repo.

### Template map

~/acm-failover-guide/manifests/10-acm-operator.yaml -> spoke ns open-cluster-management + OperatorGroup + Subscription advanced-cluster-management (release-2.17)
~/acm-failover-guide/manifests/20-multiclusterhub.yaml -> spoke MultiClusterHub multiclusterhub in ns open-cluster-management (availabilityConfig Basic)

### Re-run

Prerequisites: context `spoke` reachable with cluster-admin; spoke NOT a
managed cluster of any other hub (no foreign `klusterlet` CR — if attached,
first `oc --context <that-hub> delete managedcluster spoke` and wait for the
`open-cluster-management-agent*` namespaces to vanish from spoke).

```bash
oc --context spoke apply -f ~/acm-failover-guide/manifests/10-acm-operator.yaml
# wait: CSV advanced-cluster-management.v2.17.0 = Succeeded (~3 min), then:
oc --context spoke apply -f ~/acm-failover-guide/manifests/20-multiclusterhub.yaml
# wait: MCH phase Running (~10 min on this SNO)
```

Both applies are idempotent/convergent.

### Verify and recover

```bash
oc --context spoke get mch -n open-cluster-management   # Running / 2.17.0 / "All hub components ready."
oc --context spoke get managedclusters                  # local-cluster Joined=True Available=True
oc --context spoke get klusterlet                       # exactly one (self-managed)
oc --context spoke get pods -n open-cluster-management --no-headers | grep -v 'Running\|Completed'   # empty
oc --context spoke adm top node                         # was 11% CPU / 42% mem with hub installed
```

Failure paths: MCH stuck Installing → look for Pending pods in
`open-cluster-management`/`multicluster-engine` (SNO resource pressure) and
the multiclusterhub-operator logs. local-cluster not joining → check for a
leftover foreign klusterlet CR or `open-cluster-management-agent` namespace
(name collision with self-import). Rollback: delete the MultiClusterHub CR
(operand teardown takes ~10 min), then Subscription + CSV, then re-import
spoke into the old hub via its console (Import cluster) if the previous
topology is wanted back.

## Decision log

### Decisions

- Spoke became its OWN ACM 2.17 hub (user decision) — step 1 of the
  ACM/GitOps failover exercise; end state is two independent same-version
  hubs, which is itself the precondition for the hub backup/restore
  failover pattern (version parity is a hard documented requirement).
- Channel `release-2.17` to match the old hub's MCH 2.17.0 exactly.
- Load-bearing order: ACM operator install may precede detach, but
  `MultiClusterHub` creation MUST follow completed detach — local-cluster
  self-import creates a klusterlet named `klusterlet`, the same name the old
  hub's import used (Singleton mode). Verified live: with detach done first,
  self-import joined in ~7 min with zero conflicts.
- `availabilityConfig: Basic` because spoke is single-node (documented SNO
  setting; High doubles replicas for no benefit).
- Clean detach (delete ManagedCluster on hub) over spoke-side manual
  klusterlet removal: hub returned after its restart, so the supported path
  was available. Observed: ~4.5 min, addons first, then klusterlet; leftover
  CRDs `appliedmanifestworks`/`clusterclaims` are harmless and were reused
  by the new install. The manual hub-dead variant is documented in the guide
  (Phase 2 / research-notes).
- KEPT (not cleaned): hub-side policies in `acm-policy-research` on the old
  hub now target zero clusters — deliberately left as inert evidence (see
  that repo's runbook).

### How to drive it

Edit manifests under `~/acm-failover-guide/manifests/`, apply with
`oc --context spoke apply -f <file>`, verify with "Verify and recover", and
record every verified step with real outputs in
`~/acm-failover-guide/README.md` — the guide is the product; this runbook is
the operator map. Next planned change (Phase 2, pending user decision):
choose the failover pattern (git-as-source-of-truth + pull-model Argo vs
cluster-backup-operator + OADP to S3 vs documented manual re-import),
likely importing `sage` into this new spoke hub as the test subject. Commit
guide + runbook changes in `~/acm-failover-guide` (local git repo, branch
`main`).
