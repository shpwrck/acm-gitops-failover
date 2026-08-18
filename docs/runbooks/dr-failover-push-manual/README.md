# Manual Push Path — DR exercise runbook: manual operation, push delivery

**Status: EXERCISE VERIFIED LIVE 2026-08-13 18:30–18:40Z**
([exercise record](../../exercises/manual-push.md)). **Measured push-model
delivery RTO: 2 min 53 s** (deploy
committed 18:32:15Z with no active hub → route serving it 18:35:08Z),
against the pull model's ~2.5 min ordinary poll latency in the same
window — pull has no outage term at all. Both probes: zero non-200s.
Under live dr/ wiring the G phase gains the operator-at-return
break-glass (suspend the returned hub's dr-role before touching its
role objects), then git re-align + re-enable per D.0's
afterwards-contract — adoption verified, nothing recreated. Phase P was
verified earlier the same day. Delta against the verified
[Manual Pull Path runbook](../dr-failover-pull-manual/README.md); unlisted phases run
as written there. The DR *operation* is identical — what changes is the
delivery model under test and therefore what the exercise measures: the
Manual Pull Path proves workload delivery is IMMUNE to hub loss; this path measures exactly
how delivery DIES with the hub and how it resurrects. Both truths belong
in the customer conversation.

## Phase P — One-time prerequisites (VERIFIED 2026-08-13)

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
**Success (observed):** `hello-failover-push-spoke` appeared ON THE HUB
(contrast: the pull model's stub carries skip-reconcile and the workload
Application lives on spoke) and reached `Synced | Healthy` in under two
minutes with NO extra RBAC;
`https://hello-failover-push-hello-failover-push.apps.spoke.example.com`
serves `REVISION v1`.
**Failure:** `SyncFailed … forbidden` → your environment's addon RBAC
differs from what P.2 documents; rediscover before granting anything.

### P.2 The push identity — discovered, with a security finding

What verification found (2026-08-13, ACM 2.17):

- The minted cluster secret is `spoke-application-manager-cluster-secret`
  — the token belongs to the **`application-manager`
  ManagedServiceAccount** (same MSA family as auto-import; one more
  dependent of the [MSA token chain](../../exercises/msa-token-hygiene.md)).
- The Application's destination is NOT spoke's API URL but the
  **cluster-proxy addon**
  (`https://cluster-proxy-addon-user.multicluster-engine.svc.cluster.local:9092/spoke`)
  — push traffic tunnels through ACM's proxy, adding the proxy chain
  (hub-side service + spoke-side agent tunnel) to push delivery's
  dependency list. Note for the exercise: delivery resurrection requires
  this chain re-established on the NEW hub, not just the cluster secret.
- **Security finding:** the spoke-side SA behind that token
  (`open-cluster-management-agent-addon/application-manager`) is bound to
  ClusterRole `open-cluster-management:application-manager`, whose rules
  are `apiGroups:*, resources:*, verbs:*` + all nonResourceURLs —
  **cluster-admin in all but name**. Push worked "out of the box" because
  the hub holds an admin credential for every managed cluster. That is
  the push model's real price tag: a compromised hub Argo is admin
  everywhere it pushes. The pull model's namespace-scoped
  `managedNamespaceMetadata` RBAC ([build.md](../../build.md) gotcha #4) is the
  least-privilege contrast — put both sentences in the customer
  comparison.

Re-verify in any new environment:

```bash
oc --context $ACTIVE get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true
oc --context $MANAGED get clusterrolebinding open-cluster-management:application-manager -o jsonpath='{.roleRef.name}{" -> "}{.subjects}'
oc --context $MANAGED get clusterrole open-cluster-management:application-manager -o jsonpath='{.rules}'
```

## Phase 0/A — as the Manual Pull Path, plus the second probe

Add a second availability probe for the push app's route (same loop, own
log file `~/probe-push-<date>.log`).

**Why:** Two apps, two logs, one outage: the pull log should stay
unbroken (already proven twice); the push log tells this path's actual
story — the app KEEPS SERVING through hub death (Argo dying uninstalls
nothing), which is itself a claim customers doubt.

## Phase B — as the Manual Pull Path

## Phase C' — The inverted teaching moment

```bash
# bump REVISION in apps/hello-failover-push/configmap.yaml, commit, push
date -u +%FT%TZ   # record: push-model deploy attempted
curl -s https://hello-failover-push-hello-failover-push.apps.spoke.example.com | grep -i revision
```

**Why:** The Manual Pull Path's Phase C celebrates the deploy landing
hubless. This path documents the mirror: the commit lands in git and NOTHING HAPPENS — no
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

## Phase D — as the Manual Pull Path (identical machinery)

## Phase E' — Manual Pull Path E, plus delivery resurrection

After Manual Pull Path E.1–E.3 (including [MSA hygiene](../../exercises/msa-token-hygiene.md) — do it FIRST; the
GitOps cluster secret depends on the same MSA chain):

```bash
oc --context $PASSIVE get applications.argoproj.io -n openshift-gitops
oc --context $PASSIVE get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true
watch -n10 'curl -s https://hello-failover-push-hello-failover-push.apps.spoke.example.com | grep -i revision'
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
chain;
app `SyncFailed forbidden` → P.2's RBAC didn't survive re-home — that
finding would itself justify the exercise.

## Phase F/G/H — as the Manual Pull Path

H additionally records: the measured delivery RTO, the P.2 RBAC discovery
(fold into 63/64 comments), and the side-by-side probe-log comparison —
the single most persuasive artifact the four-path repo produces.
