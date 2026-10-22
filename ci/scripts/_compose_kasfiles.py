#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Resolve a (machine, features[, target]) triple against ci/build-matrix.yaml and print
either the colon-joined kas file list (default) or one or more requested fields
(--fields NAME[,NAME...]), for consumption by the shell scripts in ci/scripts/ and by the
Makefile.

No per-combination kas file exists: the list is computed directly as
kas/base.yml:kas/machine/<machine>.yml:kas/feature/<f1>.yml:...:kas/pins.yml -
kas/pins.yml (a single consolidated file pinning every external repo's commit) is always
appended last, so it never needs a per-combination lockfile.

If the AGL_FLOATING env var is set, kas/floating.yml (no commit overrides - every repo floats
to the tip of its declared branch) is appended instead of kas/pins.yml. Local-only; CI never
sets this.

--target disambiguates when several images share the same (machine, features) - e.g. all 5
agl-demo images on one machine. It's required whenever more than one matrix entry matches;
omit it when only one does (unambiguous, matches pre-existing single-image usage).

--extra-features appends extra kas/feature/*.yml fragments on top of a matched matrix
entry's own features, WITHOUT affecting the matrix lookup itself - for local-only additions
like agl-devel (passwordless login) that are deliberately not part of any curated matrix
entry. Never used in CI.

--no-matrix skips the ci/build-matrix.yaml lookup entirely and just prints the kasfiles list
for whatever --machine/--features/--extra-features were given, with no requirement that the
combination match any curated entry (every fragment file must still exist). For
scripts/aglsetup.sh's free-form local exploration - never used by make build/validate/setup,
which stay matrix-gated.
"""
import argparse
import os
import sys
from pathlib import Path

# ci/scripts/ isn't a Python package (no __init__.py, deliberately - these are standalone CLI
# scripts, not a library), so importing the sibling _matrix.py needs its directory on sys.path
# first. Must happen before the import, hence the noqa (import-not-at-top-of-file).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _matrix import expand_entries  # noqa: E402

TREE = Path(os.environ.get("AGL_TREE", ".")).resolve()


def find_entries(machine, features):
    wanted = sorted(features)
    try:
        entries = expand_entries()
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    return [
        entry for entry in entries
        if entry["machine"] == machine and sorted(entry.get("features", [])) == wanted
    ]


def _kasfiles_list(machine, features, extra_features):
    """Builds the colon-joined kas file list and checks every fragment actually exists."""
    kasfiles = ["kas/base.yml", f"kas/machine/{machine}.yml"]
    kasfiles += [f"kas/feature/{f}.yml" for f in features]
    kasfiles += [f"kas/feature/{f}.yml" for f in extra_features]
    kasfiles.append("kas/floating.yml" if os.environ.get("AGL_FLOATING") else "kas/pins.yml")
    for f in kasfiles:
        if not (TREE / f).exists():
            print(f"error: {f} does not exist", file=sys.stderr)
            sys.exit(1)
    return ":".join(kasfiles)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", required=True)
    ap.add_argument("--features", default="", help="comma-separated feature list")
    ap.add_argument("--target", help="disambiguate when several images share the same machine+features")
    ap.add_argument("--extra-features", default="", help="comma-separated local-only extra features (e.g. agl-devel), not matrix-curated")
    ap.add_argument(
        "--fields",
        help="comma-separated field name(s) to print, one per line, instead of the kas file "
             "list. Each name is either a matrix entry field (target/sdk/eula/...) or the "
             "literal 'kasfiles' for the composed file list - lets a caller needing several "
             "fields (e.g. build.sh's target+sdk) make one matrix lookup instead of one "
             "invocation per field.",
    )
    ap.add_argument(
        "--no-matrix", action="store_true",
        help="skip the ci/build-matrix.yaml lookup, print the kasfiles list for whatever "
             "--machine/--features/--extra-features were given regardless of whether it "
             "matches any curated entry",
    )
    args = ap.parse_args()

    features = [f for f in args.features.split(",") if f]
    extra_features = [f for f in args.extra_features.split(",") if f]

    if args.no_matrix:
        print(_kasfiles_list(args.machine, features, extra_features))
        return

    matches = find_entries(args.machine, features)
    if args.target:
        matches = [e for e in matches if e.get("target") == args.target]

    if not matches:
        print(
            f"error: no ci/build-matrix.yaml entry for machine={args.machine} "
            f"features={features!r}"
            + (f" target={args.target}" if args.target else "")
            + " - add one to ci/build-matrix.yaml (and any missing kas/feature/*.yml "
            "fragment) before building this combination.",
            file=sys.stderr,
        )
        sys.exit(1)
    if len(matches) > 1:
        targets = ", ".join(sorted(e.get("target", "?") for e in matches))
        print(
            f"error: {len(matches)} ci/build-matrix.yaml entries match machine={args.machine} "
            f"features={features!r} - pass --target to disambiguate. Candidates: {targets}",
            file=sys.stderr,
        )
        sys.exit(1)
    entry = matches[0]

    if args.fields:
        for name in args.fields.split(","):
            if name == "kasfiles":
                print(_kasfiles_list(args.machine, features, extra_features))
            else:
                print(entry.get(name, ""))
        return

    print(_kasfiles_list(args.machine, features, extra_features))


if __name__ == "__main__":
    main()
