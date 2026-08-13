# Path 3 — DR exercise runbook: manual operation, push delivery

**Status: UNVERIFIED — authored 2026-08-13.** Delta against the verified
[path-1 runbook](../dr-failover-exercise/README.md); unlisted phases run
as written there. The DR *operation* is identical — what changes is the
delivery model under test and therefore what the exercise measures: path 1
proves workload delivery is IMMUNE to hub loss; path 3 measures exactly
how delivery DIES with the hub and how it resurrects. Both truths belong
in the customer conversation.

## Phase P — One-time prerequisites

### P.1 Deploy the push app from the active hub

```bash
oc --context $ACTIVE apply -f manifests/63-appset-push.yaml
oc --context $ACTIVE get applications.argoproj.io -n openshift-gitops
```

**Why:** The push ApplicationSet generates its Applications ON THE HUB
(no pull markers), and the hub's Argo pushes to `$MANAGED` over the
ACM-minted cluster secret. Coexists with the pull app by design (separate
namespace `hello-failover-push`) so one outage exercises both models
side by side.
**Success:** `hello-failover-push-$MANAGED` appears ON THE HUB (contrast:
the pull model's Application lives on sage) and reaches `Synced/Healthy`;
`https://hello-failover-push-hello-failover-push.apps.sage.k8socp.com`
serves `REVISION v1`.
**Failure:** `SyncFailed … forbidden` → expected first hurdle; go to P.2.

### P.2 Discover (not guess) the push identity and its RBAC

```bash
# Whose token is in the minted cluster secret?
oc --context $ACTIVE get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true -o yaml | grep -E 'name:|server:'
# On the target: what can that identity do in the app namespace?
oc --context $MANAGED auth can-i create deployment -n hello-failover-push --as=<discovered-sa>
```

**Why:** The pushing identity is an ACM ManagedServiceAccount's token; its
permissions on `$MANAGED` are the load-bearing unknown of the whole path
(the pull model's `managedNamespaceMetadata` trick does NOT apply — that
empowers the TARGET's local Argo, which push doesn't use). Whatever grant
turns out to be needed becomes `manifests/64-push-rbac-sage.yaml` with the
REAL subject, applied to `$MANAGED`, and this runbook gets updated —
that's the deal with author-now-verify-later.
**Success:** `yes` from `auth can-i`, or a written+applied 64 that makes
it so.

## Phase 0/A — as path 1, plus the second probe

Add a second availability probe for the push app's route (same loop, own
log file `~/probe-push-<date>.log`).

**Why:** Two apps, two logs, one outage: the pull log should stay
unbroken (already proven twice); the push log tells this path's actual
story — the app KEEPS SERVING through hub death (Argo dying uninstalls
nothing), which is itself a claim customers doubt.

## Phase B — as path 1

## Phase C' — The inverted teaching moment

```bash
# bump REVISION in apps/hello-failover-push/configmap.yaml, commit, push
date -u +%FT%TZ   # record: push-model deploy attempted
curl -s https://hello-failover-push-hello-failover-push.apps.sage.k8socp.com | grep -i revision
```

**Why:** Path 1's Phase C celebrates the deploy landing hubless. Path 3
documents the mirror: the commit lands in git and NOTHING HAPPENS — no
hub Argo exists to push it. The gap between this timestamp and the
revision actually serving (Phase E') is the push model's
delivery-pipeline RTO, the number this whole path exists to measure. Do
the pull app's v-next in the same window: one outage, both behaviors,
side by side.
**Success (for the exercise):** Push route still serves the OLD revision;
pull route serves its NEW one within ~3 min. Both probes: unbroken 200s.
**Failure:** Push app updates mid-outage → something else is syncing it
(a leftover local-Argo binding?) — the model separation is broken;
investigate before drawing any conclusions.

## Phase D — as path 1 (identical machinery)

## Phase E' — path-1 E, plus delivery resurrection

After path-1 E.1–E.3 (including §3.3 MSA hygiene — do it FIRST; the
GitOps cluster secret depends on the same MSA chain):

```bash
oc --context $PASSIVE get applications.argoproj.io -n openshift-gitops
oc --context $PASSIVE get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true
watch -n10 'curl -s https://hello-failover-push-hello-failover-push.apps.sage.k8socp.com | grep -i revision'
```

**Why:** The restored ApplicationSet must regenerate
`hello-failover-push-$MANAGED` on the new hub, GitOpsCluster must re-mint
the cluster secret from the (freshly repaired) MSA token, and the first
successful push closes the delivery outage. The moment the route flips to
the mid-outage revision, subtract Phase C''s timestamp: **that is the
push model's delivery RTO** — the pull model's equivalent was ~0.
**Success:** App regenerated, secret present, route serving the
mid-outage revision; record the delta.
**Failure:** App `Unknown`/cluster secret missing → the MSA/GitOpsCluster
chain (posture runbook failure paths, `ClusterRegistrationFailed` entry);
app `SyncFailed forbidden` → P.2's RBAC didn't survive re-home — that
finding would itself justify the exercise.

## Phase F/G/H — as path 1

H additionally records: the measured delivery RTO, the P.2 RBAC discovery
(fold into 63/64 comments), and the side-by-side probe-log comparison —
the single most persuasive artifact the four-path repo produces.
