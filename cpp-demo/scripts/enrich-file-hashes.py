#!/usr/bin/env python3
"""
Walk the components produced by cdxgen and, for any component whose purl
points at an in-tree source file (e.g. pkg:generic/calculator#src/calculator.cpp),
attach a SHA-256 hash of that file. This gives the SBOM enough fingerprint
detail for a diff to flag content changes — not just additions/removals.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

SBOM = Path(sys.argv[1])
ROOT = Path(sys.argv[2]) if len(sys.argv) > 2 else SBOM.parent

# purl subpath fragment is whatever comes after "#"
PURL_SUBPATH = re.compile(r"#(.+)$")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    bom = json.loads(SBOM.read_text())
    enriched = 0
    for comp in bom.get("components", []):
        purl = comp.get("purl", "")
        m = PURL_SUBPATH.search(purl)
        if not m:
            continue
        rel = m.group(1)
        path = ROOT / rel
        if not path.is_file():
            continue
        digest = sha256_of(path)
        hashes = comp.setdefault("hashes", [])
        if not any(h.get("alg") == "SHA-256" for h in hashes):
            hashes.append({"alg": "SHA-256", "content": digest})
            enriched += 1
    SBOM.write_text(json.dumps(bom, indent=2))
    print(f"enriched {enriched} components with SHA-256 hashes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
