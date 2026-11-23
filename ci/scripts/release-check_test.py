#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Test of release-check.py: one good fixture, then one deliberate fault at a time; each fault must make the check fail.
Run: python3 ci/scripts/release-check_test.py   (needs PyYAML, nothing else; the temporary directory is left in place, path printed).

The statement is shaped like the one kas 5.5 wrote in the CI run of 2026-11-23 (meta-agl run 45170294848, mode=min): a Statement v1,
repos in resolvedDependencies with a gitCommit and a dirty annotation, and the content of agl-ucb's kas/*.yml embedded in base64.
"""
import base64
import copy
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "release-check.py"
TARGET = "agl-image-minimal"
SHA = lambda n: f"a{n:039x}"   # a fake 40-hex commit id (starts with a letter, see prepare-release_test.sh)

# What the release pins file says; the statement below matches it.
PINS_TEXT = f"""# release pins
header:
  version: 22
overrides:
  repos:
    meta-agl:
      commit: {SHA(1)}
    bitbake:
      commit: {SHA(2)}
    meta-openembedded:
      commit: {SHA(3)}
"""


def good_statement():
    """A statement that matches PINS_TEXT: the repos at the pinned commits, clean, kas/pins.yml embedded, target given."""
    def repo(name, commit, dirty=False):
        return {"name": name, "uri": f"git+https://example.org/{name}.git", "digest": {"gitCommit": commit},
                "annotations": {"dirty": dirty, "layers": []}}
    return {
        "_type": "https://in-toto.io/Statement/v1",
        "predicateType": "https://slsa.dev/provenance/v1",
        "subject": [{"name": "x.manifest", "digest": {"sha256": "0" * 64}}],
        "predicate": {
            "buildDefinition": {
                "buildType": "https://kas.readthedocs.io/en/5.5/userguide/project-configuration.html",
                "externalParameters": {"command": "build", "config": ["kas/base.yml", "kas/pins.yml"], "target": [TARGET], "task": None},
                "internalParameters": {},                                        # mode=min
                "resolvedDependencies": [
                    repo("meta-agl", SHA(1)), repo("bitbake", SHA(2)), repo("meta-openembedded", SHA(3)),
                    {"name": "kas/base.yml", "content": base64.b64encode(b"header: {version: 22}\n").decode(), "mediaType": "application/vnd.kas+yaml"},
                    {"name": "kas/pins.yml", "content": base64.b64encode(PINS_TEXT.encode()).decode(), "mediaType": "application/vnd.kas+yaml"},
                ],
            },
            "runDetails": {"builder": {"id": "https://github.com/siemens/kas"}, "metadata": {"invocationId": "https://example.org/run/1"}},
        },
    }


t = Path(tempfile.mkdtemp(prefix="release-check-test."))
print(f"test directory: {t}")
fails = 0


def run(name, statement=None, pins_text=PINS_TEXT, target=TARGET, sums_override=None):
    """Write the three input files into a new directory `name` and run the tool; returns (exit code, output)."""
    d = t / name
    d.mkdir()
    stmt_bytes = json.dumps(statement if statement is not None else good_statement(), indent=1).encode()
    (d / "stmt.json").write_bytes(stmt_bytes)
    (d / "pins.yml").write_text(pins_text)
    # The sums file lists the statement under <target>.provenance.json with its real hash, plus an image file.
    sums = sums_override if sums_override is not None else (
        f"{hashlib.sha256(stmt_bytes).hexdigest()}  {TARGET}.provenance.json\n{'b' * 64}  {TARGET}-m.ext4.xz\n")
    (d / "sums").write_text(sums)
    p = subprocess.run([sys.executable, str(TOOL), "--statement", str(d / "stmt.json"), "--pins", str(d / "pins.yml"),
                        "--sums", str(d / "sums"), "--target", target], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def expect(name, want_ok, text=None, **kw):
    """Run one case; it must pass (want_ok) or fail with `text` in the output."""
    global fails
    rc, out = run(name, **kw)
    good = (rc == 0) if want_ok else (rc != 0 and (text is None or text in out))
    print(("ok:   " if good else "FAIL: ") + name + ("" if good else f"\n{out}"))
    fails += 0 if good else 1


def mutated(fn):
    """A copy of the good statement changed by fn."""
    s = copy.deepcopy(good_statement())
    fn(s)
    return s


bd = lambda s: s["predicate"]["buildDefinition"]
repos = lambda s: [d for d in bd(s)["resolvedDependencies"] if "digest" in d]

# The good case, then one fault at a time.
expect("good statement passes", True)
expect("a repo at another commit than pinned", False, "used", statement=mutated(lambda s: repos(s)[0]["digest"].update(gitCommit=SHA(9))))
expect("a dirty repo", False, "dirty", statement=mutated(lambda s: repos(s)[1]["annotations"].update(dirty=True)))
expect("a repo that the pins file does not have", False, "not in the pins file",
       statement=mutated(lambda s: bd(s)["resolvedDependencies"].append(
           {"name": "meta-extra", "digest": {"gitCommit": SHA(7)}, "annotations": {"dirty": False}})))
expect("environment values in the statement (mode=max)", False, "mode=max", statement=mutated(lambda s: bd(s).update(internalParameters={"env": {"X": "1"}})))
expect("target not given to kas (null)", False, "externalParameters.target", statement=mutated(lambda s: bd(s)["externalParameters"].update(target=None)))
expect("another target", False, "externalParameters.target", target="other-image")
expect("wrong statement version", False, "wrong statement kind", statement=mutated(lambda s: s.update(_type="https://in-toto.io/Statement/v0.1")))
expect("wrong predicate type", False, "wrong statement kind", statement=mutated(lambda s: s.update(predicateType="https://example.org/other")))
expect("a statement without repos", False, "no repo", statement=mutated(lambda s: bd(s).update(resolvedDependencies=[])))
expect("pins.yml not embedded", False, "does not embed",
       statement=mutated(lambda s: bd(s).update(resolvedDependencies=[d for d in bd(s)["resolvedDependencies"] if d.get("name") != "kas/pins.yml"])))
expect("embedded pins.yml differs from the release pins file", False, "differs", pins_text=PINS_TEXT + "# changed after the build\n")
expect("statement not listed in the sums file", False, "does not list", sums_override=f"{'b' * 64}  {TARGET}-m.ext4.xz\n")
expect("statement listed with another hash", False, "does not list", sums_override=f"{'c' * 64}  {TARGET}.provenance.json\n")

print("all tests passed" if fails == 0 else f"{fails} test(s) failed")
sys.exit(1 if fails else 0)
