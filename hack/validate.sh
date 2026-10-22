#!/usr/bin/env bash
# Offline validation: everything that can be checked without clusters.
# The same script runs in CI (.github/workflows/validate.yaml).
#
# Needs: python3 + PyYAML, yamllint, shellcheck, kubeconform, kustomize (or kubectl),
# and network access to fetch CRD schemas. The Mermaid render check runs
# when mmdc (@mermaid-js/mermaid-cli) is on PATH; SKIP_MERMAID=1 skips it.
set -euo pipefail

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

step() { printf '\n== %s\n' "$*"; }

step "yamllint"
yamllint -s .

step "shellcheck"
shellcheck -x hack/*.sh hack/lib/*.sh

step "kustomize build (every overlay and role)"
build() { if command -v kustomize >/dev/null; then kustomize build "$1"; else kubectl kustomize "$1"; fi; }
for dir in dr/*/ dr/roles/*/; do
  [ -f "$dir/kustomization.yaml" ] || continue
  build "$dir" >/dev/null
  echo "ok $dir"
done

step "kubeconform (strict, against upstream CRD schemas)"
python3 hack/crd-schemas.py "$work/schemas" >/dev/null
# The template's <UTCSTAMP> placeholder is not a valid name: validate a stamped copy.
sed 's/<UTCSTAMP>/202601010000/' dr/templates/restore-activate.template.yaml > "$work/restore-activate-stamped.yaml"
kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -schema-location "$work/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -skip Kustomization \
  manifests apps dr/bootstrap dr/roles "$work/restore-activate-stamped.yaml"

step "repo invariants and doc links"
python3 hack/validate.py

if [ "${SKIP_MERMAID:-0}" != 1 ] && command -v mmdc >/dev/null; then
  step "Mermaid diagrams render"
  echo '{"args":["--no-sandbox"]}' > "$work/puppeteer.json"
  grep -rl --include='*.md' --exclude-dir=.git '^```mermaid' . | while read -r md; do
    mkdir -p "$work/mmd/$(dirname "$md")"
    mmdc -q -p "$work/puppeteer.json" -i "$md" -o "$work/mmd/$md"
    echo "ok $md"
  done
else
  step "Mermaid diagrams: skipped (mmdc not found or SKIP_MERMAID=1)"
fi

printf '\nAll checks passed.\n'
