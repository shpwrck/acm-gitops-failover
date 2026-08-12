#!/usr/bin/env bash
# Bootstrap Let's Encrypt serving certs (apps wildcard + API) on one
# k8socp.com cluster, end to end. Verified on sage 2026-08-12.
# Usage: ./cluster-le-certs.sh <cluster>   (cluster = kube context AND subdomain)
# Requires: ~/.acm-failover-cf-creds with CF_EMAIL / CF_API_KEY (chmod 600).
set -euo pipefail
CLUSTER=${1:-${CLUSTER:?usage: cluster-le-certs.sh <cluster>}}
DIR=$(cd "$(dirname "$0")/.." && pwd)
. ~/.acm-failover-cf-creds
export CF_EMAIL CLUSTER

oc --context "$CLUSTER" apply -f "$DIR/manifests/30-cert-manager-operator.yaml"

echo "waiting for cert-manager CSV..."
phase=""
for i in $(seq 1 60); do
  phase=$(oc --context "$CLUSTER" get csv -n cert-manager-operator -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}' 2>/dev/null | grep '^cert-manager' | head -1 || true)
  echo "t=$((i*10))s ${phase:-pending}"
  echo "$phase" | grep -q Succeeded && break
  sleep 10
done
echo "$phase" | grep -q Succeeded

for i in $(seq 1 30); do
  oc --context "$CLUSTER" -n cert-manager get deploy cert-manager-webhook >/dev/null 2>&1 && break
  sleep 5
done
oc --context "$CLUSTER" -n cert-manager wait --for=condition=Available deploy --all --timeout=5m

oc --context "$CLUSTER" create secret generic cloudflare-api-key -n cert-manager \
  --from-literal=api-key="$CF_API_KEY" --dry-run=client -o yaml | oc --context "$CLUSTER" apply -f -
envsubst < "$DIR/manifests/31-letsencrypt-issuer.yaml" | oc --context "$CLUSTER" apply -f -
envsubst < "$DIR/manifests/32-cluster-certs.yaml" | oc --context "$CLUSTER" apply -f -

echo "waiting for certificates (DNS-01)..."
oc --context "$CLUSTER" wait --for=condition=Ready certificate/apps-wildcard -n openshift-ingress --timeout=15m
oc --context "$CLUSTER" wait --for=condition=Ready certificate/api-cert -n openshift-config --timeout=15m

oc --context "$CLUSTER" patch ingresscontroller default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"defaultCertificate":{"name":"apps-wildcard-tls"}}}'
oc --context "$CLUSTER" patch apiserver cluster --type=merge \
  -p "{\"spec\":{\"servingCerts\":{\"namedCertificates\":[{\"names\":[\"api.$CLUSTER.k8socp.com\"],\"servingCertificate\":{\"name\":\"api-tls\"}}]}}}"

echo "watching served issuers flip to Let's Encrypt..."
for i in $(seq 1 60); do
  apps=$(echo | timeout 8 openssl s_client -connect "console-openshift-console.apps.$CLUSTER.k8socp.com:443" -servername "console-openshift-console.apps.$CLUSTER.k8socp.com" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
  api=$(echo | timeout 8 openssl s_client -connect "api.$CLUSTER.k8socp.com:6443" -servername "api.$CLUSTER.k8socp.com" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
  echo "t=$((i*20))s apps=[${apps#issuer=}] api=[${api#issuer=}]"
  echo "$apps" | grep -q "Let's Encrypt" && echo "$api" | grep -q "Let's Encrypt" && \
    { echo "DONE: $CLUSTER serving Let's Encrypt on apps + api"; exit 0; }
  sleep 20
done
echo "TIMEOUT waiting for issuer flip"; exit 1
