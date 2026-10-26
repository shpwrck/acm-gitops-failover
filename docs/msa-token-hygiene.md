# Post-activation hygiene: the restored MSA token secret

An activation restore silently freezes ManagedServiceAccount (MSA) token
rotation on the new active hub until the restored token secret is deleted
and re-minted. Every path's runbook carries the fix (Manual Pull Path step
E.3) and the pre-flight check that catches a missed fix (step 0.2). This
page explains the mechanism.

## What goes wrong

After an activation, the `auto-import-account` ManagedServiceAccount for
each imported cluster reports

```
TokenReported: False — failed to update the token secret: secrets
"auto-import-account" is forbidden: cannot set an ownerRef on a resource
you can't delete
```

with `.status.tokenSecretRef` empty. On some activations the
`TokenReported` condition is missing entirely instead of `False`; the
cause and the fix are the same.

Version note: this happened on every ACM 2.17.0 activation. On ACM
2.17.3 it did not, on any of the nine activations from 2026-10-21 to
2026-10-26: about a minute after the claim, the restored secret carried
owner `ManagedServiceAccount` and a fresh 144 h expiry. Keep the check
in place either way; it costs one command.

The activation restore brings the hub-side token secret back as a plain
Velero object: the token is correct, but the secret has no
`ownerReferences` (its `velero.io/backup-name` and
`velero.io/restore-name` labels give it away). When the
`managed-serviceaccount` addon starts against the new hub and tries to
adopt the secret so it can rotate it, [Kubernetes' ownership admission
control](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#ownerreferencespermissionenforcement)
rejects the ownerReference update. The addon itself stays `Available`;
only rotation stops.

Nothing alerts. The restored token keeps working until its validity runs
out (144 h with this repo's `veleroTtl: 72h`, since the default is twice
the TTL), and only the *next* failover fails, in `Pending Import`, days
later, with the original cause long gone from the logs.

## The timing rule

- **During activation the restored secret is load-bearing.** It is the
  credential auto-import uses to reach the managed cluster. Never delete
  it before the cluster shows `Joined/Available` on the new hub.
- **After activation it is disposable.** Once the cluster is imported and
  the `managed-serviceaccount` addon is `Available`, delete the restored
  copy. The addon re-mints it within seconds under its own ownership, and
  rotation resumes:

  ```console
  $ oc --context $PASSIVE delete secret auto-import-account -n $MANAGED
  $ oc --context $PASSIVE get managedserviceaccount auto-import-account -n $MANAGED \
      -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status}{" | "}{.status.expirationTimestamp}{"\n"}'
  True | <now + 144h>
  $ oc --context $PASSIVE get secret auto-import-account -n $MANAGED \
      -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
  ManagedServiceAccount        # controller-owned again (the restored copy had none)
  ```

- **The fix is not DR-protected until the next credentials backup
  completes.** Until then the bucket's `latest` still holds the frozen
  token. Any hub-state repair inherits the backup cadence (30 minutes
  here) as its protection lag, which is the same number that anchors the
  RPO conversation. A new `BackupSchedule` fires its first backup set
  immediately, so on a freshly promoted hub the lag is under a minute.
- **On the passive hub the same restored secrets are harmless.** The sync
  restore keeps overwriting them and nothing there tries to adopt them.
  The cleanup applies only to a hub that just activated.

## How to check

Check the `TokenReported` condition, not just `tokenSecretRef` or the
expiry: a restored-but-frozen secret passes the weaker checks while
rotation is already dead. Treat "`False` or missing" as a failure.

```console
$ oc --context <active-hub> get managedserviceaccount -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TOKEN-REPORTED:.status.conditions[?(@.type=="TokenReported")].status,EXPIRES:.status.expirationTimestamp'
```

The `application-manager` MSA, which backs push delivery, re-mints itself
through its addon after activation. This cleanup protects the next
failover's auto-import; it does not gate push delivery's recovery.
