# From SBOM signal to malicious-class confirmation

**Theme:** the SBOM diff is a tripwire. It told you *"a dependency
changed version"* or *"a new namespace appeared."* Now you want to
double-check the thing you actually ship — the **compiled fat JAR** —
to see whether a malicious class is really in there. You have no
source: just the binary artifact and its SBOM, which is all you have
at the end of the day anyway.

This note shows how far you can get using only tools that read
**compiled bytecode** (no decompilation, no source, no custom rules),
run against the consumer's own `demo-0.0.1-SNAPSHOT.jar` from
`3-with-malicious-dependency/`.

The companion [`../README.md`](../README.md) covers the SBOM-diff
*signal*; this directory is the *"go look at the artifact"* follow-up.

## Where the two payloads hide in the shipped artifact

A Spring Boot fat JAR is just a ZIP with two interesting regions:

| Payload | Path inside the fat JAR | Nesting |
|---|---|---|
| `CtxtListener` — the live reverse shell that runs in prod | `BOOT-INF/classes/io/.../demo/CtxtListener.class` | the consumer's **own** output, top-level zip entry |
| `SensorDrop`, `Compile`, `EnsureSpringAnnotation` — the dropper that wrote `CtxtListener` at build time | `BOOT-INF/lib/spring-build-analyzer-0.0.1-SNAPSHOT.jar` → `io/.../analyzer/SensorDrop.class` | one level **deeper**, inside an embedded JAR |

This split is the whole story:

- cdxgen enumerates classes from `BOOT-INF/lib/*.jar`, so it surfaces
  `SensorDrop` et al. as new namespaces. It does **not** enumerate
  `BOOT-INF/classes/`, so the consumer-side `CtxtListener.class` —
  the class that actually opens the reverse shell — is **invisible to
  the SBOM**.
- The cheapest possible JDK tool catches exactly what the SBOM
  misses.

## The toolbox (all operate on the compiled artifact)

### `jar tf` — entry enumeration → new-file diff

Diff the entry lists of two consecutive builds (variant 2 benign →
variant 3 malicious):

```sh
diff <(jar tf v2.jar | grep -E '^BOOT-INF/(classes|lib)/' | sort) \
     <(jar tf v3.jar | grep -E '^BOOT-INF/(classes|lib)/' | sort)
```

```
> BOOT-INF/classes/io/github/jeremylong/spring/analyzer/demo/CtxtListener.class   <-- the drop
> BOOT-INF/lib/spring-build-analyzer-0.0.1-SNAPSHOT.jar                            <-- version churn (noise)
< BOOT-INF/lib/spring-build-analyzer-0.0.0.jar
> BOOT-INF/lib/junit-jupiter-5.9.3.jar  ... (test transitives, noise)
```

A brand-new `CtxtListener.class` in *your own* namespace — the exact
SBOM blind spot — falls out of `jar tf` because it lists every zip
entry. Free, ships with the JDK.

### `jdeps` — referenced-API enumeration → capability diff

`jdeps` reads each class's constant pool and reports the types it
references. Run on the fat JAR it descends into `BOOT-INF/classes`:

```sh
diff <(jdeps -verbose:class v2.jar | awk '/->/{print $1" -> "$3}' | sort -u) \
     <(jdeps -verbose:class v3.jar | awk '/->/{print $1" -> "$3}' | sort -u)
```

```
> ...demo.CtxtListener -> java.net.Socket
> ...demo.CtxtListener -> java.lang.ProcessBuilder
> ...demo.CtxtListener -> java.lang.Process
> ...demo.CtxtListener -> java.io.InputStream / OutputStream / java.util.Timer ...
```

This is a capability signal **without writing a single rule**: the new
class can reach the socket and process-spawning APIs. `CtxtListener`
is compiled bytecode here, so jdeps sees its real API edges (unlike
the dropper, whose reverse-shell payload is an embedded *source
string* and therefore shows up as `JavaCompiler` + `Files` +
`AbstractProcessor` — "compiles code and writes files at build time").

### `javap` — disassembly → the literal payload

```sh
javap -p -c -classpath <extracted>/BOOT-INF/classes \
  io.github.jeremylong.spring.analyzer.demo.CtxtListener
```

```
0: ldc           // String 127.0.0.1
3: sipush  9999
7: ldc           // String /bin/sh
   ... new java/lang/ProcessBuilder ... ProcessBuilder.start ... new java/net/Socket ...
```

Host, port, shell command, and the Socket/ProcessBuilder wiring — read
straight out of the shipped bytecode.

### `extractcode` + `scancode` — recursive unpack + per-file hashing

The one tool here that **auto-recurses through every nesting level**
in a single command, so both payloads land as loose files:

```sh
extractcode demo-0.0.1-SNAPSHOT.jar      # unpacks fat JAR *and* the nested analyzer JAR
scancode --info --json-pp scan.json demo-0.0.1-SNAPSHOT.jar-extract
```

Both payloads are now on disk (note the nested `…jar-extract/…jar-extract/`):

```
BOOT-INF/classes/io/.../demo/CtxtListener.class
BOOT-INF/lib/spring-build-analyzer-0.0.1-SNAPSHOT.jar-extract/io/.../analyzer/SensorDrop.class
BOOT-INF/lib/spring-build-analyzer-0.0.1-SNAPSHOT.jar-extract/io/.../analyzer/Compile.class
```

`scancode --info` gives a content hash per file (sha1 + md5 in
3.x; current releases also emit sha256):

```
sha1=4b3675452411ca229aed2ef75bd566f959b9104c  size=2175  CtxtListener.class
sha1=71f81c3fdf58fd32c6bf374f58354355c4f19c49  size=4919  SensorDrop.class
sha1=b7161271156e1946bc1f41cd3123f00d39154ab1  size=4189  Compile.class
```

This is the SBOM-invisible signal made first-class: every `.class`,
at any depth, enumerated with a hash you can diff across builds or
match against a known-bad set. Its CycloneDX output is empty for
non-package files, so this information lives only in scancode's native
JSON — which is exactly why the SBOM ecosystem misses it.

## The one structural difference: recursion depth

| Tool | Reads | Reaches `BOOT-INF/classes/` (the drop) | Reaches nested `BOOT-INF/lib/*.jar` (the dropper) |
|---|---|---|---|
| `jar tf` | one zip level | ✅ | lists the JAR, not its contents — needs 1 manual unzip |
| `jdeps` | one zip level | ✅ | needs 1 manual unzip |
| `javap` | one class | ✅ (point it at the class) | ✅ (after unzip) |
| **`extractcode`+`scancode`** | recurses all the way down | ✅ | ✅ automatically |
| `diffoscope` | recurses all the way down | ✅ | ✅ automatically (and diffs changed bytecode of same-named classes) |

`jar tf`/`jdeps` read a single zip layer, so they catch the
consumer-side drop for free but need one extraction step per nesting
level to reach the dropper. `extractcode` and `diffoscope` exist
precisely to automate that descent.

## Per-payload summary

| Payload | cdxgen / SBOM | `jar tf` diff | `jdeps` diff | `javap` | `extractcode`+`scancode` |
|---|---|---|---|---|---|
| `CtxtListener` (reverse shell, consumer output) | ❌ missed | ✅ new entry | ✅ Socket + ProcessBuilder | ✅ host/port/shell | ✅ hash + path |
| `SensorDrop`/`Compile` (dropper, nested JAR) | ✅ namespaces | ✅ after 1 unzip | ✅ JavaCompiler + Files | ✅ embedded source | ✅ hash + path |

## What this layer is *not*

Everything above is **enumeration and inspection**, not a verdict. It
tells you a new class is present and which APIs it can reach — *where
to look*. Deciding *malicious vs. benign* is the next step: curated
rules (semgrep on decompiled source), decompilation for a human read
(CFR/Vineflower), or dynamic sandboxing (run it, watch the connect to
`localhost:9999`).

Two honest caveats:

- It is this easy only because the PoC ships **unobfuscated**.
  `javap`/`strings` and a `jdeps` capability read collapse against an
  encrypted or reflection-obfuscated payload, pushing you to
  decompiler-plus-human or dynamic analysis.
- `blint` is the **wrong layer** for a JVM drop: it is built on LIEF
  (ELF/PE/Mach-O) and cannot parse `.class`/JAR — run against this
  artifact it emits only generic native-binary hardening checks and
  zero behavioral findings. It *would* be the right tool if the drop
  were a native `.so`/`.dll`.
