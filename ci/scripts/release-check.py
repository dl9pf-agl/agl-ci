#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check the kas provenance statement of ONE release image against the release pins file and the image's sums file.

  release-check.py --statement <target>.provenance.json --pins pins_<branch>_<version>.yml --sums <target>.SHA256SUMS --target <target>

Why: kas writes the statement INSIDE the build job, so by itself it is only a claim of that job. The attest job (a separate job)
runs this check before it signs anything, so that the signed provenance says only what matches the pins file of the tag.
It fails (exit 1, one line per failed check) unless ALL of these hold:
  1. it is an in-toto Statement v1 with the SLSA provenance v1 predicate;
  2. internalParameters is empty (kas ran with --provenance mode=min; mode=max would put values of the environment, like
     mirror and hash-server addresses, into a public statement);
  3. externalParameters.target is exactly [<target>];
  4. every repo in resolvedDependencies is in the pins file, at exactly the pinned commit, and is not dirty;
  5. the statement embeds kas/pins.yml and that content is byte-identical to the pins file (so the build really used it);
  6. the sums file lists <target>.provenance.json with the sha256 of the statement file (the statement belongs to these files).
"""
import argparse
import base64
import hashlib
import json
import sys
from pathlib import Path

import yaml

STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
PREDICATE_TYPE = "https://slsa.dev/provenance/v1"

failures = []   # one text per failed check; printed at the end


def check(ok, passed_text, failed_text):
    # Record the result of one check. Passing is printed at once, failing is collected and decides the exit code.
    if ok:
        print(f"ok:   {passed_text}")
    else:
        print(f"FAIL: {failed_text}")
        failures.append(failed_text)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--statement", required=True)
    ap.add_argument("--pins", required=True)
    ap.add_argument("--sums", required=True)
    ap.add_argument("--target", required=True)
    a = ap.parse_args()

    stmt_bytes = Path(a.statement).read_bytes()
    stmt = json.loads(stmt_bytes)
    pred = stmt.get("predicate") or {}
    bd = pred.get("buildDefinition") or {}

    # 1. The kind of document. Anything else is not what kas writes and not what the verifiers expect.
    check(stmt.get("_type") == STATEMENT_TYPE and stmt.get("predicateType") == PREDICATE_TYPE,
          "statement is in-toto v1 with the SLSA provenance v1 predicate",
          f"wrong statement kind: _type={stmt.get('_type')!r} predicateType={stmt.get('predicateType')!r}")

    # 2. mode=min leaves internalParameters empty; mode=max puts the environment values there.
    check(not bd.get("internalParameters"),
          "internalParameters is empty (mode=min)",
          "internalParameters is not empty: kas ran in mode=max and the statement holds environment values")

    # 3. The target kas was asked to build. kas records a list when --target was given and null when only an environment
    #    variable was used, so the build must pass --target (build.sh does).
    check((bd.get("externalParameters") or {}).get("target") == [a.target],
          f"target is [{a.target}]",
          f"externalParameters.target is {(bd.get('externalParameters') or {}).get('target')!r}, expected [{a.target!r}]")

    # 4. The repos. The pins file is `overrides: repos: {name: {commit}}`; every repo kas used must be pinned there at that commit.
    pins_bytes = Path(a.pins).read_bytes()
    pins = {n: (r or {}).get("commit") for n, r in ((yaml.safe_load(pins_bytes) or {}).get("overrides") or {}).get("repos", {}).items()}
    deps = bd.get("resolvedDependencies") or []
    repos = [d for d in deps if "digest" in d]           # repos have a digest; the embedded config files have content
    bad = []
    for d in repos:
        name = d.get("name")
        commit = (d.get("digest") or {}).get("gitCommit")
        if name not in pins:
            bad.append(f"{name}: not in the pins file")
        elif commit != pins[name]:
            bad.append(f"{name}: used {commit}, pinned {pins[name]}")
        if (d.get("annotations") or {}).get("dirty"):
            bad.append(f"{name}: dirty (uncommitted changes in the checkout)")
    check(repos and not bad,
          f"{len(repos)} repos, all at their pinned commit and clean",
          "repos do not match the pins file: " + ("; ".join(bad) if bad else "the statement lists no repo"))

    # 5. kas embeds the content of the config files that are not part of a checked-out repo, agl-ucb's own kas/*.yml among them.
    #    In a release run kas/pins.yml IS the release pins file (the workflow copies it there), so the embedded copy must be identical.
    embedded = [d for d in deps if d.get("name") == "kas/pins.yml" and "content" in d]
    same = len(embedded) == 1 and base64.b64decode(embedded[0]["content"]) == pins_bytes
    check(same,
          "the build used this pins file (embedded kas/pins.yml is identical)",
          "the statement does not embed kas/pins.yml, or its content differs from the release pins file")

    # 6. The sums file: lines `<sha256>  <name>`. The statement must be listed with the hash of the file we have.
    sums = {}
    for line in Path(a.sums).read_text().splitlines():
        if line.strip():
            h, _, n = line.partition("  ")
            sums[n] = h
    name = f"{a.target}.provenance.json"
    check(sums.get(name) == hashlib.sha256(stmt_bytes).hexdigest(),
          f"the sums file lists {name} with the hash of the statement",
          f"the sums file does not list {name} with the sha256 of the statement file")

    if failures:
        print(f"release-check: {len(failures)} check(s) failed")
        sys.exit(1)
    print("release-check: all checks passed")


if __name__ == "__main__":
    main()
