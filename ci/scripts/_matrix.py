#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared ci/build-matrix.yaml loader/expander, used by ci/scripts/_compose_kasfiles.py, the
GitHub Actions read-matrix job, and ci/gitlab/read-matrix.yml - so the images:/machines:
expansion logic (and the incompatible-feature check) exists exactly once.

ci/build-matrix.yaml schema:
  machine_eula: {<machine>: true}   - machines needing EULA_<MACHINE>=1, same for every image.
  images:
    - target: <bitbake target>
      features: [<aglsetup-style feature name>, ...]
      sdk: bool
      tiers: [...]                  - default tiers for every machine below
      machines:
        - <machine name>                          - uses the image's default tiers
        - <machine name>: {tiers: [<override>]}   - per-machine tier override
  check_layers:                     - make validate's yocto-check-layer sub-check, see
                                       load_check_layers()
    dependency_roots: [<dir>, ...]  - recursively scanned for yocto-check-layer's --dependency
    layers:
      - <layer path>                             - LAYERDEPENDS-based auto-resolution alone
      - <layer path>: {additional_layers: [...]} - force-adds layers with no LAYERDEPENDS at all

expand_entries() flattens images:/machines: into the historical one-row-per-(machine,features,
target) shape (dicts with machine/features/target/sdk/eula/tiers keys) that every consumer
actually wants to filter/lookup against. load_check_layers() does the equivalent for
check_layers:.

Run directly (`python3 ci/scripts/_matrix.py`) to validate ci/build-matrix.yaml: checks for
INCOMPATIBLE_FEATURES violations and duplicate (machine, features, target) rows. Also run by
`make validate` / CI. `--list-check-layers` and `--check-layer-args` are query modes for
ci/scripts/validate.sh's yocto-check-layer invocation - see their docstrings below.
"""
import argparse
import os
import re
import sys
from pathlib import Path

import yaml

# Build tree = the agl-ucb checkout with the layer repos cloned inside (scripts/kas, base.yml url/branch).
# Every layer repo that has ci/build-matrix.yaml contributes its own images. AGL_SCOPE=<repo> limits
# the run to that repo plus every repo that (transitively) lists it under `needs:` - the downstream chain.
TREE = Path(os.environ.get("AGL_TREE", ".")).resolve()
WORKDIR = os.environ.get("AGL_WORKDIR", "/work")   # where the tree is mounted for tools run via kas-container

# Feature pairs that must never appear together in one images: entry. aglsetup.sh itself never
# checked this (purely additive), so this repo enforces it instead.
INCOMPATIBLE_FEATURES = [
    {"agl-kvm", "agl-xen"},  # two hypervisor backends, can't coexist on one image
]


# A build-matrix.yaml of the repo under test comes from the pull request, so it is untrusted input (a fork can change it). Its values
# end up in kas file paths, in shell strings of the build job and in artifact paths: accept only plain names, known tiers and a
# bounded number of entries. Everything here is checked when the matrix is loaded, so the matrix job fails before anything is built.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PATH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$")   # relative, no empty or dot-only component
TIERS = {"push-pr", "nightly", "release", "dispatch"}
MAX_ENTRIES = 128   # expanded entries of all repos in scope; GitHub allows 256 matrix jobs per workflow run


def _bad(repo, what, value):
    raise ValueError(f"{repo}/ci/build-matrix.yaml: {what} {value!r} is not allowed")


def _check_name(repo, what, value):
    if not isinstance(value, str) or not NAME_RE.match(value) or ".." in value:
        _bad(repo, what, value)


def _check_tiers(repo, what, tiers):
    if not isinstance(tiers, list) or not set(tiers) <= TIERS:
        _bad(repo, what, tiers)


def _check_repo_data(repo, d):
    """Reject anything in one repo's matrix file that is not a plain name, a known tier or a bounded size."""
    _check_name(repo, "repo name", repo)
    for r in d.get("needs", []):
        _check_name(repo, "needs entry", r)
    for m, v in (d.get("machine_eula") or {}).items():
        _check_name(repo, "machine_eula machine", m)
        if not isinstance(v, bool):
            _bad(repo, f"machine_eula value for {m}", v)
    for img in d.get("images", []):
        _check_name(repo, "target", img.get("target"))
        for f in img.get("features", []):
            _check_name(repo, "feature", f)
        if not isinstance(img.get("sdk"), bool):
            _bad(repo, f"sdk of {img.get('target')}", img.get("sdk"))
        if not isinstance(img.get("tiers"), str):
            _check_tiers(repo, f"tiers of {img['target']}", img.get("tiers"))
        if not isinstance(img.get("machines"), str):
            for m in img.get("machines", []):
                name = m if isinstance(m, str) else next(iter(m), None)
                _check_name(repo, "machine", name)
                if isinstance(m, dict) and "tiers" in (m[name] or {}):
                    _check_tiers(repo, f"tiers of {img['target']} on {name}", m[name]["tiers"])
    cl = d.get("check_layers") or {}
    for key in ("dependency_roots", "default"):
        for p in cl.get(key, []):
            if not isinstance(p, str) or not PATH_RE.match(p) or ".." in p.split("/"):
                _bad(repo, f"check_layers.{key} path", p)
    for entry in cl.get("layers", []):
        p = entry if isinstance(entry, str) else next(iter(entry), None)
        if not isinstance(p, str) or not PATH_RE.match(p) or ".." in p.split("/"):
            _bad(repo, "check_layers.layers path", p)
        if isinstance(entry, dict):
            for a in (entry[p] or {}).get("additional_layers", []):
                if not isinstance(a, str) or not PATH_RE.match(a) or ".." in a.split("/"):
                    _bad(repo, "check_layers additional_layers path", a)


def _needs_closure(repo, datas):
    """All repos that repo needs, directly or transitively."""
    seen, todo = set(), list(datas[repo].get("needs", []))
    while todo:
        r = todo.pop()
        if r not in seen:
            seen.add(r)
            todo += datas.get(r, {}).get("needs", [])
    return seen


def load_matrix():
    """Merge the build-matrix.yaml of every in-scope repo in the tree (images get a `repo` key)."""
    datas = {f.parent.parent.name: yaml.safe_load(f.read_text()) for f in sorted(TREE.glob("*/ci/build-matrix.yaml"))}
    scope = os.environ.get("AGL_SCOPE")
    if not datas:
        raise ValueError(f"no */ci/build-matrix.yaml under {TREE}")
    for r, d in datas.items():
        _check_repo_data(r, d or {})
    keep = [r for r in datas if not scope or r == scope or scope in _needs_closure(r, datas)]
    merged = {"machine_eula": {}, "images": [], "check_layers": {"dependency_roots": [], "layers": [], "default": []}}
    for repo in keep:
        d = datas[repo]
        merged["machine_eula"].update(d.get("machine_eula", {}))
        merged["images"] += [dict(i, repo=repo) for i in d.get("images", [])]
        cl = d.get("check_layers", {})
        merged["check_layers"]["dependency_roots"] += [r for r in cl.get("dependency_roots", []) if r not in merged["check_layers"]["dependency_roots"]]
        merged["check_layers"]["layers"] += cl.get("layers", [])
        merged["check_layers"]["default"] += [l for l in cl.get("default", []) if l not in merged["check_layers"]["default"]]
    return merged


def check_incompatible(features):
    """Returns the offending feature names if `features` contains two mutually-incompatible
    features, else None."""
    fset = set(features)
    for group in INCOMPATIBLE_FEATURES:
        hit = fset & group
        if len(hit) > 1:
            return hit
    return None


def _name_and_opts(entry):
    """Unpacks a build-matrix.yaml list item that's either a bare string or a single-key
    {name: {opts}} dict - the shape shared by images[].machines and check_layers.layers."""
    if isinstance(entry, str):
        return entry, {}
    (name, opts), = entry.items()
    return name, opts


DEFAULTS_FILE = Path(__file__).resolve().parent.parent / "matrix-defaults.yaml"   # ci/matrix-defaults.yaml, same commit as this script


def load_defaults():
    """The shared machine sets and tier presets (ci/matrix-defaults.yaml)."""
    d = yaml.safe_load(DEFAULTS_FILE.read_text()) or {}
    return d.get("machine_sets", {}), d.get("tier_presets", {})


def _lookup(table, name, what, target):
    if name not in table:
        raise ValueError(f"target {target!r}: unknown {what} {name!r}; known: {sorted(table)} (ci/matrix-defaults.yaml)")
    return table[name]


def expand_entries(data=None):
    data = data if data is not None else load_matrix()
    machine_eula = data.get("machine_eula", {})
    machine_sets, tier_presets = load_defaults()
    entries = []
    for img in data.get("images", []):
        machines, tiers, tiers_on = img["machines"], img["tiers"], {}
        if isinstance(machines, str):      # a name from machine_sets
            machines = _lookup(machine_sets, machines, "machine set", img["target"])
        if isinstance(tiers, str):         # a name from tier_presets
            preset = _lookup(tier_presets, tiers, "tier preset", img["target"])
            tiers, tiers_on = preset["default"], preset.get("machine_tiers", {})
        bad = check_incompatible(img["features"])
        if bad:
            raise ValueError(
                f"ci/build-matrix.yaml: target {img['target']!r} combines mutually-incompatible "
                f"features {sorted(bad)} - see INCOMPATIBLE_FEATURES in ci/scripts/_matrix.py"
            )
        for m in machines:
            name, overrides = _name_and_opts(m)
            tiers_here = overrides.get("tiers", tiers_on.get(name, tiers))
            if machine_eula.get(name, False) and "push-pr" in tiers_here:
                raise ValueError(f"{img.get('repo', '')}: target {img['target']!r} on {name!r} needs an EULA and must not be in tier push-pr")
            entries.append({
                "machine": name,
                "features": img["features"],
                "target": img["target"],
                "sdk": img["sdk"],
                "eula": machine_eula.get(name, False),
                "tiers": tiers_here,
                "repo": img.get("repo", ""),
            })
    if len(entries) > MAX_ENTRIES:
        raise ValueError(f"the matrix has {len(entries)} entries, more than the {MAX_ENTRIES} allowed")
    return entries


def load_check_layers(data=None):
    """Returns (dependency_roots, layers) from check_layers: - dependency_roots is the shared
    list of dirs yocto-check-layer's --dependency recursively scans; layers maps each checkable
    path to its additional_layers list (empty when LAYERDEPENDS-based auto-resolution via
    --dependency alone is sufficient - true for most AGL sublayers)."""
    data = data if data is not None else load_matrix()
    cl = data.get("check_layers", {})
    dependency_roots = cl.get("dependency_roots", [])
    layers = {}
    for entry in cl.get("layers", []):
        path, opts = _name_and_opts(entry)
        layers[path] = opts.get("additional_layers", [])
    return dependency_roots, layers


def validate_matrix():
    try:
        entries = expand_entries()
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    seen = set()
    dupes = 0
    for e in entries:
        key = (e["machine"], tuple(sorted(e["features"])), e["target"])
        if key in seen:
            print(f"error: duplicate matrix entry for {key}", file=sys.stderr)
            dupes += 1
        seen.add(key)

    print(f"ci/build-matrix.yaml: {len(entries)} expanded entries, {dupes} duplicate(s)")
    sys.exit(1 if dupes else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--list-check-layers", action="store_true",
        help="print every check_layers.layers path, one per line (resolves CHECK_LAYERS=all)",
    )
    ap.add_argument(
        "--default-check-layers", action="store_true",
        help="print the layers that validate.sh checks in addition to meta-agl-core by default (check_layers.default of the "
             "repos in scope, one per line; empty until a repo opts in)",
    )
    ap.add_argument(
        "--check-layer-args", nargs="+", metavar="LAYER",
        help="print the yocto-check-layer --dependency/--additional-layers clause for the "
             "given layer path(s) (paths as they appear in check_layers.layers), as one line "
             "ready to splice into the invocation - --dependency roots are always included, "
             "--additional-layers is the deduplicated union across all given layers, omitted "
             "entirely if none apply",
    )
    ap.add_argument(
        "--json", metavar="TIER",
        help="print {\"include\": [...]} with the expanded entries of TIER, for a GitHub Actions matrix",
    )
    ap.add_argument(
        "--repos", action="store_true",
        help="print the repos in scope (those whose images are in the merged matrix), one per line",
    )
    ap.add_argument(
        "--machine-eula", metavar="MACHINE",
        help="print whether MACHINE is in the machine_eula: table (True/False) - a flat "
             "machine-keyed lookup, independent of any (machine, features) matrix row, for "
             "callers (e.g. scripts/aglsetup.sh) that don't go through a matrix match at all",
    )
    args = ap.parse_args()

    if args.json:
        import json
        rows = [dict(e, features=",".join(e["features"])) for e in expand_entries() if args.json in e["tiers"]]
        print(json.dumps({"include": rows}))
        return

    if args.repos:
        print("\n".join(sorted({i["repo"] for i in load_matrix()["images"]})))
        return

    if args.machine_eula:
        print(load_matrix().get("machine_eula", {}).get(args.machine_eula, False))
        return

    if args.list_check_layers:
        _, layers = load_check_layers()
        for path in layers:
            print(path)
        return

    if args.default_check_layers:
        print("\n".join(load_matrix().get("check_layers", {}).get("default", [])))
        return

    if args.check_layer_args:
        roots, layers = load_check_layers()
        additional = []
        for l in args.check_layer_args:
            for a in layers.get(l, []):
                if a not in additional:
                    additional.append(a)
        parts = ["--dependency"] + [f"{WORKDIR}/{r}" for r in roots]
        if additional:
            parts += ["--additional-layers"] + [f"{WORKDIR}/{a}" for a in additional]
        print(" ".join(parts))
        return

    validate_matrix()


if __name__ == "__main__":
    main()
