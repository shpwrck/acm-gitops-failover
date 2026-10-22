#!/usr/bin/env python3
"""Repo invariants that schema validation cannot see.

1. The manual (manifests/) and git-driven (dr/) copies of each DR object
   are identical, so the two paths cannot drift apart.
2. Each hub's dr-role bootstrap Application is excluded from ACM backups
   and reconciles its own overlay.
3. Each hub overlay renders a valid role: passive alone, or uniquely named
   activation one-shots matching the template, optionally with the active
   role (see dr/README.md).
4. Every Argo CD source points at the same repository, so a fork changes
   them together.
5. Relative links (and #anchors) in the Markdown docs resolve, and so do
   the doc sections the hack/ scripts link to (help_at).
6. Every object in manifests/ and dr/ carries the label
   app.kubernetes.io/part-of: acm-gitops-failover, which is how
   hack/teardown.sh tells this repo's objects from everything else.

Run from anywhere: hack/validate.py. Needs PyYAML and kustomize (or kubectl).
"""

import pathlib
import re
import shutil
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
DR = ROOT / "dr"
NOT_HUBS = {"bootstrap", "roles", "templates"}
STAMP = re.compile(r"^restore-acm-activate-(\d{12})$")
errors = []


def fail(msg):
    errors.append(msg)


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def kustomize(path):
    if shutil.which("kustomize"):
        cmd = ["kustomize", "build", str(path)]
    else:
        cmd = ["kubectl", "kustomize", str(path)]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode:
        fail(f"{path.relative_to(ROOT)}: kustomize build failed: {out.stderr.strip()}")
        return []
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def check_parity():
    pairs = [
        ("manifests/55-backupschedule.yaml", "dr/roles/active/backupschedule.yaml"),
        ("manifests/56-restore-passive.yaml", "dr/roles/passive/restore-passive.yaml"),
    ]
    for manual, gitops in pairs:
        a, b = load(manual), load(gitops)
        for key in ("apiVersion", "kind", "metadata", "spec"):
            if a.get(key) != b.get(key):
                fail(f"{manual} and {gitops} differ in {key}; change both or neither")
    manual = load("manifests/57-restore-activate.yaml")
    template = load("dr/templates/restore-activate.template.yaml")
    if manual["spec"] != template["spec"]:
        fail("manifests/57-restore-activate.yaml and dr/templates/restore-activate.template.yaml specs differ")
    if template["metadata"]["name"] != "restore-acm-activate-<UTCSTAMP>":
        fail("dr/templates/restore-activate.template.yaml must keep the name restore-acm-activate-<UTCSTAMP>")
    return template["spec"]


def check_bootstrap(hubs):
    for hub in hubs:
        path = DR / "bootstrap" / f"dr-role-{hub}.yaml"
        if not path.exists():
            fail(f"dr/{hub}/ has no bootstrap Application at {path.relative_to(ROOT)}")
            continue
        app = yaml.safe_load(path.read_text())
        rel = path.relative_to(ROOT)
        if app["metadata"]["name"] != "dr-role":
            fail(f"{rel}: Application must be named dr-role (the runbooks address it by name)")
        if (app["metadata"].get("labels") or {}).get("velero.io/exclude-from-backup") != "true":
            fail(f"{rel}: missing label velero.io/exclude-from-backup: \"true\" — "
                 "without it a restore delivers this hub's role to the other hub")
        if app["spec"]["source"]["path"] != f"dr/{hub}":
            fail(f"{rel}: source.path must be dr/{hub}")
    for path in sorted((DR / "bootstrap").glob("dr-role-*.yaml")):
        hub = path.stem.removeprefix("dr-role-")
        if hub != "rbac" and hub not in hubs:
            fail(f"{path.relative_to(ROOT)} has no matching dr/{hub}/ overlay")


def check_overlay(hub, template_spec):
    rel = f"dr/{hub}"
    objs = kustomize(DR / hub)
    schedules = [o for o in objs if o["kind"] == "BackupSchedule"]
    restores = [o for o in objs if o["kind"] == "Restore"]
    passive = [r for r in restores if r["spec"].get("veleroManagedClustersBackupName") == "skip"]
    activations = [r for r in restores if r not in passive]
    if not objs:
        fail(f"{rel}: renders nothing")
    if passive and len(objs) > 1:
        fail(f"{rel}: the passive restore must be the overlay's only object (the backup "
             "operator honors one Restore at a time and ignores Restores while a BackupSchedule runs)")
    for r in activations:
        name = r["metadata"]["name"]
        m = STAMP.match(name)
        if not m:
            fail(f"{rel}: activation restore {name!r} must be named restore-acm-activate-<UTCSTAMP> "
                 "(a fixed name makes the next activation a silent no-op)")
        elif not (DR / hub / f"restore-activate-{m.group(1)}.yaml").exists():
            fail(f"{rel}: {name} must live in {rel}/restore-activate-{m.group(1)}.yaml")
        if r["spec"] != template_spec:
            fail(f"{rel}: {name} spec differs from dr/templates/restore-activate.template.yaml")
    if schedules:
        return "active" + (" (activation one-shot still listed)" if activations else "")
    if activations:
        return "activating"
    return "passive" if passive else "unknown"


def check_repo_urls():
    urls = {}
    for path in [*ROOT.glob("manifests/*.yaml"), *(DR / "bootstrap").glob("*.yaml")]:
        for line in path.read_text().splitlines():
            m = re.match(r"\s*repoURL:\s*(\S+)", line)
            if m:
                urls.setdefault(m.group(1), []).append(str(path.relative_to(ROOT)))
    if len(urls) > 1:
        fail("Argo sources point at different repos: "
             + "; ".join(f"{u} in {', '.join(f)}" for u, f in urls.items()))
    return next(iter(urls), None)


PART_OF = ("app.kubernetes.io/part-of", "acm-gitops-failover")


def check_labels():
    paths = [*ROOT.glob("manifests/*.yaml"), *DR.glob("*/*.yaml")]
    for path in sorted(p for p in paths if p.name != "kustomization.yaml"):
        for doc in yaml.safe_load_all(path.read_text()):
            if not doc:
                continue
            labels = (doc.get("metadata") or {}).get("labels") or {}
            if labels.get(PART_OF[0]) != PART_OF[1]:
                fail(f"{path.relative_to(ROOT)}: {doc.get('kind')} {doc['metadata'].get('name')} lacks the label "
                     f"{PART_OF[0]}: {PART_OF[1]} (hack/teardown.sh would leave it behind)")


def slug(heading):
    heading = re.sub(r"[`*_]|<[^>]+>", "", heading).strip().lower()
    return re.sub(r"[^\w\- ]", "", heading).replace(" ", "-")


def anchors(md):
    found, in_code = set(), False
    for line in md.read_text().splitlines():
        if line.startswith("```"):
            in_code = not in_code
        elif not in_code and (m := re.match(r"#+\s+(.*)", line)):
            base, n = slug(m.group(1)), 0
            while (s := base if n == 0 else f"{base}-{n}") in found:
                n += 1
            found.add(s)
    return found


def check_links():
    link = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
    for md in sorted(ROOT.rglob("*.md")):
        if ".git" in md.parts:
            continue
        in_code = False
        for n, line in enumerate(md.read_text().splitlines(), 1):
            if line.startswith("```"):
                in_code = not in_code
            if in_code:
                continue
            for target in link.findall(line):
                if re.match(r"[a-z]+:", target):
                    continue
                path, _, anchor = target.partition("#")
                dest = (md.parent / path).resolve() if path else md
                where = f"{md.relative_to(ROOT)}:{n}"
                if not dest.exists():
                    fail(f"{where}: broken link {target}")
                elif anchor and dest.suffix == ".md" and anchor not in anchors(dest):
                    fail(f"{where}: no heading for #{anchor} in {dest.relative_to(ROOT)}")
    for sh in sorted((ROOT / "hack").glob("*.sh")):
        for n, line in enumerate(sh.read_text().splitlines(), 1):
            for target in re.findall(r"\bhelp_at\s+([\w./-]+(?:#[\w-]+)?)", line):
                path, _, anchor = target.partition("#")
                dest = ROOT / path
                where = f"{sh.relative_to(ROOT)}:{n}"
                if not dest.is_file():
                    fail(f"{where}: help_at names a missing file {path}")
                elif anchor and anchor not in anchors(dest):
                    fail(f"{where}: no heading for #{anchor} in {path}")


def main():
    hubs = sorted(p.name for p in DR.iterdir() if p.is_dir() and p.name not in NOT_HUBS)
    template_spec = check_parity()
    check_bootstrap(hubs)
    posture = {hub: check_overlay(hub, template_spec) for hub in hubs}
    repo = check_repo_urls()
    check_labels()
    check_links()

    print(f"Argo source repo: {repo}")
    for hub, role in posture.items():
        print(f"dr/{hub}: {role}")
    if sum(role.startswith("active") for role in posture.values()) != 1:
        print("note: not exactly one active hub in git (expected only mid-failover, between PR-B and the demote PR)")
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("all repo checks passed")


if __name__ == "__main__":
    main()
