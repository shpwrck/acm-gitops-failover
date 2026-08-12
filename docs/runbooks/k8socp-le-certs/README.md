---
leave-behind: v1
state-scope: k8socp-le-certs
status: current
---

# k8socp.com Let's Encrypt serving certs leave-behind

## Operability

### State and access

Durable state lives on all three OpenShift clusters (contexts `hub`,
`spoke`, `sage` in `~/.kube/config`, cluster-admin client certs embedded)
plus the Cloudflare zone `k8socp.com` and the Let's Encrypt ACME account
that cert-manager registered per cluster.

- Per cluster: cert-manager operator (Red Hat build v1.20.0, ns
  `cert-manager-operator`, channel `stable-v1`), operand in `cert-manager`;
  `ClusterIssuer letsencrypt-prod` (ACME prod, Cloudflare DNS-01);
  Certificates `openshift-ingress/apps-wildcard` (`*.apps.<c>.k8socp.com` →
  secret `apps-wildcard-tls`) and `openshift-config/api-cert`
  (`api.<c>.k8socp.com` → secret `api-tls`); IngressController `default`
  patched with `spec.defaultCertificate=apps-wildcard-tls`; APIServer
  `cluster` patched with a namedCertificate for `api.<c>.k8socp.com`.
  Renewal is automatic (cert-manager, ~30 days before expiry; current certs
  expire 2026-11-10).
- Credential: Cloudflare **global API key** + account email, in secret
  `cloudflare-api-key` (ns `cert-manager`) on each cluster and in
  `~/.acm-failover-cf-creds` (chmod 600, not in git) on the WSL box. Source
  of truth: the TrueNAS ACME DNS authenticator (`midclt call
  acme.dns.authenticator.query` via the UDM jump path — see the
  truenas-seaweedfs-s3 runbook for the access procedure). IMPROVEMENT
  CANDIDATE: mint a zone-scoped token in the Cloudflare dashboard and
  replace the global key in all four locations.
- Pre-existing state NOT owned by this scope: hub's cert-manager also
  serves a service-mesh CA (`mesh-root-ca`, `mesh-selfsigned-bootstrap`
  ClusterIssuers + `mesh-intermediate-hub-001`) — 84 days old, untouched.
- Local kubeconfig: `certificate-authority-data` pins were REMOVED from all
  three cluster entries (server trust now via system store, which includes
  LE); client-cert auth unchanged (`system:admin`). Backup:
  `~/.kube/config.bak-pre-le-20260812-1053`.

### Template map

~/acm-failover-guide/manifests/30-cert-manager-operator.yaml -> ns cert-manager-operator + OperatorGroup + Subscription (per cluster)
~/acm-failover-guide/manifests/31-letsencrypt-issuer.yaml (envsubst CF_EMAIL) -> ClusterIssuer letsencrypt-prod (per cluster)
~/acm-failover-guide/manifests/32-cluster-certs.yaml (envsubst CLUSTER) -> Certificates apps-wildcard + api-cert (per cluster)
~/acm-failover-guide/scripts/cluster-le-certs.sh <cluster> -> the whole chain end-to-end incl. IngressController/APIServer patches (verified on sage)

### Re-run

Prerequisites: `~/.acm-failover-cf-creds` present; cluster context works;
no conflicting cert-manager OperatorGroup (see Verify and recover).

```bash
~/acm-failover-guide/scripts/cluster-le-certs.sh <cluster>
# then, once the API serves LE (script waits for it):
oc config unset clusters.<cluster>.certificate-authority-data
```

Idempotent: applies are convergent, the secret is apply-updated, and
cert-manager only re-issues when the Certificate spec changes or renewal is
due.

### Verify and recover

```bash
for ep in console-openshift-console.apps.<c>.k8socp.com:443 api.<c>.k8socp.com:6443; do
  echo | openssl s_client -connect $ep -servername ${ep%:*} 2>/dev/null | openssl x509 -noout -issuer -enddate
done   # expect issuer O=Let's Encrypt, notAfter ~60-90 days out
oc --context <c> get certificate -A               # all Ready=True
oc --context <c> whoami                           # system:admin (client cert auth intact)
```

Failure paths: CSV `Failed/TooManyOperatorGroups` = a second OperatorGroup
in `cert-manager-operator` (hub had a pre-existing install; delete the
duplicate OG, CSV self-recovers). Certificate stuck NotReady → `oc describe
challenge -A` (DNS-01 propagation or Cloudflare auth). `oc` failing TLS
after the API patch = kubeconfig still pins the internal CA (unset it, or
restore from the backup above to roll back trust). Full rollback per
cluster: remove `spec.defaultCertificate` from the IngressController and
`spec.servingCerts.namedCertificates` from APIServer `cluster` — the
operators revert to self-signed defaults; then re-add the CA pin from the
kubeconfig backup.

## Decision log

### Decisions

- Per-cluster cert pairs, not one multi-SAN cert: apps cert lives in
  `openshift-ingress`, API cert in `openshift-config` — separate secrets
  are structurally required, and rotation stays independent.
- `*.apps.<c>.k8socp.com` + `api.<c>.k8socp.com` SANs; the user-suggested
  `*.<c>.k8socp.com` alone would not cover console (wildcards match one
  label). User informed, no objection.
- Cloudflare global API key reused from the TrueNAS ACME authenticator
  (verified zone-edit on k8socp.com by TXT create/delete first) because no
  scoped token existed and dashboard access wasn't available; flagged the
  scoped-token swap as follow-up.
- DNS-01 (not HTTP-01) because wildcards require it, and the clusters'
  ingress is not internet-reachable anyway (RFC1918 A records).
- ACM survives the API cert swap by construction: klusterlets connect to
  `https://kubernetes.default.svc:443` (internal CA). Verified on both hubs
  (local-cluster stayed Joined/Available through the rollout).
- kube-apiserver rollout time on SNO is the long pole (minutes), not
  issuance (~90 s for four certs).

### How to drive it

To add a cluster: run `scripts/cluster-le-certs.sh <name>` (context and
subdomain must match), then unset the kubeconfig CA pin. To change SANs:
edit `manifests/32-cluster-certs.yaml`, re-envsubst-apply, cert-manager
re-issues, the router/apiserver pick up the updated secret automatically.
To rotate the Cloudflare credential: update the TrueNAS authenticator, the
three `cloudflare-api-key` secrets, and `~/.acm-failover-cf-creds` together.
Watch renewals with `oc get certificate -A` (Ready flips during renewal);
nothing is scheduled manually. Record any new gotcha in the guide
(`~/acm-failover-guide/README.md` §2b) and this file, and commit both.
