# Java demo — annotation-processor injection vs. SBOM diffing

Three side-by-side variants of the same Spring Boot Hello-World app,
each producing its own SBOM. Diffing the SBOMs across variants
illustrates two different supply-chain signals:

1. **Variant 1 → 2:** *a new dependency appears* — a coarse, package-level
   signal that any SBOM tool (and any human reviewer) would catch.
2. **Variant 2 → 3:** *the same artifact suddenly contains classes that
   shouldn't be there* — a subtle, namespace-level signal that only
   surfaces when the SBOM includes per-class enumeration. cdxgen does
   this by default on fat JARs as of v12.4.x.

The malicious dependency used in variant 3 is **Jeremy Long's
[malicious-dependencies](https://github.com/jeremylong/malicious-dependencies)
proof of concept**, an annotation processor that injects a benign
reverse shell (`CtxtListener`, connecting to `localhost:9999`) into
every Spring Boot app it gets pulled into at compile time.

## Three variants

| Variant | Demo's `pom.xml` | What's in the analyzer JAR |
|---|---|---|
| `1-before-dependency/` | no analyzer dep | n/a |
| `2-with-benign-dependency/` | `spring-build-analyzer 0.0.0` | 1 real class (`AnnotationValidationProcessor`) + auto-generated `HelpMojo` |
| `3-with-malicious-dependency/` | `spring-build-analyzer 0.0.1-SNAPSHOT` | the same 2 classes **plus** 6 dropped-in payload classes (`SensorDrop`, `Compile` + 3 inner, `EnsureSpringAnnotation`) |

Each variant directory contains:
- `pom.xml` — the demo's Maven build file
- `src/` — the demo's source code (same in all three variants —
  `DemoApplication.java`, `HelloController.java`, and the test)
- `analyzer/` (variants 2 and 3 only) — source code for the dependency
  that variant pulls in
- `sboms/sbom-cdxgen.json` — the resulting CycloneDX SBOM
  (`cdxgen -t jar` over the built fat JAR)

## How to reproduce all three SBOMs

```sh
# Builds all three analyzers (where applicable), all three demos, and
# regenerates all three SBOMs. Requires Docker; no host JDK or Maven.
java-demo/scripts/build-and-sbom.sh all
```

To build a single variant, pass its directory name instead of `all`:

```sh
java-demo/scripts/build-and-sbom.sh 2-with-benign-dependency
```

Under the hood the script does, for each variant:

1. (Variants 2 and 3 only) **Build the analyzer JAR and install it
   into a shared local Maven repo at `java-demo/.m2-cache/`** —
   `mvn -B clean install` for the benign one;
   `mvn -B clean && mvn -B install` for Jeremy's
   (his README warns *"DO NOT shorten the following to `mvn clean install`
   as things may not work."*).
2. **Build the demo's fat JAR** —
   `mvn -B package -DskipTests=true`.
3. **Run cdxgen against the fat JAR** —
   `cdxgen -t jar -o sboms/sbom-cdxgen.json target/demo-0.0.1-SNAPSHOT.jar`.

> **cdxgen version note.** The SBOMs committed under each variant's
> `sboms/` were generated with cdxgen 12.4.3. Earlier versions
> (≤12.3.x) required the `-c` / `--resolve-class` flag to enumerate
> classes inside fat JARs, and returned 0 components without it.
> 12.4.x folds that behaviour into the default `-t jar` scan, so the
> namespace-level signal below is now available without any extra
> flags. If you pin to an older cdxgen, add `-c` to the command above.

## What the diffs look like

### Diff #1 — variant 1 vs variant 2 (no dep → benign dep)

```
$ diff <(jq -r '.components[].purl' 1-before-dependency/sboms/sbom-cdxgen.json | sort) \
       <(jq -r '.components[].purl' 2-with-benign-dependency/sboms/sbom-cdxgen.json | sort)

> pkg:maven/com.squareup/javapoet@1.13.0?type=jar
> pkg:maven/io.github.jeremylong.spring.analyzer/spring-build-analyzer@0.0.0?type=jar
```

Two new components appear:

- `spring-build-analyzer 0.0.0` — the dep we just added.
- `javapoet 1.13.0` — pulled in transitively, because the analyzer's
  `pom.xml` declares it as a `<scope>compile</scope>` dependency.

This is the **easy** signal. Every SBOM tool catches it. It's the
same signal a human gets from reviewing the `pom.xml` diff.

### Diff #2 — variant 2 vs variant 3 (benign dep → malicious dep)

The package-level diff still shows changes, but the changes look like
ordinary version churn:

```
< pkg:maven/io.github.jeremylong.spring.analyzer/spring-build-analyzer@0.0.0?type=jar
> pkg:maven/io.github.jeremylong.spring.analyzer/spring-build-analyzer@0.0.1-SNAPSHOT?type=jar
> pkg:maven/junit-jupiter/junit-jupiter@5.9.3?type=jar
> pkg:maven/junit-jupiter-api/junit-jupiter-api@5.9.3?type=jar
> ... 6 more junit/transitive deps ...
```

A version bump and some test-framework transitives — nothing visibly
suspect. **A package-level reviewer would shrug and move on.**

The smoking gun is at the **namespace level**, inside the
`spring-build-analyzer` component itself. Each class enumerated by
cdxgen lives in a `Namespaces` property attached to its component.

#### Off-the-shelf diff tools tested against this signal

Four general-purpose CycloneDX diff tools were run on the variant 2
and variant 3 SBOMs (`cdxgen 12.4.3` output) to see whether any of
them flag the `Namespaces` property growing from 2 entries to 8 inside
the `spring-build-analyzer` component. None do.

| Tool | Version change surfaced | Namespace property change surfaced |
|---|---|---|
| sbom-tools — https://github.com/sbom-tool/sbom-tools — v0.1.19 | ✅ flagged as `Modified` with `field_changes: [{field: "version"}]` | ❌ — `properties` are not part of its diff model |
| sbomdiff — https://github.com/anthonyharrison/sbomdiff — v0.6.0 | ✅ flagged as `status: change` with `version.from / .to` | ❌ — `properties` are not in its output schema at all |
| cyclonedx-cli — https://github.com/CycloneDX/cyclonedx-cli — v0.32.0 | ✅ text UX names the version bump; JSON splits the component into paired `removed` (v0.0.0) + `added` (v0.0.1-SNAPSHOT) entries | 🟡 the raw `Namespaces` blob for both versions is embedded verbatim in the JSON output, but the tool doesn't compare them — recoverable only by post-processing the diff JSON with `jq` |
| sbom-utility — https://github.com/CycloneDX/sbom-utility — v0.19.0 | ❌ crashes: `panic: runtime error: slice bounds out of range` | ❌ — same; and its own advisory recommends running the `Trim` command first to strip `bom-ref`, `hashes`, and `properties` before diffing, which would actively erase this signal |

So for the namespace-level signal — the part that distinguishes
*"benign dep with a version bump"* from *"benign dep replaced by
something carrying extra payload classes"* — no off-the-shelf
CycloneDX diff tool surfaces it. The `jq` recipe below is currently
the most direct way to extract it:

```
$ jq -r '.components[]
         | select(.purl | test("spring-build-analyzer"))
         | .properties[] | select(.name=="Namespaces") | .value' \
     2-with-benign-dependency/sboms/sbom-cdxgen.json
io.github.jeremylong.spring.analyzer.spring_build_analyzer.HelpMojo
io.github.jeremylong.spring.build.analyzer.AnnotationValidationProcessor

$ jq -r '.components[]
         | select(.purl | test("spring-build-analyzer"))
         | .properties[] | select(.name=="Namespaces") | .value' \
     3-with-malicious-dependency/sboms/sbom-cdxgen.json
io.github.jeremylong.spring.analyzer.spring_build_analyzer.HelpMojo
io.github.jeremylong.spring.build.analyzer.AnnotationValidationProcessor
io.github.jeremylong.spring.build.analyzer.Compile$CharSequenceJavaFileObject
io.github.jeremylong.spring.build.analyzer.Compile$ClassFileManager
io.github.jeremylong.spring.build.analyzer.Compile$JavaFileObject
io.github.jeremylong.spring.build.analyzer.Compile
io.github.jeremylong.spring.build.analyzer.EnsureSpringAnnotation
io.github.jeremylong.spring.build.analyzer.SensorDrop
```

The benign version has 2 classes; the malicious version has 8.

The 6 new classes (`Compile`, three `Compile$…` inner classes,
`EnsureSpringAnnotation`, `SensorDrop`) are exactly the payload
classes — an in-memory Java compiler used to build a malicious
processor on the fly, an annotation processor that registers and runs
during the consumer's `javac`, and the helper that drops the
`CtxtListener` reverse shell into the consumer's compiled output.

**This is the signal.** Same artifact name, different version, but
also: contents that have no business being in a "build analyzer" of
all things.

## What the SBOM diff *is* — and what it isn't

A diff like the one above is an **investigation trigger**, not an
adjudication. Specifically:

- cdxgen reports the *fully-qualified class names* present in each
  JAR. It does **not** report what those classes do, what bytecode
  they contain, what permissions they request, or whether they're
  benign.
- The SBOM does **not** include SHA-256 hashes for the individual
  classes — only at the JAR level. So if a malicious version of an
  artifact reused all the original class names but changed their
  bytecode, the namespace diff would show no change.
- For the consumer's own compiled output (`BOOT-INF/classes/`),
  cdxgen emits nothing at all — it only enumerates classes from
  embedded JARs. So the **`CtxtListener.class` that this attack drops
  into the consumer's own bytecode is invisible to cdxgen**.
  (See the [tool comparison](#tool-comparison) below.)

The right framing for the talk is:

> **An SBOM diff is a tripwire.** When it surfaces a new namespace
> inside an existing dependency, or a new file in your own compiled
> output, that's the signal that a *human* — or a stricter tool —
> needs to look at the bytecode itself. The SBOM tells you *where to
> look*; it does not tell you *what's wrong*.

## Tool comparison

We tested four SBOM/file-enumeration tools against this exact attack
in late April / early May 2026. None of the four caught everything;
each had a different blind spot.

| Tool / flag | Surfaces new dep (variant 1 → 2) | Surfaces dropped classes inside the dep (variant 2 → 3) | Surfaces injected `CtxtListener.class` in consumer's BOOT-INF/classes |
|---|---|---|---|
| **`cdxgen -t jar`** (12.4.x, used here) | ✅ | ✅ at the namespace level | ❌ — only reads classes from JARs, not loose .class files |
| `cdxgen -t jar` (≤12.3.x) | ❌ — returned 0 components from a fat JAR; required `-c` to enumerate anything | ❌ — same; required `-c` | ❌ |
| `syft` | ✅ — auto-walks `BOOT-INF/lib/*.jar` | ❌ — package-level only | ❌ |
| `trivy fs` | ✅ when scanning the source tree | ❌ — returns 0 components from a fat JAR | ❌ |
| **`extractcode` + `scancode`** | ✅ (it sees every nested JAR) | ✅ — every `.class` enumerated with SHA-256 | ✅ — **the only tool here that catches this** |

A few things follow:

- For the **producer side** (catching that the malicious artifact is
  shipping something its source tree doesn't account for), cdxgen
  12.4+ is the lightest viable tool. One command, no flags, no
  pre-extraction, and the suspicious namespaces fall out of a single
  `jq` query.
- For the **consumer side** (catching that *your* build output now
  contains a class you never wrote), no SBOM tool currently works.
  scancode + extractcode catches it via raw file enumeration with
  SHA-256, but its CycloneDX output is empty for non-package files —
  that information is only in scancode's native JSON. So this kind of
  detection is not yet first-class in the SBOM ecosystem.

For a longer breakdown of what each tool catches and what it misses,
see [the comparison study](../#what-this-repo-is) referenced from the
top-level README.

## Why this PoC was built

[`jeremylong/malicious-dependencies`](https://github.com/jeremylong/malicious-dependencies)
demonstrates a concrete realization of an old supply-chain class of
attack: *anything that runs at build time can modify the build
output*, and an annotation processor is one of many ways to land
classes in a compiled JAR without a corresponding source file. The
malicious classes themselves don't even live in the published
`spring-build-analyzer` source tree — they're injected at build time
by a sibling Maven module, `build-helper`. So even a careful reviewer
of the published source would not see them.

The point of the variants in this directory is to make the resulting
**SBOM-level signal visible**, not to relitigate the attack itself —
Jeremy's repo and writeup do that better than we could.

## Licensing Notes
All content added by this repository is licensed per Apache-2.0 license, however this does not include the original [`jeremylong/malicious-dependencies`](https://github.com/jeremylong/malicious-dependencies) code, which is used here only as analysis subject.
