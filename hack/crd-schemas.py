#!/usr/bin/env python3
"""Download the CRDs this repo's manifests use and convert them to JSON
schemas for kubeconform.

The datreeio CRDs-catalog (used directly by validate.sh) covers Argo CD,
OLM and the core OCM kinds. Everything else is fetched here from the
upstream source at the release this repo targets (ACM 2.17, OADP 1.5,
OpenShift 4.21) and written as <out>/<group>/<kind>_<version>.json.

Usage: hack/crd-schemas.py <output-dir>
"""

import json
import pathlib
import sys
import urllib.request

import yaml

RAW = "https://raw.githubusercontent.com"
CRDS = [
    # BackupSchedule, Restore
    f"{RAW}/stolostron/cluster-backup-operator/release-2.17/config/crd/bases/cluster.open-cluster-management.io_backupschedules.yaml",
    f"{RAW}/stolostron/cluster-backup-operator/release-2.17/config/crd/bases/cluster.open-cluster-management.io_restores.yaml",
    # GitOpsCluster
    f"{RAW}/stolostron/multicloud-integrations/release-2.17/deploy/crds/apps.open-cluster-management.io_gitopsclusters.yaml",
    # KlusterletAddonConfig
    f"{RAW}/stolostron/klusterlet-addon-controller/release-2.17/deploy/agent.open-cluster-management.io_klusterletaddonconfigs_crd.yaml",
    # MultiClusterHub
    f"{RAW}/stolostron/multiclusterhub-operator/release-2.17/config/crd/bases/operator.open-cluster-management.io_multiclusterhubs.yaml",
    # DataProtectionApplication
    f"{RAW}/openshift/oadp-operator/oadp-1.5/config/crd/bases/oadp.openshift.io_dataprotectionapplications.yaml",
    # Route (an aggregated API on OpenShift; openshift/api ships a CRD form)
    f"{RAW}/openshift/api/release-4.21/route/v1/zz_generated.crd-manifests/routes.crd.yaml",
]


# Cross-field constraints (allOf/anyOf/oneOf/not) assume the API server has
# already applied defaults, so plain JSON-schema validation of an
# un-defaulted manifest gets them wrong. They are dropped; the server still
# enforces them.
COMBINATORS = ("allOf", "anyOf", "oneOf", "not")


def to_json_schema(node):
    """Translate an OpenAPI v3 CRD schema into JSON schema, closing every
    object (additionalProperties: false) so misspelled fields fail."""
    if isinstance(node, list):
        return [to_json_schema(n) for n in node]
    if not isinstance(node, dict):
        return node
    # Some upstream CRDs carry keys with null values (e.g. `anyOf: null`)
    out = {k: to_json_schema(v) for k, v in node.items()
           if v is not None and k not in COMBINATORS}
    if out.pop("x-kubernetes-int-or-string", False):
        out.pop("type", None)
        out["oneOf"] = [{"type": "string"}, {"type": "integer"}]
    if out.pop("nullable", False) and isinstance(out.get("type"), str):
        out["type"] = [out["type"], "null"]
    preserve = out.pop("x-kubernetes-preserve-unknown-fields", False)
    if "properties" in out and "additionalProperties" not in out and not preserve:
        out["additionalProperties"] = False
    return out


def main(outdir):
    out = pathlib.Path(outdir)
    for url in CRDS:
        with urllib.request.urlopen(url, timeout=60) as resp:
            crd = yaml.safe_load(resp.read())
        group = crd["spec"]["group"]
        kind = crd["spec"]["names"]["kind"].lower()
        for version in crd["spec"]["versions"]:
            schema = to_json_schema(version["schema"]["openAPIV3Schema"])
            path = out / group / f"{kind}_{version['name']}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(schema, indent=1))
            print(f"wrote {path}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
