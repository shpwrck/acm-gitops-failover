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
unaffected. [`hack/build.sh`](#the-scripted-build) makes that copy in
its Settings stage; by hand:

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
  OpenShift](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/get_started/index#advanced-config-hub);
  use `High` on multi-node hubs.
- The verified build's API endpoints served publicly trusted
  certificates. With self-signed certificates, include
  `certificate-authority-data` in the import kubeconfig and the CA in the
  DPA's `objectStorage.caCert`.

## Software and versions

| Component | Version | Where | Notes |
| --- | --- | --- | --- |
| ACM | 2.17 (verified on 2.17.0) | both hubs | [The same version on both hubs is a hard backup/restore requirement](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#enabling-backup-operator-clusters) |
| `cluster-backup` MCH component | with ACM | both hubs | Enabled in `manifests/20-multiclusterhub.yaml` ([MCH component override](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/get_started/index#advanced-config-hub)); ACM then installs OADP in `open-cluster-management-backup` |
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
  Argo CD reconciles its DR role (`dr/`) from it. The `hack/` scripts
  work on your clone's `origin`: the pre-flight checks that `repoURL`
  names it, and they push to the branch the settings file names (the
  mid-outage deploy, the teardown's reset of `dr/`), so that branch must
  accept pushes from your workstation.
- **The hubs never talk to each other.** Their only shared state is the
  bucket.
- **Push delivery needs no extra ingress.** The hub's Argo CD reaches the
  spoke through ACM's cluster-proxy tunnel.
- Checking the S3 endpoint by hand with `curl --aws-sigv4` needs
  **curl 8 or newer** (the curl 7.76 shipped in RHCOS returns
  `SignatureDoesNotMatch` against a healthy endpoint). Velero itself is
  unaffected.

## The scripted build

`hack/build.sh` runs the build steps below in order, from three clusters
that pass the health check under [Clusters](#clusters), and ends with
`hack/dr.sh check`, the pre-flight every exercise starts with. It reads
the same settings file as `hack/dr.sh`, `~/acm-dr/dr.env`, and on a
terminal, both the build and `--check` start with a Settings stage that
changes nothing on the clusters. With no settings file yet, it asks for
your kubeconfig, the branch the clusters pull from, which of your
contexts are the two hubs and the workload cluster, and the bucket,
prefix, region, endpoint and CA file (if the store's certificate is not
publicly trusted) of the backup storage. The hub that starts active is
the one `dr/` makes active on that branch: hub-x in a fresh copy. Then
it writes the settings file, and `~/acm-dr/kubeconfig`: a copy of your
kubeconfig in which those three contexts are named hub-x, hub-y and
spoke (see [Clusters](#clusters)); your own kubeconfig does not change.
With a settings file, it shows what the file holds, to keep or change;
each question then starts from the file's value. `--yes` uses the file
as it is. To write the settings by hand instead, copy
[`hack/dr.env.example`](../hack/dr.env.example) to `~/acm-dr/dr.env` and
set the contexts, the branch and the S3 endpoint, bucket, prefix and
region. The build asks for the S3 keys, or reads them from
`S3_ACCESS_KEY` and `S3_SECRET_KEY` in the environment, and puts them
only into the secret on each hub: not into a file, not into its log.
What you type or paste at its prompts keeps only its printable
characters: a pasted line break (which the prompt turns into a space)
and any escape sequences the terminal slips in are dropped, and it
prints the length of each key, and the access key's last four
characters, so you can check what it took. The endpoint must be an
`http(s)://` URL before it is saved. `DR_PLAIN=1 hack/build.sh` asks
with plain prompts instead of gum's.

```bash
hack/build.sh --check   # read-only on the clusters: what it would install, reuse or refuse, and why
hack/build.sh           # a menu; --yes builds without asking
```

The menu offers Check, Build and Quit. Each pick, done or stopped, ends
with Back to the menu; only Quit (or Ctrl-C) leaves.

With gum, the script starts on a clear screen and keeps the top of the
screen in place: the stages (done, current and to come) and the time
since it started. Each stage starts on an empty
window under it, and a pre-flight section that is all green collapses
to one line (its heading, a ✓ and what it found), so the output stays in
the window; the log keeps everything,
including what a later stage cleared from the screen. Before each stage
after the ACM one, it waits for you to pick Continue, so you can read
what the last stage did before the window clears; `--yes` runs straight
through. `--check` runs
only the settings and the pre-flight, so its header has those two
stages; the plan at its end lists what the other eight would install or
reuse. It logs to
`~/acm-dr/logs/build-check-<time>.log`. The
pinned header needs a terminal of at least 72 columns and 20 lines (a
smaller one gets a note, and the output scrolls), and `DR_PIN=0` turns
it off.

It takes 40 to 60 minutes, most of it waiting for operators. Every RED
line links to the section of this document that explains it, and the
log is in `~/acm-dr/logs/build-<time>.log`. After a stop, run it again:
each stage skips what is already in place. What it does beyond typing
the steps:

- **One ACM version on both hubs.** It pins ACM to the version a hub
  already runs, or else to the newest in the `release-2.17` channel, with
  `installPlanApproval: Manual` on both hubs, and approves only that
  InstallPlan and the first ones of the multicluster engine and OADP,
  never an upgrade (step 1).
- **What is installed is reused.** An ACM that is already there gets the
  in-place changes and the annotations of [A hub that already runs
  ACM](#a-hub-that-already-runs-acm); an OpenShift GitOps that is already
  there is left as it is, and a hub that gets GitOps next to one that
  runs it is pinned to the same version (step 2).
- **It refuses what would break,** before it changes anything: a hub that
  another hub manages, a spoke managed by some other hub, hubs on
  different ACM versions, other managed clusters on a hub (see [Shared
  clusters](#shared-clusters)), a stray Route CRD (gotcha 3), manifests
  that pull from another repo or branch than your settings name, or an
  active hub's overlay that still lists an earlier failover's activation
  one-shot (step 7).
- **It creates `open-cluster-management-global-set`** on a hub where ACM
  did not (gotcha 1).
- **It writes the demo apps' URLs** (`APP_URL`, `PUSH_APP_URL`) into the
  settings file once they answer.

[`hack/teardown.sh`](#tearing-it-down) undoes it.

## Build steps

Apply from the repo root, in the order of the steps below. The numbers in
`manifests/` group the files by component; the steps apply the demo apps
(61–63) before the backup roles (55–56), so the first backup carries
them.

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
until [ "$(oc --context hub-y get csv advanced-cluster-management.v$V -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ]; do sleep 15; done
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
too, or a z-stream release during the exercise upgrades only that hub.
The annotation records the old value, so that
[`hack/teardown.sh`](#tearing-it-down) can set it back:

```bash
SUB=$(oc --context hub-x get subscription.operators.coreos.com -n open-cluster-management \
  -o jsonpath='{.items[?(@.spec.name=="advanced-cluster-management")].metadata.name}')
OLD=$(oc --context hub-x get subscription.operators.coreos.com "$SUB" -n open-cluster-management \
  -o jsonpath='{.spec.installPlanApproval}')
oc --context hub-x annotate subscription.operators.coreos.com "$SUB" -n open-cluster-management \
  acm-gitops-failover/install-plan-approval="$OLD"
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
keeping every other entry. If it was off, the annotation records that
the build turned it on, so that [`hack/teardown.sh`](#tearing-it-down)
turns it off again and leaves the rest of that ACM alone:

```bash
oc --context hub-x get mch multiclusterhub -n open-cluster-management -o json \
  | jq -c '{spec: {overrides: {components:
      ((.spec.overrides.components // [] | map(select(.name != "cluster-backup")))
       + [{name: "cluster-backup", enabled: true}])}}}' > /tmp/mch-patch.json
oc --context hub-x patch mch multiclusterhub -n open-cluster-management \
  --type merge --patch-file /tmp/mch-patch.json
oc --context hub-x get mch multiclusterhub -n open-cluster-management \
  -o jsonpath='{.spec.overrides.components[?(@.name=="cluster-backup")].enabled}'   # true
oc --context hub-x annotate mch multiclusterhub -n open-cluster-management \
  acm-gitops-failover/cluster-backup=enabled-by-build   # only if it was off before
```

Neither of these objects gets this repo's label
(`app.kubernetes.io/part-of: acm-gitops-failover`), so the teardown keeps
this ACM; everything the remaining steps apply does carry it.

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

A klusterlet that reports to the cluster itself is not another hub's:
its `spec.clusterName` is `local-cluster`, or its hub kubeconfig (secret
`hub-kubeconfig-secret` in `open-cluster-management-agent`) points at
`https://kubernetes.default.svc`. It is the agent a hub runs for its own
`local-cluster`, and an ACM uninstall can leave it behind; with no
MultiClusterHub left on the cluster, nothing manages it.
`hack/teardown.sh --full` removes it. By hand, delete it while its
operator still runs, so the operator cleans up after it, then its
namespaces:

```bash
oc --context hub-y delete klusterlet klusterlet --wait=false
oc --context hub-y wait klusterlet/klusterlet --for=delete --timeout=5m
oc --context hub-y delete namespace open-cluster-management-agent-addon open-cluster-management-agent
```

If the klusterlet stays because its operator is gone already (no
`klusterlet` deployment in `open-cluster-management-agent`), clear its
finalizer: `oc --context hub-y patch klusterlet klusterlet --type merge -p
'{"metadata":{"finalizers":null}}'`.

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

Skip a cluster that already runs OpenShift GitOps: applying the file
there would mark the existing Subscription as this repo's, and the
[teardown](#tearing-it-down) would then remove an operator that was
there before the build (and its Subscription may have another name,
which gives OLM two Subscriptions for one package).

If another Subscription in `openshift-operators` is on Manual approval,
OLM holds the new GitOps
InstallPlan for approval too, although the GitOps Subscription is
Automatic: the Subscription shows `InstallPlanPending` with reason
`RequiresApproval`, and no GitOps CSV appears. On a cluster that uses
OpenShift's own Gateway API (Red Hat OpenShift AI turns it on, for
example) the ingress operator installs Service Mesh 3 there and keeps
its Subscription on Manual, putting it back within seconds if you change
it. Approve the plan the
Subscription names, after checking that it installs GitOps alone. Never
approve an older pending plan in that namespace instead: it can carry
other operators' changes (one older plan seen live would have rolled
Service Mesh back).
`hack/build.sh` approves such a plan when it holds only GitOps, and stops
and names it otherwise:

```bash
IP=$(oc --context hub-x get subscription.operators.coreos.com openshift-gitops-operator -n openshift-operators \
  -o jsonpath='{.status.installPlanRef.name}')
oc --context hub-x get installplan "$IP" -n openshift-operators -o jsonpath='{.spec.clusterServiceVersionNames}{"\n"}'   # GitOps only
oc --context hub-x patch installplan "$IP" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
```

If one hub already runs GitOps, check its version first. Channel `latest`
installs the newest z-stream on a new cluster, so pin the other hub to the
existing hub's CSV, the same way as ACM in step 1. The spoke can take
`latest`. If the existing hub's Subscription follows another channel, set
that channel in the copy too. A Manual Subscription holds every upgrade in
its namespace (OLM resolves `openshift-operators` as one unit), so other
operators there wait for approval too until you switch it back:

```bash
oc --context spoke apply -f manifests/60-gitops-operator.yaml   # unless the spoke runs GitOps already
GV=$(oc --context hub-x get subscription.operators.coreos.com -n openshift-operators \
  -o jsonpath='{.items[?(@.spec.name=="openshift-gitops-operator")].status.installedCSV}')
echo "$GV"
sed "s/^  installPlanApproval: Automatic\$/  installPlanApproval: Manual\n  startingCSV: $GV/" \
  manifests/60-gitops-operator.yaml > /tmp/60-gitops-operator-pinned.yaml
grep -A1 '^  installPlanApproval' /tmp/60-gitops-operator-pinned.yaml   # Manual, then the startingCSV
oc --context hub-y apply -f /tmp/60-gitops-operator-pinned.yaml
IP=""; until [ -n "$IP" ]; do sleep 10
  IP=$(oc --context hub-y get subscription.operators.coreos.com openshift-gitops-operator -n openshift-operators \
    -o jsonpath='{.status.installPlanRef.name}')
done
oc --context hub-y get installplan "$IP" -n openshift-operators -o jsonpath='{.spec.clusterServiceVersionNames}{"\n"}'   # only $GV
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
    --from-file=cloud=/tmp/cloud --dry-run=client -o yaml \
    | oc label --local -f - app.kubernetes.io/part-of=acm-gitops-failover -o yaml \
    | oc --context $hub apply -f -
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
rest of the build relies on, and skip the auto-import secret. Apply it
without this repo's label, so that the [teardown](#tearing-it-down)
leaves the spoke managed, as it was before the build:

```bash
sed '/app.kubernetes.io\/part-of: acm-gitops-failover/d' manifests/40-import-spoke.yaml \
  | oc --context hub-x apply -f -
```

If another tool imported it with a kept auto-import secret (annotation
`managedcluster-import-controller.open-cluster-management.io/keeping-auto-import-secret`),
delete that secret. That leaves the ManagedServiceAccount token from the
backups as the only import credential, which is the state the runbooks
assume:

```bash
oc --context hub-x get secret auto-import-secret -n spoke   # NotFound is what you want
oc --context hub-x delete secret auto-import-secret -n spoke
```

### 5. Active hub: GitOps wiring and the demo apps

```bash
oc --context hub-x apply -f manifests/61-gitops-integration.yaml
oc --context hub-x apply -f manifests/62-appset-pull.yaml
oc --context hub-x apply -f manifests/63-appset-push.yaml
# the pull app, synced by the spoke's own Argo CD; the push app, synced by
# the hub's Argo CD through cluster-proxy. An Application reads Healthy
# before its first sync (it has no resources yet), so wait for the sync first:
for app in spoke/hello-failover-spoke hub-x/hello-failover-push-spoke; do
  c=${app%/*}; a=${app#*/}
  until oc --context $c get applications.argoproj.io $a -n openshift-gitops >/dev/null 2>&1; do sleep 10; done
  oc --context $c wait applications.argoproj.io/$a -n openshift-gitops \
    --for=jsonpath='{.status.operationState.phase}'=Succeeded --timeout=10m
  oc --context $c wait applications.argoproj.io/$a -n openshift-gitops \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout=10m
done
oc --context spoke get applications.argoproj.io -A
oc --context hub-x get applications.argoproj.io -n openshift-gitops
```

On the hub, the pull app's copy reads `Unknown`: it carries
`argocd.argoproj.io/skip-reconcile`, and its status comes from the spoke.

Everything applied in this step is in a backed-up API group, so hub-y
picks it up through its passive restore (step 6); there is nothing to apply there.

### 6. Backup roles

This comes after the demo apps, so the first backup already carries
them: the passive hub's first restore then holds them too, and the
Automated Pull Path's check that the backup contains Applications (P.2)
passes from the start. The schedule takes its first backups right away.
Let them finish before the passive hub starts restoring, so its first
restore has something to read:

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

### 7. Git-driven paths only: bootstrap `dr/`

Follow Phase P of the [Automated Pull Path
runbook](runbooks/dr-failover-pull-gitops/README.md#phase-p--one-time-prerequisites):
RBAC first, then each hub's `dr-role` Application. Each hub's Argo CD
adopts the BackupSchedule or Restore applied in step 6. From then on the
manual runbooks need their break-glass step (D.0) before touching a hub's
role objects.

On a branch that has been through a git-driven failover, the active hub's
overlay still lists that failover's activation one-shot next to
`../roles/active` (the "promoted" state in
[dr/README.md](../dr/README.md)). Before you build new clusters from that
branch, delete the `restore-activate-*.yaml` file from the overlay and its
entry from the overlay's `kustomization.yaml`, and push; `hack/teardown.sh`
does this for you (its stage 8), and `hack/teardown.sh --reset` does it
without removing ACM or OpenShift GitOps. Otherwise the new hub's `dr-role` applies
it next to the BackupSchedule, where the backup operator ignores it.

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

## Tearing it down

`hack/teardown.sh` removes the exercise from the three clusters, in the
reverse order of the build, so that the next build, or other work on the
clusters, starts clean. It reads the same settings file as the build.
Start with a dry run: it reads the clusters, prints the plan and every
step a real run would take, and changes nothing.

```bash
hack/teardown.sh --dry-run           # what the default removes, and what stays
hack/teardown.sh --reset --dry-run   # the same with --reset
hack/teardown.sh --full --dry-run    # the same with --full
hack/teardown.sh                     # a menu; --yes removes without asking
```

On its own, `hack/teardown.sh` offers Check (Reset) and Check (Teardown),
the dry runs of `--reset` and `--full`, then Teardown (Reset) and
Teardown (Full). Each pick, done or stopped, ends with Back to the menu;
only Quit (or Ctrl-C) leaves. The default mode is a command:
`hack/teardown.sh --dry-run`, then `hack/teardown.sh --yes`.

| Mode | What goes |
| --- | --- |
| default | Everything that carries the label `app.kubernetes.io/part-of: acm-gitops-failover`, which every object in `manifests/` and `dr/` has (`hack/validate.sh` checks it), so a manual build is labeled the same way as a scripted one. ACM and OpenShift GitOps go where their Subscription carries the label, that is, where the build installed them. On an ACM that was there before, the two marked changes of [A hub that already runs ACM](#a-hub-that-already-runs-acm) are undone, and the rest of it stays. |
| `--reset` | Only the exercise: the DR roles (stage 2), the demo apps (stage 3) and `dr/` in git (stage 8). ACM, OpenShift GitOps, the backup storage and the spoke's import stay, with the build's changes to them, so the next `hack/build.sh` reuses them and re-creates only the demo apps, the backups and the roles, in minutes. Use it to build again without reinstalling the operators. |
| `--full` | ACM, OpenShift GitOps and the demo, whoever installed them, and the spoke is detached: afterwards none of the three clusters runs ACM or OpenShift GitOps. |

In every mode, other operators and workloads stay, and so do the S3 bucket
and its backups, the settings file, and the CRDs the operators installed
(harmless, and a new install adopts them). In git, only `dr/` on the
branch and the branches `hack/dr.sh` pushed change (stage 8). The log is in
`~/acm-dr/logs/teardown-<time>.log`. After a stop, run it again: each
stage skips what is already gone. The teardown keeps the same header at
the top of the screen as the build (the stages and the time), and each
stage starts on an empty window under it. Between stages it waits for
Continue, as the build does (`--yes` skips the waits). A dry run does
all of this too, and logs every 'would' line to
`~/acm-dr/logs/teardown-dryrun-<time>.log`. The stages, in order:

1. **Pre-flight** (read-only): every cluster must answer; then a table of
   what goes and what stays, and the checks under [What the teardown
   refuses](#what-the-teardown-refuses).
2. **DR roles**: each hub's `dr-role` Application first, since its Argo
   CD would put the role back, then the BackupSchedule, the restores and
   the `dr-role` RBAC.
3. **Demo apps**: on both hubs (the passive hub holds restored copies),
   the ApplicationSets and the Applications they made, the GitOpsCluster,
   the placements and the cluster secrets; then the apps' namespaces on
   the spoke.
4. **Detach the spoke** (where the build imported it, or with `--full`):
   the ManagedCluster goes, a stale copy on the passive hub first; the hub that reaches the spoke then removes its
   klusterlet and add-ons, which takes a few minutes.
5. **Backup storage**: each hub's DataProtectionApplication and S3 key
   secret. Empty the bucket with your S3 tool if the next build should
   start without the old backups; it does not have to, since its first
   backup is newer than all of them.
6. **ACM**, the documented way ([Uninstalling Red Hat Advanced Cluster
   Management](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/get_started/index)):
   the MultiClusterHub first, which takes the engine, the add-ons and the
   backup operator with it (5 to 15 minutes), then the ACM operator, what
   ACM's "Cleaning up artifacts before reinstalling" script lists, the
   namespaces ACM made, and the hub's own agent for `local-cluster` if the
   uninstall left it ([A cluster that is managed by another
   hub](#a-cluster-that-is-managed-by-another-hub)). With `--full`, it also
   removes such an agent that an earlier uninstall left.
7. **OpenShift GitOps**: its Argo CD instance while the operator can still
   clean up after it, then the operator and the `openshift-gitops`
   namespace.
8. **Git**: once no `dr-role` Application reads it, `dr/` on the branch
   goes back to the roles the build starts from: the settings file's
   `ACTIVE` hub lists only `../roles/active`, the `PASSIVE` hub only
   `../roles/passive`, and the `restore-activate-*.yaml` one-shots of
   earlier git-driven failovers go (see [7. Git-driven paths
   only](#7-git-driven-paths-only-bootstrap-dr)). It commits on top of
   the branch on origin in a scratch worktree, pushes, and brings your
   checkout up to date if it is on that branch with no changes. Then it
   deletes the `failover-*`, `promote-*` and `demote-*` branches that
   `hack/dr.sh` pushed for its pull requests, on origin and in your
   checkout, once the branch has merged them; unmerged ones stay. A
   hub whose `dr-role` stays (one this repo did not create) keeps its
   overlay.
9. **Summary**: what is left of ACM, OpenShift GitOps and the ACM agent on
   each cluster, and the roles `dr/` gives each hub.

### What the teardown refuses

The pre-flight goes RED, and nothing is removed, when removing ACM or
OpenShift GitOps would take something that is not this repo's with it:

- **ACM also manages another cluster.** Removing the MultiClusterHub
  detaches every cluster it manages. Detach that cluster yourself first
  (see [A cluster that is managed by another
  hub](#a-cluster-that-is-managed-by-another-hub)), or keep that ACM: the
  default mode keeps an ACM that was there before the build.
- **ACM runs a DiscoveryConfig, an AgentServiceConfig or a
  MultiClusterObservability** (default mode only). The ACM uninstall needs
  them gone first, and this repo never creates them, so they belong to
  someone else. Remove them yourself, or use `--full`, which deletes them
  as the uninstall docs do.
- **Argo CD runs something this repo did not create**: an Application or
  ApplicationSet other than the demo's and `dr-role`, or an Argo CD
  instance outside `openshift-gitops`. Removing OpenShift GitOps deletes
  them. Move them to another cluster or delete them yourself, then run the
  teardown again; or use the default mode, which keeps a GitOps that was
  there before the build.

A spoke that runs an ACM agent but is listed by neither hub is reported,
not detached: its hub is elsewhere, and only that hub can detach it.

### A MultiClusterHub that does not go

The teardown waits up to 30 minutes for each MultiClusterHub to finish
uninstalling, then stops and prints its phase and conditions, which name
what it is still waiting for. The usual cause is a managed cluster that
has not finished detaching (`oc get managedclusters`; only
`local-cluster` may remain) or an add-on resource whose finalizer waits
for a controller. Resolve that, then run the teardown again: it carries on
from where it stopped, and runs ACM's cleanup script once the
MultiClusterHub is gone.

### A namespace that does not go

A namespace stays `Terminating` while an object in it keeps a finalizer,
usually because the operator that would clear the finalizer is already
gone. The teardown waits up to 15 minutes, then stops and prints the
namespace's conditions: `NamespaceContentRemaining` names the kinds still
there, `NamespaceFinalizersRemaining` the finalizers. To see the objects:

```bash
NS=<namespace>; C=<context>
oc --context $C api-resources --verbs=list --namespaced -o name \
  | xargs -n1 oc --context $C get -n $NS --ignore-not-found --show-kind -o name
```

If the operator that owns a finalizer is gone for good, clearing the
finalizer on that object by hand is the remaining way out
(`oc --context $C patch <kind>/<name> -n $NS --type merge -p
'{"metadata":{"finalizers":null}}'`). Do that only for objects of an
operator you have removed. Then run the teardown again.
