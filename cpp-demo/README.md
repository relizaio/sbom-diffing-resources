# C++ demo — SBOM diffing catches a foreign source drop

A small C++ project used to illustrate **continuous SBOM diffing** in CI:
two SBOMs generated before and after a "foreign" source file is added to
the project, and a tiny purl-keyed differ that flags the new file as an
actionable supply-chain signal.

## Narrative

> An attacker drops a foreign source file into your repo through a
> compromised dependency, a typo-squatted PR, a careless contributor,
> or any build-time mechanism that can write to the source tree. The
> file isn't a known package, so package-level SBOM diffs miss it.
> File-level SBOM diffs catch the new component on the very first build.

## Layout

```
cpp-demo/
├── README.md             ← you are here
├── before/               ← snapshot of source state #1 (clean)
│   ├── CMakeLists.txt
│   ├── vcpkg.json
│   └── src/              ← 5 files: main, calculator{.h,.cpp}, utils{.h,.cpp}
├── after/                ← snapshot of source state #2 (post-injection)
│   ├── CMakeLists.txt    ← persistence.cpp added to add_executable()
│   ├── vcpkg.json        ← unchanged (the foreign file is unpackaged)
│   └── src/              ← 6 files: same five plus persistence.cpp
├── sboms/
│   ├── sbom-before.json  ← cdxgen output for the "before" tree (7 components)
│   └── sbom-after.json   ← cdxgen output for the "after" tree (8 components)
├── CMakeLists.txt        ← live state (toggled by Makefile recipes below)
├── vcpkg.json
├── src/
├── stash/inject/persistence.cpp.tmpl   ← the foreign file the inject step drops
├── Makefile              ← end-to-end orchestration
└── scripts/
    ├── enrich-file-hashes.py   ← post-cdxgen: SHA-256 every in-tree file component
    └── sbom-diff.py            ← purl-keyed diff with hash-change detection
```

`before/` and `after/` are **frozen snapshots** so a reader can see what
changed. The live `src/` + `CMakeLists.txt` at the top level are what the
Makefile operates on; `make demo` regenerates the SBOMs in `sboms/` from
scratch.

## Prerequisites

- Docker (the demo runs `ghcr.io/cyclonedx/cdxgen:latest` so the cdxgen
  toolchain — Node.js + the JVM-backed atom slicer — has a known-good
  environment on every machine).
- Python 3 (for the two helper scripts; no third-party deps).

The C++ binary is never linked — the SBOM is generated from source
metadata, so no compiler is required.

## End-to-end commands

### One-shot reproduction

```sh
make demo
```

This is `revert → sbom-before → inject → sbom-after → diff` in sequence.
The SBOMs land at `sbom-before.json` / `sbom-after.json` in the project
root and the diff prints to stdout.

### Step-by-step (the same recipe broken out)

```sh
# 0. ensure clean state (removes any prior persistence.cpp + restores CMakeLists.txt)
make revert

# 1. baseline SBOM — runs cdxgen against the "before" tree, then enriches
#    every in-tree file component with a SHA-256 of its on-disk content
make sbom-before

# 2. drop a foreign source file into src/, register it in CMakeLists.txt
#    (this simulates the supply-chain injection)
make inject

# 3. post-injection SBOM — same cdxgen + enrich pipeline, against the
#    now-modified tree
make sbom-after

# 4. compare the two SBOMs (purl-keyed diff)
make diff
```

### What the Makefile actually invokes

The `sbom-before` and `sbom-after` recipes are both:

```sh
docker run --rm \
    -v "$PWD:/app" -w /app \
    -u "$(id -u):$(id -g)" \
    --tmpfs /tmp:exec,uid=$(id -u),gid=$(id -g) \
    ghcr.io/cyclonedx/cdxgen:latest \
    -t cpp -o sbom-{before,after}.json /app
./scripts/enrich-file-hashes.py sbom-{before,after}.json .
```

No special cdxgen flags are needed — `-t cpp` against the source tree
emits per-source-file components (`pkg:generic/<name>#<path>`) alongside
the vcpkg dependencies. We just attach SHA-256 to each in-tree file
afterwards because cdxgen does not.

## What the diff looks like

```
=== SBOM diff ===
  before: sbom-before.json  (7 components)
  after:  sbom-after.json  (8 components)

  added:   1
    + pkg:generic/persistence#src/persistence.cpp  sha256=8a2afdf67f81…
  removed: 0
  changed: 0

ACTIONABLE: at least one component is new or has changed content.
Investigate before allowing the build to proceed.
```

The diff exits **status 1** whenever there is an *added* or
*hash-changed* component. In a real pipeline this would fail the CI job
and require a human to attest to the new file before the build proceeds.

## Components in each SBOM

**Before (7):**

| purl |
|---|
| `pkg:generic/fmt` |
| `pkg:generic/cli11` |
| `pkg:generic/main#src/main.cpp` |
| `pkg:generic/calculator#src/calculator.cpp` |
| `pkg:generic/utils#src/utils.cpp` |
| `pkg:generic/CLI/CLI#CLI/CLI.hpp` |
| `pkg:generic/fmt/core#fmt/core.h` |

**After (8):** same seven plus

| purl |
|---|
| `pkg:generic/persistence#src/persistence.cpp` |

The new entry has no upstream package, no manifest entry, and a SHA-256
fingerprint that has never appeared in this project before. That's the
actionable signal.

## Why this is the talk's point

Traditional SBOM workflows surface only **registered** components — vcpkg
manifests, Cargo crates, Maven artifacts, conan recipes, etc. Anything
that isn't a known package — a vendored snippet, a copy-pasted function,
a foreign source drop — is invisible at the package level.

When the SBOM also contains **file-level** components, a diff between
two snapshots flags the appearance of a never-before-seen file even
when no package metadata changed. That's the missing primitive.

The injected `persistence.cpp` is **deliberately benign** — it just
opens a log file. The "supply-chain" property we exercise is its mere
*appearance*, not its content.

## Tooling notes

- **cdxgen 12.3.3** in container mode produces per-source-file
  components for C/C++ projects out of the box — the default `-t cpp`
  invocation emits the in-tree source files as `pkg:generic/...#path`
  components alongside the vcpkg dependencies, so no extra flags are
  needed. The Makefile pins `ghcr.io/cyclonedx/cdxgen:latest` so the
  JVM-backed atom slicer runs in a known-good environment across
  machines.
- **cdxgen 12.4.x — known reproduction gotcha.** The committed SBOMs
  under `sboms/` were generated with 12.3.3. As of 12.4.x cdxgen
  descends into the `before/` and `after/` reference snapshot subdirs
  alongside the live tree and content-deduplicates across them, so a
  default `make demo` produces a noisy 9/9-component diff (`+3 / -3`)
  where source-file paths bounce between `src/`, `before/src/`, and
  `after/src/` and the before-state SBOM ends up listing
  `persistence#after/src/persistence.cpp` — defeating the
  "appeared between snapshots" narrative. To reproduce the clean
  `+1 persistence.cpp` signal on 12.4.x, move the snapshot dirs out
  of cdxgen's view for the duration of the run:
  ```sh
  mv before /tmp/ && mv after /tmp/
  make demo
  mv /tmp/before . && mv /tmp/after .
  ```
  With the snapshot dirs out of the way the resulting purls match the
  committed 12.3.3 outputs exactly.
- **`enrich-file-hashes.py`** is a 30-line post-processor that walks
  every component whose purl has a `#path` fragment, computes a SHA-256
  of the on-disk file, and attaches it to the component's `hashes`
  array. This step exists because cdxgen does not emit hashes for
  per-file C/C++ components by default.
- **`sbom-diff.py`** is a 60-line script that indexes both SBOMs by
  purl and reports added / removed / hash-changed components. It is
  intentionally compact for clarity in a talk; production pipelines
  would use the `cyclonedx-cli diff` subcommand or equivalent.
