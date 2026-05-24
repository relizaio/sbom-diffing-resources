# sbom-diffing-resources

Two end-to-end demos and a tooling comparison that argue for a single
practice:

> **Generate SBOMs continuously, diff consecutive snapshots, and treat
> any new component — at the package or namespace level — as a signal
> to investigate.**

This repo is the supporting material for an upcoming conference talk on
continuous SBOM diffing as a supply-chain defense, especially for the
long tail of components that don't have a clean upstream identifier
(vendored snippets, foreign source drops, build-time compile-time
class injections).

## What's in the repo

| Path | What it shows |
|---|---|
| [`cpp-demo/`](cpp-demo/) | A small C++ project where a foreign source file is dropped into `src/`. Two cdxgen runs, before and after, surface the new file as a `pkg:generic/...#path` component. SBOM diff catches it. |
| [`java-demo/`](java-demo/) | Three Spring Boot variants — no analyzer dep, with a benign analyzer, with [Jeremy Long's malicious-dependencies PoC](https://github.com/jeremylong/malicious-dependencies). cdxgen against each fat JAR surfaces both a new dependency (variant 1 → 2) and new namespaces inside that dependency (variant 2 → 3). |

Each demo is self-contained: source code, the recipe for reproducing
the SBOMs from scratch (Docker only, no host JDK / Maven), and the
already-generated SBOMs committed under `sboms/`.

## Why two languages

The C++ demo and the Java demo target the **same primitive** —
"a thing appeared in the build output that wasn't in the source" —
but exercise it at different levels:

- **C++:** the foreign thing is a *source file*, and per-source-file
  components fall out of `cdxgen -t cpp` for free.
- **Java:** the foreign thing is a *compiled class file* dropped into
  a published JAR by a sibling Maven module's test phase. cdxgen 12.4+
  enumerates classes inside `BOOT-INF/lib/*.jar` by default on a
  `-t jar` scan (older versions needed `-c` / `--resolve-class`),
  but neither version covers the consumer's own `BOOT-INF/classes/`.

Together the two demos make the case that **file/namespace-level SBOM
content is the primitive that catches both halves of the supply-chain
problem** — newly first-class in cdxgen, still missing for loose
consumer-side class files, and absent from most other tools.

## The talk's central claim

A package-level SBOM (the kind every CI pipeline already produces)
catches one half of the problem: *"something new is in your dependency
list"*. It misses the half where the dependency itself starts shipping
content it didn't ship before — and the half where your own compiled
output gets quietly augmented at build time.

A diff between two SBOMs is, in itself, a **tripwire**. It tells you
*where to look*. It does not tell you *what's wrong*. For the actual
forensics — what did this new class do, what did this new file
contain — you need a second tool layer (e.g.
[scancode-toolkit](https://github.com/nexB/scancode-toolkit) for
file-level SHA-256 enumeration, [blint](https://github.com/owasp-dep-scan/blint)
for native binaries, ad-hoc decompilation for JVM bytecode).

The two demos here exist to make the **tripwire** part visible and
mechanical. The follow-on forensics is briefly discussed at the bottom
of [`java-demo/README.md`](java-demo/README.md) and is left as the
exercise the talk closes on.

## Running everything yourself

Both demos require only Docker on the host. No JDK, no Maven, no
C++ toolchain.

```sh
# C++ demo — produces cpp-demo/sboms/sbom-{before,after}.json
cd cpp-demo
make demo

# Java demo — produces java-demo/{1,2,3}-*/sboms/sbom-cdxgen.json
cd ../java-demo
./scripts/build-and-sbom.sh all
```

Both scripts pull the cdxgen container
(`ghcr.io/cyclonedx/cdxgen:latest`, currently 12.4.3) and, for the
Java demo, also pull `maven:3.9-eclipse-temurin-17`. First run takes
a few minutes for the image pulls and Maven dependency downloads;
subsequent runs are cached.

## What's deliberately *not* in this repo

- **Built JARs** and `target/` directories. These are reproducible
  from source via the scripts above. The malicious analyzer JAR
  in particular contains code that opens a localhost socket on first
  run; we don't ship it precompiled.
- **Vulnerability scans, license reports, attestations.** Out of
  scope for this talk's narrative — the diff is the topic, not the
  surrounding tooling.
- **A unified SBOM diff CLI.** The C++ demo includes a tiny purl-keyed
  `scripts/sbom-diff.py`; the Java demo just uses `diff <(jq …)`.
  Both are intentionally compact for slide use; in a real pipeline
  you'd reach for `cyclonedx-cli diff` or equivalent.

## License

[Apache 2.0](LICENSE) — same as cdxgen, scancode, and the malicious-
dependencies PoC the Java demo references.
