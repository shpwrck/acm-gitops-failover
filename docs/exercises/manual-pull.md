# Manual Pull Path — exercise record

The full manual exercise, verified live in both directions on
consecutive days: the forward run (2026-08-12), failback as a role
swap, and the reverse run (2026-08-13). The step-by-step procedure is
the [`dr-failover-pull-manual` runbook](../runbooks/dr-failover-pull-manual/README.md).

## The forward exercise (verified live, 2026-08-12)

Pre-flight (all checks passed): the load-bearing one is the MSA token —
`oc get managedserviceaccount auto-import-account -n <cluster>` on the
active hub must show `.status.tokenSecretRef`, an unexpired
`.status.expirationTimestamp`, **and `TokenReported: True`** (the
[MSA token finding](msa-token-hygiene.md) — a
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
  `https://api.hub-y.example.com:6443`; all 8 addons Available on the new
  hub.
- Post-failover step (documented, easy to forget): [create the
  `BackupSchedule` on the NEW
  primary](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#disaster-recovery)
  — failover is deliberately manual, and ACM's `backup-restore-enabled`
  policy exists to nag if you forget. Done at 15:2x.
- ROSA translation: identical procedure; the S3 bucket is real S3, and the
  hubs' `DataProtectionApplication` loses only the `s3Url`/`s3ForcePathStyle`
  lines.

## Failback as role swap (verified live)

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
  in the reverse direction is the same forward procedure with the roles
  renamed.

## The reverse exercise (verified live, 2026-08-13)

The whole forward procedure run in the opposite direction the next day —
hub-y (active since the forward exercise) killed, hub-x activated,
role-swap failback — driven end-to-end from the
[`dr-failover-pull-manual` runbook](../runbooks/dr-failover-pull-manual/README.md),
which this run validated step by step. Two deliberate differences from the
forward run: pre-flight found and fixed the frozen MSA rotation first (the
[MSA token finding](msa-token-hygiene.md) — fix
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
| 14:45:44 | — | [MSA token freeze](msa-token-hygiene.md) reproduced on hub-x: `TokenReported: False` → restored secret deleted → re-minted `True` |
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
  - **The [MSA token freeze](msa-token-hygiene.md) is systematic, not a
    one-off**: the freshly-activated hub
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
