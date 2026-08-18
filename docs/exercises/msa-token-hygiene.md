# Post-activation hygiene: the restored MSA token secret (found 2026-08-13)

A cross-cutting finding cited by every path's record and runbook: an
activation restore silently freezes MSA token rotation until the restored
secret is deleted and re-minted.

Pre-flighting the [reverse exercise](manual-pull.md) the next morning
surfaced a silent
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

The [Manual Pull Path](manual-pull.md) pre-flight is upgraded
accordingly: check the `TokenReported`
condition, not just `tokenSecretRef`/expiry — a restored-but-frozen secret
can pass the weaker checks while rotation is already dead:

```console
$ oc --context <active-hub> get managedserviceaccount -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TOKEN-REPORTED:.status.conditions[?(@.type=="TokenReported")].status,EXPIRES:.status.expirationTimestamp'
```

**Re-verified 2026-08-18:** the freeze reproduced on newly-activated
hubs throughout a four-exercise re-verification day, and the fix behaved
identically every time (delete → controller-owned re-mint within
seconds, expiry now+144h). One variation observed: on one
freshly-activated hub the `TokenReported` condition was entirely ABSENT
rather than `False` — same underlying signature (a restored secret with
no `ownerReferences`), same fix. Check for "False **or missing**", not
just `False`. Also sharpened: the `application-manager` MSA (the push
credential) re-mints itself via its addon — this cleanup gates the next
failover's auto-import, not push delivery's resurrection.
