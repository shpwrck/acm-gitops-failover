---
leave-behind: v1
state-scope: truenas-seaweedfs-s3
status: current
---

# TrueNAS SeaweedFS S3 backup store leave-behind

## Operability

### State and access

Durable state lives on the TrueNAS SCALE box (25.10.4) at `192.168.17.1` /
`truenas.skrzypek.dev`. Access path: WSL cannot reach the NAS VLAN directly —
SSH via the UDM jump host (`root@192.168.1.1`, key auth; `sshpass` lives
there), then `truenas_admin@192.168.17.1` (password auth; same password works
for `sudo -S`). The OpenShift cluster VLAN (`172.16.10.x`) reaches the NAS
directly — verified from both `hub` and `spoke` nodes.

- TrueNAS app `seaweedfs` (stable catalog train, chart 1.2.32, SeaweedFS
  4.41, maintained by iX): 6 service containers (`ix-seaweedfs-{master,
  volume,filer,s3,admin,worker}-1`). App data under
  `/mnt/.ix-apps/app_mounts/seaweedfs/*` on the `kingston` pool (SSD, ~429G
  free at install).
- S3 API: `https://truenas.skrzypek.dev:30304` — TLS via TrueNAS certificate
  id 3 (`truenas-cloudflare`, actually a **Let's Encrypt** cert for
  `truenas.skrzypek.dev`, valid until 2026-10-02; trusted out-of-the-box by
  RHCOS nodes). Other published ports: admin 30300, master 30301, volume
  30302, filer 30303.
- S3 identity `velero` (actions Read/Write/List/Tagging/Admin), created via
  `weed shell s3.configure` — persisted in the filer store, survives app
  restarts. Anonymous access: denied (403), verified.
- Bucket: `acm-backups` (created via `weed shell s3.bucket.create`).
- Credential VALUES live in `~/.acm-failover-s3-creds` (chmod 600, NOT in
  git) on the WSL box: `S3_ACCESS_KEY`, `S3_SECRET_KEY`, plus
  `SEAWEED_ADMIN_PW` (app admin UI). The same S3 keys will be copied into
  the OADP `cloud-credentials` secrets on the hubs. Also retrievable via
  `weed shell` (`s3.configure` with no args lists identities) or
  `midclt call app.config seaweedfs` (admin password).
- Config knob that mattered: `seaweedfs.volume_size_limit_mb: 5000`
  (lowered from default 30000 — see Decisions).

### Template map

TrueNAS catalog app seaweedfs (stable train) + values {admin_user, admin_password, s3_port.certificate_id=3, volume_size_limit_mb=5000} -> running SeaweedFS S3 endpoint https://truenas.skrzypek.dev:30304 with data on kingston pool
weed shell s3.configure/-s3.bucket.create commands -> S3 identity velero + bucket acm-backups (persisted in filer)

### Re-run

Prerequisites: UDM jump path up; TrueNAS apps (Docker) service running;
certificate id 3 still valid in TrueNAS.

```bash
# All commands run on the NAS via:  ssh root@192.168.1.1 → sshpass ssh truenas_admin@192.168.17.1
# 1. Install app (idempotent-ish: app.create fails if it exists; use app.update to change values)
echo <pw> | sudo -S midclt call -j app.create '{"app_name":"seaweedfs","train":"stable","catalog_app":"seaweedfs","values":{"seaweedfs":{"admin_user":"admin","admin_password":"<SEAWEED_ADMIN_PW>","volume_size_limit_mb":5000},"network":{"s3_port":{"bind_mode":"published","port_number":30304,"certificate_id":3}}}}'
# 2. Wait for app state RUNNING (midclt call app.query)
# 3. S3 identity + bucket (idempotent: re-applying overwrites the same identity/bucket)
docker exec ix-seaweedfs-master-1 sh -c 'echo "s3.configure -access_key=<S3_ACCESS_KEY> -secret_key=<S3_SECRET_KEY> -user=velero -actions=Read,Write,List,Tagging,Admin -apply" | /usr/bin/weed shell -master=master:30301.30371'
docker exec ix-seaweedfs-master-1 sh -c 'echo "s3.bucket.create -name acm-backups" | /usr/bin/weed shell -master=master:30301.30371'
```

### Verify and recover

```bash
# From a cluster node (RHCOS): TLS trust + anonymous denial
oc --context hub debug node/hub -- chroot /host curl -s -o /dev/null -w '%{http_code}' https://truenas.skrzypek.dev:30304/acm-backups   # expect 403
# Signed round-trip — use a MODERN curl (>=8.x); RHCOS curl 7.76 --aws-sigv4 is
# BUGGY and returns SignatureDoesNotMatch falsely. On the NAS:
docker run --rm curlimages/curl -sk --aws-sigv4 aws:amz:us-east-1:s3 --user KEY:SECRET \
  -X PUT -d probe https://truenas.skrzypek.dev:30304/acm-backups/probe.txt   # expect 200
```

Failure paths: PUT returning 500 `InternalError` with s3 container logs
saying "No writable volumes and no free volumes left" = volume-slot
exhaustion (see Decisions; fix by lowering `volume_size_limit_mb` via
`app.update` or deleting empty volumes). App not RUNNING → `midclt call
app.query`, container logs via `docker logs ix-seaweedfs-<svc>-1`. Recovery:
the app is disposable — backups are re-creatable; `app.delete` + re-run
Re-run steps rebuilds from scratch (bucket data lost). Cert expiry (Oct
2026): renewals are TrueNAS-managed; if the cert id changes, `app.update`
with the new `certificate_id`.

## Decision log

### Decisions

- SeaweedFS chosen over MinIO because the user has no MinIO license
  (MinIO is AGPL; community edition degraded in 2025). Garage rejected for
  the same AGPL reason; versitygw (Apache-2.0) is the named fallback if
  SeaweedFS ever misbehaves with Velero. SeaweedFS is Apache-2.0, in the
  TrueNAS **stable** catalog train, and maintained by iX themselves.
- Hosted on TrueNAS (user decision), NOT on any cluster: the ACM backup docs
  require the storage location be reachable from all hubs at all times, and
  the store must survive the hub failure we simulate. This mirrors the
  customer's ROSA + real-S3 topology (external, region-durable store).
- TLS enabled with the existing Let's Encrypt cert (id 3) rather than plain
  HTTP: free fidelity to real S3, no caCert needed in the OADP
  DataProtectionApplication because RHCOS already trusts LE.
- `volume_size_limit_mb` lowered 30000→5000: with 234G free, the 30GB limit
  yields only ~7 auto volume slots, and SeaweedFS pre-created all 7 for the
  default collection at first start — leaving ZERO slots for the
  `acm-backups` collection (PUT → 500 "No writable volumes"). At 5GB the
  slot budget is ~46. Velero backup objects are small; 5GB volumes are ample.
- Verification gotcha worth keeping: RHCOS curl 7.76's `--aws-sigv4`
  produces false `SignatureDoesNotMatch` (canonicalization bugs, fixed in
  later curl). Signed-request verification must use curl ≥8 or an SDK
  (Velero uses aws-sdk-go and is unaffected).
- Port kept at the app default 30304 (not 9000) to stay stock with the
  TrueNAS chart; the endpoint URL is recorded everywhere it matters.

### How to drive it

Change app settings only via `midclt call -j app.update seaweedfs
'{"values": {...}}'` (never edit compose files under `/mnt/.ix-apps`
directly — the chart regenerates them). Manage identities/buckets via `weed
shell` in `ix-seaweedfs-master-1` (`s3.configure`, `s3.bucket.*`). After any
change, re-run the Verify block (403 anonymous + 200 signed PUT). Next
consumer of this state: OADP `DataProtectionApplication` on both hubs
pointing `s3Url: https://truenas.skrzypek.dev:30304`, bucket `acm-backups`,
`s3ForcePathStyle: "true"` — recorded, verified, in `docs/build.md`
(Phase 2a/2b).
