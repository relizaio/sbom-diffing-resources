#!/usr/bin/env python3
"""
Diff two CycloneDX SBOMs by purl. Prints:

  - components added in `after` but not in `before`
  - components removed (in `before` but not `after`)
  - components whose SHA-256 hash changed between snapshots

Output is intentionally compact and demo-friendly — not a replacement for
cyclonedx-cli's `diff` subcommand, but enough to drive the narrative.
"""
import json
import sys
from pathlib import Path


def index(bom: dict) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for comp in bom.get("components", []):
        purl = comp.get("purl") or comp.get("bom-ref")
        if purl:
            out[purl] = comp
    return out


def sha256(comp: dict) -> str | None:
    for h in comp.get("hashes", []):
        if h.get("alg") == "SHA-256":
            return h.get("content")
    return None


def short(comp: dict) -> str:
    purl = comp.get("purl", "?")
    h = sha256(comp)
    return f"{purl}" + (f"  sha256={h[:12]}…" if h else "")


def main() -> int:
    before = json.loads(Path(sys.argv[1]).read_text())
    after = json.loads(Path(sys.argv[2]).read_text())
    b, a = index(before), index(after)

    added = sorted(set(a) - set(b))
    removed = sorted(set(b) - set(a))
    changed = sorted(p for p in (set(a) & set(b)) if sha256(b[p]) and sha256(a[p]) and sha256(b[p]) != sha256(a[p]))

    print(f"=== SBOM diff ===")
    print(f"  before: {Path(sys.argv[1]).name}  ({len(b)} components)")
    print(f"  after:  {Path(sys.argv[2]).name}  ({len(a)} components)")
    print()
    print(f"  added:   {len(added)}")
    for p in added:
        print(f"    + {short(a[p])}")
    print(f"  removed: {len(removed)}")
    for p in removed:
        print(f"    - {short(b[p])}")
    print(f"  changed: {len(changed)}")
    for p in changed:
        print(f"    ~ {p}")
        print(f"        was sha256={sha256(b[p])[:12]}…")
        print(f"        now sha256={sha256(a[p])[:12]}…")

    if added or changed:
        print()
        print("ACTIONABLE: at least one component is new or has changed content.")
        print("Investigate before allowing the build to proceed.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
