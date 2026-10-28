#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Print the URL of every git repository that the kas files below the given directories clone (one per line, sorted).

  kit/mirror/git-repos-from-kas.py <dir> [<dir> ...]     e.g. a checked-out agl-ucb tree: it also finds the feature
                                                         fragments of the layers (meta-agl/kas/feature/*.yml)
Reads `repos: <name>: url:` and `overrides: repos: <name>: url:` of every *.yml below a directory named kas. Needs PyYAML.
"""
import sys
from pathlib import Path

import yaml

urls = set()
for root in sys.argv[1:]:
    for f in Path(root).rglob("*.yml"):
        if "kas" not in f.parts or "/.git/" in str(f):
            continue
        try:
            d = yaml.safe_load(f.read_text())
        except (yaml.YAMLError, OSError, UnicodeDecodeError):
            continue
        if not isinstance(d, dict):
            continue
        for section in (d.get("repos"), (d.get("overrides") or {}).get("repos") if isinstance(d.get("overrides"), dict) else None):
            for repo in (section or {}).values():
                url = repo.get("url") if isinstance(repo, dict) else None
                if isinstance(url, str) and url.startswith(("http://", "https://")):
                    urls.add(url)
print("\n".join(sorted(urls)))
