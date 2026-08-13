# DR exercise records

The verified record of every disaster exercise run against the
k8socp.com lab — timelines, findings, and measured RTOs, all observed
live on 2026-08-12/13. Section numbers (§3.x) are stable and are cited
from the [runbooks](runbooks/) and the [dr/](../dr/README.md) ledger;
the design these runs prove out is [design.md](design.md).

## 3. The DR exercise (verified live, 2026-08-12)

Pre-flight (all checks passed; the full checklist is in the
`acm-active-passive-dr` runbook): the load-bearing one is the MSA token —
`oc get managedserviceaccount auto-import-account -n <cluster>` on the
active hub must show `.status.tokenSecretRef`, an unexpired
`.status.expirationTimestamp`, **and `TokenReported: True`** (§3.3 — a
restored-but-frozen secret passes the weaker checks), and a backup must
have COMPLETED after that token existed. Bonus data point: the whole posture had just survived a full
three-cluster cold start with zero intervention (backups resumed, passive
sync resumed, app kept serving).

Timeline (hub-x = active, hub-y = passive, spoke = workloads):

| Clock | T+ | Event |
| --- | --- | --- |
| 15:22:32 | 0:00 | hub-x powered off (API dead) — datacenter loss |
| 15:23:38 | 1:06 | `REVISION v2` committed+pushed to git, no hub alive |
| 15:24:12 | 1:40 | on hub-y: passive `Restore` deleted, `57-restore-activate.yaml` applied ([activation restore docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-activation-resources)) |
| 15:24:49 | 2:17 | activation `Finished`; **spoke Import/Joined/Available on hub-y** (MSA auto-import ≤37 s) |
| 15:25:52 | 3:20 | hub-y regenerated the app ManifestWork; **route serving v2** |

- **App availability: 100%** — a 10-second probe never failed once through
  hub death, failover, and re-home. ([Hub loss is benign for managed
  clusters](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#backup-intro):
  "some features stop working, even if all managed clusters still work" —
  observed.)
- **Mid-outage deploys work**: spoke's local Argo pulled v2 from git while
  NO hub existed — [the pull model's whole
  point](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/gitops/index#arch-pull),
  observed.
- Proof of re-home: spoke's `bootstrap-hub-kubeconfig` now points at
  `https://api.hub-y.k8socp.com:6443`; all 8 addons Available on the new
  hub.
- Post-failover step (documented, easy to forget): [create the
  `BackupSchedule` on the NEW
  primary](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#disaster-recovery)
  — failover is deliberately manual, and ACM's `backup-restore-enabled`
  policy exists to nag if you forget. Done at 15:2x.
- ROSA translation: identical procedure; the S3 bucket is real S3, and the
  hubs' `DataProtectionApplication` loses only the `s3Url`/`s3ForcePathStyle`
  lines.

### 3.2 Failback as role swap (verified live)

The role swap was chosen over the [documented return-to-primary
mirror](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#restore-data-initial-hub):
the ex-primary comes back as the NEW passive, leaving the posture symmetric
and the exercise repeatable in the opposite direction.

| Clock | Event |
| --- | --- |
| 15:31:54 | hub-x API back; its view of spoke still STALE (`True/True`) |
| ~15:34 | spoke lease expired on hub-x → `Available=Unknown` |
| ≤15:36 | **`BackupCollision` fired on hub-x's old BackupSchedule** — it saw hub-y's newer backup in the shared bucket, from a different cluster id, and froze itself ([the documented collision guard](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prevent-backup-collision)) |
| 15:36:24 | defuse: old `BackupSchedule` deleted; stale `ManagedCluster spoke` deleted — [safe ONLY in `Unknown`: "If the status is not Unknown, your workloads are uninstalled from the managed cluster"](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#keep-hub-active-restore-clean) |
| 15:36:57 | hub-side cleanup complete — **15 s, zero stuck finalizers** |
| 15:38:45 | passive `Restore` applied and `Enabled` — hub-x is the new passive |

~7 minutes from hub-x power-on to symmetric posture; spoke and its app were
untouched throughout (availability probe: still zero failures across
failover AND failback). Probe footnote: the raw probe log (15:22–16:08)
shows failures beginning at 15:46:20 — that is the lab being powered off
for the day, 7+ minutes after failback completed, not a DR event; every
probe during the exercise window succeeded.

Caveats verified/noted:

- Wait out the lease: the returning hub shows moved clusters as `True` for
  the first ~2–4 minutes. Do NOT delete the ManagedCluster until it reads
  `Unknown`.
- Velero skips pre-existing same-name resources on restore, which is why
  [the docs prefer a CLEAN passive
  hub](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#prepare-new-hub).
  Harmless here: the ex-primary's leftover GitOps wiring is byte-identical
  to the backup content (both from the same git commits). On a real re-used
  hub, audit leftovers first.
- End state: hub-y ACTIVE (spoke + backups), hub-x PASSIVE (continuous
  restore), git the only workload source of truth. Re-running the exercise
  in the reverse direction is the same §3 procedure with the roles renamed.

### 3.3 Post-activation hygiene: the restored MSA token secret (found 2026-08-13)

Pre-flighting the reverse exercise the next morning surfaced a silent
failure the 2026-08-12 activation had left behind on the new active hub
(hub-y): the `auto-import-account` ManagedServiceAccount for spoke reported

```
TokenReported: False — failed to update the token secret: secrets
"auto-import-account" is forbidden: cannot set an ownerRef on a resource
you can't delete
```

with `.status.tokenSecretRef` empty — token rotation had been frozen since
the activation itself (condition timestamp 2026-08-12T19:25:28Z, within a
minute of the activation restore finishing).

Mechanics: the activation restore brings the hub-side token secret back as
a plain Velero object — correct token, but no `ownerReferences` (its
`velero.io/backup-name`/`velero.io/restore-name` labels give it away).
When the `managed-serviceaccount` addon then starts against the new hub
and tries to adopt the secret so it can rotate it, [Kubernetes' ownership
admission
control](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#ownerreferencespermissionenforcement)
rejects the ownerReference update. The addon itself stays `Available`;
only rotation dies. Nothing pages: the restored token keeps working until
its 144h validity expires (here 2026-08-18T15:40Z — it had been minted by
the old hub hours before it died), and only the NEXT failover fails — in
`Pending Import`, days later, with the original cause long out of the
logs.

The timing rule, now a standard runbook step:

- **During activation the restored secret is load-bearing.** It is the
  credential auto-import uses to reach the managed cluster. Never delete
  it before the cluster shows `Joined/Available`.
- **After activation it is disposable.** Once the cluster is imported and
  `managed-serviceaccount` is `Available`, delete the restored copy; the
  addon re-mints it within seconds under its own ownership, unfreezing
  rotation. Verified live (fix at 14:10:47Z):

  ```console
  $ oc --context hub-y delete secret auto-import-account -n spoke
  $ oc --context hub-y get managedserviceaccount auto-import-account -n spoke \
      -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status}{" | "}{.status.expirationTimestamp}{"\n"}'
  True | 2026-08-19T14:10:47Z
  $ oc --context hub-y get secret auto-import-account -n spoke \
      -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
  ManagedServiceAccount        # controller-owned again (restored copy had none)
  ```

- **The fix is not DR-protected until the next credentials backup
  completes.** Observed live: fix at 14:10:47Z, newest credentials backup
  14:00:23Z — the bucket kept serving the frozen token as `latest` until
  the 14:30Z set landed. Any hub-state repair inherits the backup cadence
  (here 30 min) as its protection lag — the same number that anchors the
  customer RPO conversation.
- **On the passive hub the same restored secrets are harmless** — the sync
  restore keeps overwriting them and nothing there tries to adopt them.
  This cleanup applies only to a hub that just *activated*.

The §3 pre-flight is upgraded accordingly: check the `TokenReported`
condition, not just `tokenSecretRef`/expiry — a restored-but-frozen secret
can pass the weaker checks while rotation is already dead:

```console
$ oc --context <active-hub> get managedserviceaccount -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TOKEN-REPORTED:.status.conditions[?(@.type=="TokenReported")].status,EXPIRES:.status.expirationTimestamp'
```

### 3.4 The reverse exercise (verified live, 2026-08-13)

The whole §3 procedure run in the opposite direction the next day — hub-y
(active since §3) killed, hub-x activated, role-swap failback — driven
end-to-end from the
[`dr-failover-exercise` runbook](runbooks/dr-failover-exercise/README.md),
which this run validated step by step. Two deliberate differences from §3:
pre-flight found and fixed the frozen MSA rotation first (§3.3 — fix
14:10:47Z, protecting credentials backup `Completed` 14:30:21Z), and the
disaster was a clean host shutdown through the API
(`oc --context hub-y debug node/hub-y -- chroot /host shutdown -h 1`) —
gentler on SNO etcd than a power cut; the variant belongs in the exercise
record because a customer will ask.

| Clock (UTC) | T+ | Event |
| --- | --- | --- |
| 14:34:12 | 0:00 | hub-y halted (scheduled shutdown fired; API dead within the minute) |
| ~14:35:30 | ~1:20 | `REVISION v3` committed+pushed to git, no active hub alive |
| ~14:39 | ~5:00 | spoke serving v3 (its local Argo's normal poll; hub-x still passive) |
| 14:42:09 | 7:57 | on hub-x: passive restore deleted, activation restore created |
| 14:42:19 | 8:07 | **spoke re-homed** — bootstrap pointer flip observed (10 s probe granularity) |
| ≤14:43 | ~9:00 | spoke `Joined/Available` on hub-x; all 8 addons `Available` |
| 14:45:44 | — | §3.3 reproduced on hub-x: `TokenReported: False` → restored secret deleted → re-minted `True` |
| 14:46:38 | — | `BackupSchedule` applied on hub-x; first full set fired immediately, `Completed` in seconds |
| +~15 min | — | hub-y powered on: spoke already `Unknown` (lease long expired), `BackupCollision` fired (hub-x id `4331cb00…` vs hub-y id `88d1a668…`), stale schedule + `ManagedCluster` + activation restore deleted, passive restore `Enabled` |

- **Availability: 0 non-200 responses across the entire window**
  (`grep -cv ' 200$'` over the 10 s probe log = 0) — zero downtime in this
  direction too, through kill, mid-outage deploy, activation, and
  failback.
- **Decision-to-re-home ≈10 s** (activation restore 14:42:09 → pointer
  flip 14:42:19). The 8-minute T+ total is dominated by the deliberate
  mid-outage-deploy demonstration, not by the machinery.
- New findings, all folded into the exercise runbook:
  - **§3.3 is systematic, not a one-off**: the freshly-activated hub
    reproduced the frozen `TokenReported` exactly as predicted, and the
    same fix worked — post-activation secret cleanup is a permanent step.
  - A new `BackupSchedule` fires its first full backup set immediately on
    creation (no wait for the cron slot), so the new active hub's
    repair-to-protection lag at failover is under a minute.
  - The backup operator stamps an `acm-restore-clusters-<ts>` safety
    backup at activation time — expected artifact, not an anomaly.
  - **A demoted hub keeps its `Finished` `restore-acm-activate` — delete
    it during demotion.** Left in place, the NEXT activation's `oc apply`
    of the same manifest is a silent no-op (identical spec, nothing
    re-triggers): a "successful" apply and no failover, at the worst
    possible moment.
  - A hub that was down longer than the lease window wakes with its moved
    clusters already `Unknown` — the 2–4 minute wait applies only to short
    outages.
- End state: **hub-x ACTIVE, hub-y PASSIVE, spoke untouched — the original
  posture, restored by exercising the DR machinery in both directions on
  consecutive days.**

### 3.5 Path 2: failover as a pull request (verified live, 2026-08-13)

The git-driven flip run twice against the restored posture (hub-x active,
hub-y passive), driven by the
[`dr-failover-gitops` runbook](runbooks/dr-failover-gitops/README.md).
Kill variant both times: `shutdown -r +1` (self-recovering graceful
reboot — no out-of-band dependency; SNO stays API-dead ~8 min).

**Attempt 1 (17:32–17:57Z) — falsified the one-PR design.** Kill
17:32:04Z; API dead 17:33:23Z; `REVISION v4` committed hubless 17:34:09Z;
failover PR #1 merged 17:35:26Z after the death-gate review. Then two
failure modes in one run: the active role's BackupSchedule arrived in the
same Argo sync as the activation Restore, and the operator **ignored the
restore** ("This resource is ignored because BackupSchedule resource
schedule-acm is currently active"); the premature schedule then
immediately wrote hub-y's **passive state over the bucket's `latest`**,
so a re-run restore "succeeded" restoring nothing. hub-x rebooted back
with spoke untouched; revert PR #2 restored the symmetric posture; hub-x's
schedule (selfHeal-recreated after deleting the collision-frozen object)
healed `latest` within a minute. Zero downtime throughout. The fix —
**failover = activation PR-A, then promotion PR-B** — landed as 96c22ab.

**Attempt 2 (18:00–18:15Z) — verified with the two-PR choreography:**

| Clock (UTC) | T+ | Event |
| --- | --- | --- |
| 18:00:12 | 0:00 | hub-x killed (scheduled reboot; API dead 18:01:28) |
| 18:01:51 | 1:39 | `REVISION v5` committed+pushed, no hub alive (served by spoke ~3 min later) |
| 18:02:09 | 1:57 | **PR-A merged** (activation-only; death-gate evidence in review comment) |
| 18:02:14 | 2:02 | hub-y's Argo synced (refresh annotation): passive Restore pruned — but the activation one-shot was evaluated first and permanently ignored (V1 race, "only one Restore honored at a time") |
| 18:07:58 | 7:46 | V1 recovery: ignored one-shot deleted; selfHeal re-created it in 6 s |
| 18:08:09 | 7:57 | restore `Finished`; **spoke `Joined/Available` on hub-y** (pointer flip 18:08:11 — delete→claim 11 s) |
| 18:09:05 | 8:53 | **promotion PR-B merged** → BackupSchedule; first full set `Completed` (18:09:54) |
| 18:09:29 | 9:17 | **demote PR merged while hub-x still down** |
| 18:13:29 | — | returned hub's Argo pruned its stale schedule before it fired anything (V3 benign); passive restore `Enabled` 18:13:39 |
| 18:14:06 | — | G.3/G.5 residue on hub-x; 18:14:53 §3.3 token re-mint on hub-y (third consecutive reproduction — it is systematic) |

- **Availability: zero non-200s** in both probe logs (pull and push apps)
  across both attempts — two hub deaths, no workload blip.
- **The machinery is tens of seconds; the audit trail is the cost.**
  Merge→sync ≈5 s (refresh annotation), restore→claim 11 s. Attempt 2's
  6-minute merge→claim wall clock was V1 *detection and recovery* — now a
  documented 30-second runbook step (delete the ignored one-shot; never
  hand-apply).
- Verdict details: [dr/README.md](../dr/README.md) verification ledger
  (V1 falsified→fixed, V3 benign, V4 measured; V5 open until hub-y's
  next demote).

### 3.6 Path 3: what a hub outage costs push delivery (verified live, 2026-08-13)

Manual failover with the push app under test (ACTIVE=hub-y, PASSIVE=hub-x),
run 18:30–18:40Z, driven by the
[`dr-failover-push-manual` runbook](runbooks/dr-failover-push-manual/README.md):

| Clock (UTC) | Event |
| --- | --- |
| 18:30:19 | pre-flight 0.3 gate: credentials set newer than the §3.3 fix `Completed` — the fix's protection lag was 15.5 min, the RPO number live |
| 18:30:38 | hub-y killed (self-recovering variant); API dead 18:31:57 |
| 18:32:15 | **C' inverted teaching moment**: push `v2` + pull `v6` committed, no active hub — push RTO clock starts |
| 18:32:26 | D.0 break-glass on hub-x (suspend `dr-role`) — D.1's delete then held (no 6 s selfHeal resurrection) |
| 18:32:53 | D.2 manual activation applied → spoke `Joined/Available` on hub-x 18:33:03 (**10 s**, pointer flip same second) |
| 18:34:37 | MSA token re-minted (§3.3 hygiene), GitOps cluster secret re-minted (1→2) |
| 18:34:48 | pull route serves `v6` — ordinary poll latency, zero outage term |
| 18:35:08 | push app `Synced`, **route serves `v2` — push delivery RTO 2 min 53 s** |
| 18:35:41 | F.1 schedule on hub-x; first set `Completed` immediately (fresh token captured) |
| 18:36:43 | hub-y returns (~4.8 min down), stale `spoke True/True`, dr-role reasserting active |
| 18:37:34 | operator-at-return break-glass: hub-y's `dr-role` suspended before touching role objects |
| 18:39:06 / 18:39:16 | spoke lease expires (`Unknown`) / **`BackupCollision` freezes hub-y's schedule — third observation, froze before writing a byte** |
| 18:39:28–18:40:04 | G.2/G.3/G.4/G.5 residue; hub-y passive-sync `Enabled` |
| be20031 | git re-aligned to manual reality (D.0 afterwards-contract), both dr-roles re-enabled — **adoption verified** (object creation timestamps preserved) |

- **The number the path exists for:** push delivery RTO **2:53** =
  operator decision latency (38 s) + activation (10 s) + MSA/cluster-secret
  chain (~95 s) + appset sync and push (~30 s). The pull app's same-window
  "RTO" was its ~2.5 min poll — structurally zero outage contribution. In a
  real disaster the operator term dominates: pull stays flat while push
  grows with every minute of decision time.
- **Both apps served continuously** — the push app's Argo dying uninstalls
  nothing (customers doubt this; the probe log is the receipt).
- The E' resurrection chain was observed strictly ordered: MSA token →
  cluster secret → app sync → route flip; §3.3 hygiene stays FIRST (the
  push credential is the same MSA family).

### 3.7 Path 4: the composed exercise (verified live, 2026-08-13)

The full composition — git-driven operation with push delivery under
measurement (ACTIVE=hub-x, PASSIVE=hub-y), run 18:43–18:53Z, closing the
2×2:

| Clock (UTC) | Event |
| --- | --- |
| 18:43:48 | hub-x killed (self-recovering variant); API dead 18:45:06 |
| 18:45:11 | push `v3` (RTO clock) + pull `v7` committed, no active hub |
| 18:45:31 | **PR-A merged** (death-gate evidence in review) |
| 18:45:37 | V1 race detected in 6 s (`ignored … passive-sync currently active`) — now a routine step |
| 18:45:48→59 | recovery delete → selfHeal re-run → **spoke `True/True` on hub-y; merge→claim 28 s total** |
| 18:46:54 | §3.3 token + cluster-secret re-mint (fourth consecutive reproduction) |
| 18:47:56 | **push route serves `v3` — delivery RTO 2 min 45 s**, beating manual path 3's 2:53 |
| 18:48:30 / 18:48:38 | promotion PR-B merged (first backup set `Completed` 18:48:42) / demote PR merged, hub-x still down |
| 18:51:30→41 | returned hub-x: **`BackupCollision` first, prune 10 s later** — V3's other order, benign both ways across paths 2+4 |
| 18:52:11 / 18:52:41 | spoke `Unknown` on hub-x / pull `v7` serving (one slow ~7.5 min poll cycle — jitter, not outage) |
| 18:53:00 | G.3 stale-claim delete — posture symmetric: hub-y ACTIVE, hub-x PASSIVE |

- **The matrix's slowest cell beat its manual sibling**: PR merge→claim
  took 28 s (V1 recovery included), less than path 3's 38 s operator
  typing latency — so the audit trail was free. In a real disaster the
  decision dominates both, and the PR *is* the decision record.
- Probe verdict for the whole day — §3.4 plus three exercises, four hub
  deaths: **zero non-200 responses on either app** (710+ samples each).
