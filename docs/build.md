# Building the environment

What the failover exercises run against, and how to build it: the
clusters, versions, storage, and the order to apply `manifests/` and
`dr/`. Why it is built this way is [design.md](design.md); the operator
procedures are the [runbooks](runbooks/); the measured results are in
[results.md](results.md).

## Clusters

| Cluster | Role | Verified shape |
| --- | --- | --- |
| hub-x | ACM hub, starts active | single-node OpenShift 4.21 |
| hub-y | ACM hub, starts passive | single-node OpenShift 4.21 |
| spoke | workload cluster, imported into the active hub | single-node OpenShift 4.21 |

The names are the kubeconfig contexts every command below and every
runbook uses. If your clusters have other names, give them these names in
a copy of your kubeconfig, so other tools that use your contexts are
unaffected:

```bash
mkdir -p ~/acm-dr && oc config view --flatten > ~/acm-dr/kubeconfig
chmod 600 ~/acm-dr/kubeconfig                 # it holds cluster credentials
export KUBECONFIG=~/acm-dr/kubeconfig         # in every terminal of the exercise
oc config rename-context <your active hub> hub-x
oc config rename-context <your passive hub> hub-y
oc config rename-context <your workload cluster> spoke   # skip if it is already named spoke
oc config get-contexts                        # hub-x, hub-y and spoke are listed
```

Start from three healthy clusters. After a cold start, a single-node
cluster takes 10–20 minutes to settle:

```bash
for c in hub-x hub-y spoke; do
  echo "== $c"
  oc --context $c get nodes                                    # Ready
  oc --context $c get clusteroperators --no-headers \
    | awk '$3 != "True" || $5 != "False"'                      # no output: all Available, none Degraded
  oc --context $c get csr --no-headers | grep -c Pending       # 0
done
```

A node that stays `NotReady` after a long power-off usually has
certificate signing requests waiting; approve that cluster's pending ones
with `oc --context <c> get csr -o name | xargs oc --context <c> adm
certificate approve`.

The values to change in the repo are listed in the
[README](../README.md#getting-started). The hub roles are
interchangeable: failover swaps them back and forth with no extra cleanup
in between.

- Hub sizing (observed): a single node with 19.5 CPU / 95 GiB allocatable
  ran the full hub at about 11% CPU and 42% memory (about 47 pods across
  `multicluster-engine` and `open-cluster-management`).
  `availabilityConfig: Basic` on the MultiClusterHub is [the install
  docs' guidance for single-node
  OpenShift](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index#advanced-config-hub);
  use `High` on multi-node hubs.
- The verified build's API endpoints served publicly trusted
  certificates. With self-signed certificates, include
  `certificate-authority-data` in the import kubeconfig and the CA in the
  DPA's `objectStorage.caCert`.

## Software and versions

| Component | Version | Where | Notes |
| --- | --- | --- | --- |
| ACM | 2.17 (verified on 2.17.0) | both hubs | [The same version on both hubs is a hard backup/restore requirement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#enabling-backup-operator-clusters) |
| `cluster-backup` MCH component | with ACM | both hubs | Enabled in `manifests/20-multiclusterhub.yaml` ([MCH component override](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/install/index#advanced-config-hub)); ACM then installs OADP in `open-cluster-management-backup` |
| `managedserviceaccount` MCE component | with ACM | both hubs | On by default; MSA auto-import depends on it |
| OpenShift GitOps operator | channel `latest` (verified on 1.21) | all three clusters | [Identical operators on both hubs is a restore-hub requirement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prepare-new-hub) |
| S3-compatible object store | any | outside the clusters | Verified with SeaweedFS 4.41; on AWS use real S3 |

## Network and storage

- **An S3-compatible store, external to every cluster, reachable from both
  hubs.** [The backup operator needs OADP and an S3-compatible
  location](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#backup-restore-architecture),
  and ["active and passive hub clusters are connected to the same
  storage
  location"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#active-passive-config).
  Create one bucket (`acm-backups` here) and one access key for Velero.
  For non-AWS stores the DPA sets `s3ForcePathStyle: "true"` and
  `checksumAlgorithm: ""`; on AWS drop `s3Url` and `s3ForcePathStyle`.
  SeaweedFS note: with the default 30 GB `volumeSizeLimitMB`, the default
  collection can pre-claim every volume slot on a small disk and the
  first bucket PUT fails with 500 "No writable volumes"; lower the volume
  size limit.
- **A git host reachable from every cluster** (your copy of this repo):
  the spoke's local Argo CD pulls the apps from it, and each hub's local
  Argo CD reconciles its DR role (`dr/`) from it.
- **The hubs never talk to each other.** Their only shared state is the
  bucket.
- **Push delivery needs no extra ingress.** The hub's Argo CD reaches the
  spoke through ACM's cluster-proxy tunnel.
- Checking the S3 endpoint by hand with `curl --aws-sigv4` needs
  **curl 8 or newer** (the curl 7.76 shipped in RHCOS returns
  `SignatureDoesNotMatch` against a healthy endpoint). Velero itself is
  unaffected.

## Build steps

Apply from the repo root. `manifests/` is numbered in apply order.

| Manifest | Apply on | Purpose |
| --- | --- | --- |
| `10-acm-operator.yaml` | both hubs | ACM operator |
| `20-multiclusterhub.yaml` | both hubs | MultiClusterHub with `cluster-backup` enabled |
| `40-import-spoke.yaml` | active hub | Import the spoke ([auto-import-secret flow](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index#importing-clusters-auto-import-secret); secret created out-of-band) |
| `50-dpa.yaml` | both hubs | DataProtectionApplication pointing at the shared bucket |
| `55-backupschedule.yaml` | active hub only | [BackupSchedule](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#using-backup-restore) every 30 min with `useManagedServiceAccount: true`, [effectively mandatory for imported clusters](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-imported-managed-clusters) |
| `56-restore-passive.yaml` | passive hub only | [Continuous sync restore](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-passive-resources-check-backups) |
| `57-restore-activate.yaml` | nowhere yet | The manual failover action (runbook step D.2) |
| `60-gitops-operator.yaml` | all three clusters | OpenShift GitOps operator |
| `61-gitops-integration.yaml` | active hub | [GitOpsCluster and Placements](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#gitops-register) ([cluster secrets minted from rotated MSA tokens](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#secret-gitops)) |
| `62-appset-pull.yaml` | active hub | [Pull-model ApplicationSet](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#crd-pull-model) for `apps/hello-failover` |
| `63-appset-push.yaml` | active hub | Push-model ApplicationSet for `apps/hello-failover-push` |
| `dr/bootstrap/` | each hub | dr-role RBAC and Application, needed only for the git-driven paths |

### 1. Hubs: ACM with the backup component

```bash
for hub in hub-x hub-y; do
  oc --context $hub apply -f manifests/10-acm-operator.yaml
done
# wait until the ACM CSV reports Succeeded on both hubs:
oc --context hub-x get csv -n open-cluster-management
for hub in hub-x hub-y; do
  oc --context $hub apply -f manifests/20-multiclusterhub.yaml
done
for hub in hub-x hub-y; do
  oc --context $hub wait mch/multiclusterhub -n open-cluster-management \
    --for=jsonpath='{.status.phase}'=Running --timeout=30m
  oc --context $hub get csv -n open-cluster-management-backup -o name | grep oadp   # OADP installed by ACM
done
```

**Both hubs must report the same ACM version** before you go on:

```bash
for hub in hub-x hub-y; do
  oc --context $hub get csv -n open-cluster-management -o name | grep advanced-cluster-management
done
```

If one hub already runs an older z-stream than the catalog's latest, pin
the new hub to it. Apply a copy of `10-acm-operator.yaml` with
`installPlanApproval: Manual` and a `startingCSV`, approve the one
InstallPlan it creates, and wait for the CSV before applying
`20-multiclusterhub.yaml` there (here hub-y, pinned to 2.17.3):

```bash
V=2.17.3
sed "s/^  installPlanApproval: Automatic\$/  installPlanApproval: Manual\n  startingCSV: advanced-cluster-management.v$V/" \
  manifests/10-acm-operator.yaml > /tmp/10-acm-operator-pinned.yaml
grep -A1 '^  installPlanApproval' /tmp/10-acm-operator-pinned.yaml   # Manual, then the startingCSV
oc --context hub-y apply -f /tmp/10-acm-operator-pinned.yaml
until oc --context hub-y get installplan -n open-cluster-management -o name | grep -q .; do sleep 10; done
IP=$(oc --context hub-y get installplan -n open-cluster-management -o jsonpath='{.items[0].metadata.name}')
oc --context hub-y patch installplan "$IP" -n open-cluster-management --type merge -p '{"spec":{"approved":true}}'
until [ "$(oc --context hub-y get csv advanced-cluster-management.v$V -n open-cluster-management \
  -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ]; do sleep 15; done
```

The multicluster engine Subscription that ACM creates inherits the
Manual approval, so after you apply `20-multiclusterhub.yaml` on that hub
its InstallPlan waits for approval too, and the MultiClusterHub stays
`Installing` until you approve it:

```bash
oc --context hub-y apply -f manifests/20-multiclusterhub.yaml
until oc --context hub-y get installplan -n multicluster-engine -o name | grep -q .; do sleep 10; done
IP=$(oc --context hub-y get installplan -n multicluster-engine \
  -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}')
oc --context hub-y patch installplan "$IP" -n multicluster-engine --type merge -p '{"spec":{"approved":true}}'
oc --context hub-y wait mch/multiclusterhub -n open-cluster-management \
  --for=jsonpath='{.status.phase}'=Running --timeout=30m
```

Set the existing hub's ACM Subscription to `installPlanApproval: Manual`
too, or a z-stream release during the exercise upgrades only that hub:

```bash
SUB=$(oc --context hub-x get subscription.operators.coreos.com -n open-cluster-management \
  -o jsonpath='{.items[?(@.spec.name=="advanced-cluster-management")].metadata.name}')
oc --context hub-x patch subscription.operators.coreos.com "$SUB" -n open-cluster-management \
  --type merge -p '{"spec":{"installPlanApproval":"Manual"}}'
```

#### A hub that already runs ACM

Skip `10-acm-operator.yaml` there: a second OperatorGroup in
`open-cluster-management` makes OLM fail every CSV in the namespace
(`TooManyOperatorGroups`). Do not apply `20-multiclusterhub.yaml` either:
the operator has filled the existing MultiClusterHub's
`spec.overrides.components` with every component, and `oc apply`
replaces that whole list. Turn on `cluster-backup` in place instead,
keeping every other entry:

```bash
oc --context hub-x get mch multiclusterhub -n open-cluster-management -o json \
  | jq -c '{spec: {overrides: {components:
      ((.spec.overrides.components // [] | map(select(.name != "cluster-backup")))
       + [{name: "cluster-backup", enabled: true}])}}}' > /tmp/mch-patch.json
oc --context hub-x patch mch multiclusterhub -n open-cluster-management \
  --type merge --patch-file /tmp/mch-patch.json
oc --context hub-x get mch multiclusterhub -n open-cluster-management \
  -o jsonpath='{.spec.overrides.components[?(@.name=="cluster-backup")].enabled}'   # true
```

#### A cluster that is managed by another hub

It must be detached before it becomes a hub: the hub's self-import
creates a klusterlet named `klusterlet`, which collides with the one the
other hub installed. Detaching removes the add-ons and ManifestWork
payloads that hub delivered to it; anything another tool deployed (Argo
CD push, Helm) stays.

```bash
oc --context <managing hub> delete managedcluster <cluster name>
oc --context hub-y get klusterlet                         # NotFound, after a few minutes
oc --context hub-y get ns open-cluster-management-agent   # NotFound
```

If the klusterlet stays, follow the cleanup in the ACM
[Clusters guide](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index)
("Removing a cluster from management").

#### Shared clusters

These manifests assume dedicated clusters. On a hub that already manages
other clusters, pick a ManagedCluster name that is not taken (applying
`40-import-spoke.yaml` over an existing `spoke` takes that cluster over)
and bind a dedicated ManagedClusterSet instead of `default` in
`61-gitops-integration.yaml`, or every cluster in `default` gets
registered with Argo CD.

A hub that runs other Argo CD applications fails them over too:
everything in the `argoproj.io` group is in the backup, so the other hub
restores them and starts syncing them, including the ones that deploy to
the hub itself. And if another setup already registers the workload
cluster with that hub's Argo CD under the same name, the GitOpsCluster's
cluster secret makes two clusters with one name, and Argo CD stops
syncing the applications that target it by name. For an exercise, move
other GitOps work off the hubs first.

### 2. All clusters: OpenShift GitOps

```bash
for c in hub-x hub-y spoke; do
  oc --context $c apply -f manifests/60-gitops-operator.yaml
done
```

If one hub already runs GitOps, check its version first. Channel `latest`
installs the newest z-stream on a new cluster, so pin the other hub to the
existing hub's CSV, the same way as ACM in step 1. The spoke can take
`latest`. A Manual Subscription holds every upgrade in its namespace (OLM
resolves `openshift-operators` as one unit), so other operators there
wait for approval too until you switch it back:

```bash
oc --context hub-x apply -f manifests/60-gitops-operator.yaml   # no change if it is the same Subscription
oc --context spoke apply -f manifests/60-gitops-operator.yaml
GV=$(oc --context hub-x get subscription.operators.coreos.com openshift-gitops-operator \
  -n openshift-operators -o jsonpath='{.status.installedCSV}')
echo "$GV"
sed "s/^  installPlanApproval: Automatic\$/  installPlanApproval: Manual\n  startingCSV: $GV/" \
  manifests/60-gitops-operator.yaml > /tmp/60-gitops-operator-pinned.yaml
grep -A1 '^  installPlanApproval' /tmp/60-gitops-operator-pinned.yaml   # Manual, then the startingCSV
oc --context hub-y apply -f /tmp/60-gitops-operator-pinned.yaml
IP=""; until [ -n "$IP" ]; do sleep 10
  IP=$(oc --context hub-y get installplan -n openshift-operators -o json | jq -r --arg csv "$GV" \
    '.items[] | select(.spec.approved==false and (.spec.clusterServiceVersionNames | index($csv))) | .metadata.name')
done
oc --context hub-y patch installplan "$IP" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
until [ "$(oc --context hub-y get csv "$GV" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ]; do sleep 15; done
for c in hub-x hub-y spoke; do
  echo "== $c"; oc --context $c get csv -n openshift-operators -o name | grep gitops
done
```

### 3. Hubs: backup storage

Check the bucket and key from your workstation first (curl 8 or newer),
then point a copy of `manifests/50-dpa.yaml` at your endpoint, so the
endpoint stays out of git. If the bucket name, prefix or region differ
from `acm-backups`, `acm` and `us-east-1`, change them in the copy too.
Then, on each hub:

```bash
read -rp 'S3 endpoint URL: ' S3_URL            # e.g. https://s3.example.com
read -rp 'S3 access key: ' S3_ACCESS_KEY
read -rsp 'S3 secret key: ' S3_SECRET_KEY; echo
curl -sS -o /dev/null -w '%{http_code}\n' --aws-sigv4 "aws:amz:us-east-1:s3" \
  --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" "$S3_URL/acm-backups?list-type=2"   # 200
sed "s#s3Url: https://s3.example.com#s3Url: $S3_URL#" manifests/50-dpa.yaml > /tmp/50-dpa.yaml
grep s3Url /tmp/50-dpa.yaml
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$S3_ACCESS_KEY" "$S3_SECRET_KEY" > /tmp/cloud
for hub in hub-x hub-y; do
  oc --context $hub create secret generic cloud-credentials -n open-cluster-management-backup \
    --from-file=cloud=/tmp/cloud --dry-run=client -o yaml | oc --context $hub apply -f -
  oc --context $hub apply -f /tmp/50-dpa.yaml
done
rm /tmp/cloud
for hub in hub-x hub-y; do
  oc --context $hub wait backupstoragelocation --all -n open-cluster-management-backup \
    --for=jsonpath='{.status.phase}'=Available --timeout=5m
done
```

The secret is created through `apply`, so running the block again (for
example with a new key) updates it in place; then run `oc --context <hub>
rollout restart deploy/velero -n open-cluster-management-backup` on each
hub so Velero picks up the new key at once. A location that stays
`Unavailable` with `SignatureDoesNotMatch` in `oc get
backupstoragelocation -o yaml` has a wrong secret key in that secret.

A certificate error from curl means the store's certificate is not
publicly trusted: add its CA to the copy as `objectStorage.caCert`
(base64) before applying it.

### 4. Active hub: import the spoke

```bash
oc --context hub-x apply -f manifests/40-import-spoke.yaml
oc --context spoke config view --flatten --minify > /tmp/spoke-kubeconfig
oc --context hub-x create secret generic auto-import-secret -n spoke \
  --from-file=kubeconfig=/tmp/spoke-kubeconfig
rm /tmp/spoke-kubeconfig
oc --context hub-x get managedclusters -w        # Ctrl-C once spoke shows Joined and Available True
```

(If the `KlusterletAddonConfig` is rejected because namespace `spoke`
does not exist yet, re-apply the file once the ManagedCluster has created
it.)

If hub-x already manages the spoke, apply `40-import-spoke.yaml` anyway,
because it sets the clusterset, the `name` label and the add-ons the
rest of the build relies on, and skip the auto-import secret. If another
tool imported it with a kept auto-import secret (annotation
`managedcluster-import-controller.open-cluster-management.io/keeping-auto-import-secret`),
delete that secret. That leaves the ManagedServiceAccount token from the
backups as the only import credential, which is the state the runbooks
assume:

```bash
oc --context hub-x get secret auto-import-secret -n spoke   # NotFound is what you want
oc --context hub-x delete secret auto-import-secret -n spoke
```

### 5. Backup roles

The schedule takes its first backups right away. Let them finish before
the passive hub starts restoring, so its first restore has something to
read:

```bash
oc --context hub-x apply -f manifests/55-backupschedule.yaml
while :; do
  P=$(oc --context hub-x get backup.velero.io -n open-cluster-management-backup -o jsonpath='{.items[*].status.phase}')
  echo "$(date -u +%T) ${P:-no backups yet}"
  [ -n "$P" ] && [ -z "$(echo "$P" | tr ' ' '\n' | grep -v '^Completed$')" ] && break
  sleep 20
done                                    # Ctrl-C and investigate if a phase reads Failed or PartiallyFailed
oc --context hub-x get backupschedule -n open-cluster-management-backup   # Enabled
oc --context hub-y apply -f manifests/56-restore-passive.yaml
oc --context hub-y wait restores.cluster.open-cluster-management.io/restore-acm-passive-sync \
  -n open-cluster-management-backup --for=jsonpath='{.status.phase}'=Enabled --timeout=15m
oc --context hub-y get restores.cluster.open-cluster-management.io -n open-cluster-management-backup
```

### 6. Active hub: GitOps wiring and the demo apps

```bash
oc --context hub-x apply -f manifests/61-gitops-integration.yaml
oc --context hub-x apply -f manifests/62-appset-pull.yaml
oc --context hub-x apply -f manifests/63-appset-push.yaml
oc --context spoke get applications.argoproj.io -A   # hello-failover-spoke, synced by the spoke's Argo
oc --context hub-x get applications.argoproj.io -n openshift-gitops   # hello-failover-push-spoke, on the hub
```

Everything applied in this step is in a backed-up API group, so hub-y
picks it up through its passive restore; there is nothing to apply there.

### 7. Git-driven paths only: bootstrap `dr/`

Follow Phase P of the [Automated Pull Path
runbook](runbooks/dr-failover-pull-gitops/README.md#phase-p--one-time-prerequisites):
RBAC first, then each hub's `dr-role` Application. Each hub's Argo CD
adopts the BackupSchedule or Restore applied in step 5. From then on the
manual runbooks need their break-glass step (D.0) before touching a hub's
role objects.

## Build-time gotchas

Each cost real time and none is in the product docs (the numbering is
stable; other documents cite these by number):

1. **A missing `open-cluster-management-global-set` namespace on the
   hub** silently prevents the `managed-serviceaccount`, `cluster-proxy`
   and `work-manager` addons from reaching any cluster: no MSA tokens, so
   GitOpsCluster registration fails and `useManagedServiceAccount`
   auto-import would fail at failover. Fix: recreate the namespace (MCE
   regenerates the binding and placement instantly). **DR pre-flight
   check:** `oc get managedserviceaccount -A` on the active hub must show
   `auto-import-account` for each imported cluster with a
   `.status.tokenSecretRef` ([automatic import
   considerations](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#auto-import-considerations)).
2. On an ACM hub, bare `application` resolves to ACM's `app.k8s.io` CRD.
   Always query `applications.argoproj.io`, or you will chase phantom
   disappearances.
3. **A stray `routes.route.openshift.io` CRD** (installed on a cluster
   that was once a spoke with a hub's GitOps addon) collides with the
   real aggregated Route API and makes the cluster's whole `/openapi/v2`
   return 503, which wedges Argo's cluster cache (`ComparisonError:
   failed to load open api schema`). Save a copy
   (`oc get crd routes.route.openshift.io -o yaml`) and delete the CRD;
   real Routes are served by openshift-apiserver and are unaffected.
   Check every cluster that ever had the gitops addon.
4. **Route creation forbidden** for the spoke's Argo
   application-controller (`SyncFailed: routes ... is forbidden`): [the
   pull-model RBAC
   prerequisite](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#prereqs-pull-model).
   The least-privilege fix used here: `managedNamespaceMetadata` labels
   the app namespace `argocd.argoproj.io/managed-by=openshift-gitops`, and
   the GitOps operator mints namespace-scoped RoleBindings. The docs'
   alternative is a cluster-admin binding for the controller.
5. **Routes are permanently OutOfSync without `ignoreDifferences`** for
   `/spec/host`, `/spec/wildcardPolicy` and `/spec/to/weight`
   (server-side defaults). An explicit host in git is wrong for an
   ApplicationSet, because it would pin one cluster's apps domain.
