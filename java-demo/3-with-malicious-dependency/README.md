# Variant 3 — `with-malicious-dependency`

Same Spring Boot Hello-World app, with **Jeremy Long's
[`malicious-dependencies`](https://github.com/jeremylong/malicious-dependencies)
proof of concept** as the analyzer dependency at version
`0.0.1-SNAPSHOT`.

## What this attack does

`spring-build-analyzer` is a Maven plugin that, on the surface, is a
compile-time analyzer for Spring Boot apps. Its **published source
tree** contains a single Java class (`AnnotationValidationProcessor`),
which iterates over `@SpringBootApplication` annotations during
`javac`. Looks innocent.

What makes it malicious is the **sibling Maven module**, `build-helper`:

- `build-helper`'s *test phase* programmatically creates extra
  `.class` files (`Compile`, `EnsureSpringAnnotation`, `SensorDrop`,
  plus inner classes) and copies them **into the
  `spring-build-analyzer` JAR's classpath** during the analyzer's
  build.
- The `spring-build-analyzer` JAR's
  `META-INF/services/javax.annotation.processing.Processor` registers
  *both* the benign processor and the dropped `EnsureSpringAnnotation`.
- When the consumer (this `demo` app) runs `javac`, both processors
  load. `EnsureSpringAnnotation` invokes `SensorDrop`, which uses the
  in-memory compiler (`Compile`) to compile a small `CtxtListener`
  source on the fly and write its `.class` file directly into the
  consumer's compiled output (`BOOT-INF/classes/.../demo/CtxtListener.class`).
- `CtxtListener` is a Spring `ApplicationContextInitializer`. It runs
  on app startup and opens a (benign) reverse shell to
  `localhost:9999`.

The result: the consumer's *own compiled bytecode* now contains a
class that has no source file in the consumer's repository, no
manifest entry, and no upstream package — it appeared at build time
through a chain that traverses two repos and three Maven modules.

## Files

```
3-with-malicious-dependency/
├── README.md            ← you are here
├── pom.xml              ← demo's Maven build file (depends on spring-build-analyzer 0.0.1-SNAPSHOT)
├── src/                 ← demo source — same as variants 1 & 2
├── analyzer/            ← Jeremy Long's full analyzer reactor
│   ├── pom.xml          ← parent POM, declares two modules
│   ├── spring-build-analyzer/
│   │   ├── pom.xml      ← the published artifact (benign-looking source)
│   │   └── src/main/    ← exactly 1 .java file (AnnotationValidationProcessor)
│   └── build-helper/
│       ├── pom.xml      ← the malicious sibling module
│       └── src/         ← test phase here is what drops the payload classes
└── sboms/
    └── sbom-cdxgen-c.json  ← cdxgen -t jar -c output (40 components)
```

## Reproduce

```sh
# from the repo root:
java-demo/scripts/build-and-sbom.sh 3-with-malicious-dependency
```

That is equivalent to:

```sh
# 1. build & install Jeremy's analyzer (per his README, run clean and install
#    SEPARATELY — combining them as 'mvn clean install' breaks the build-helper
#    test-phase machinery that drops the payload classes)
docker run --rm \
    -v "$PWD/analyzer:/work" -w /work \
    -v "$(pwd)/../.m2-cache:/root/.m2" \
    maven:3.9-eclipse-temurin-17 \
    mvn -B clean
docker run --rm \
    -v "$PWD/analyzer:/work" -w /work \
    -v "$(pwd)/../.m2-cache:/root/.m2" \
    maven:3.9-eclipse-temurin-17 \
    mvn -B install

# 2. build the demo's fat JAR — at this point the malicious annotation processor
#    runs during the consumer's javac and CtxtListener.class lands in the output
docker run --rm \
    -v "$PWD:/work" -w /work \
    -v "$(pwd)/../.m2-cache:/root/.m2" \
    maven:3.9-eclipse-temurin-17 \
    mvn -B package -DskipTests=true

# 3. SBOM the fat JAR with cdxgen -c (the -c flag is what surfaces the dropped
#    namespaces inside the spring-build-analyzer component)
docker run --rm \
    -v "$PWD:/app" -w /app \
    -v "$(pwd)/../.m2-cache:/home/cdx" -e HOME=/home/cdx \
    -u "$(id -u):$(id -g)" \
    --tmpfs /tmp:exec,uid=$(id -u),gid=$(id -g) \
    ghcr.io/cyclonedx/cdxgen:latest \
    -t jar -c -o /app/sboms/sbom-cdxgen-c.json /app/target/demo-0.0.1-SNAPSHOT.jar
```

## Confirming the attack landed

After step 2, the consumer's fat JAR contains an extra class file
that has no source in the consumer's repo:

```
$ unzip -l target/demo-0.0.1-SNAPSHOT.jar | grep "BOOT-INF/classes/.*\.class$"
   783  BOOT-INF/classes/io/github/jeremylong/spring/analyzer/demo/DemoApplication.class
   663  BOOT-INF/classes/io/github/jeremylong/spring/analyzer/demo/HelloController.class
  2175  BOOT-INF/classes/io/github/jeremylong/spring/analyzer/demo/CtxtListener.class   ← NOT in src/

$ find src -name "CtxtListener.java"
(no output)
```

`CtxtListener` is exactly what Jeremy's PoC describes — a Spring
context initializer that opens a TCP socket to `localhost:9999` and
behaves as a reverse shell on app startup.

## What the SBOM contains

40 components — the 32 from variant 2, plus a handful of test-framework
transitives that Jeremy's analyzer pulls in (`junit-jupiter` and friends,
`opentest4j`, `apiguardian-api`), plus the version bump on
`spring-build-analyzer` itself: `0.0.0` → `0.0.1-SNAPSHOT`.

**The signal is at the namespace level**, inside the
`spring-build-analyzer` component:

```
io.github.jeremylong.spring.analyzer.spring_build_analyzer.HelpMojo
io.github.jeremylong.spring.build.analyzer.AnnotationValidationProcessor
io.github.jeremylong.spring.build.analyzer.Compile$CharSequenceJavaFileObject   ← new
io.github.jeremylong.spring.build.analyzer.Compile$ClassFileManager             ← new
io.github.jeremylong.spring.build.analyzer.Compile$JavaFileObject               ← new
io.github.jeremylong.spring.build.analyzer.Compile                              ← new
io.github.jeremylong.spring.build.analyzer.EnsureSpringAnnotation               ← new
io.github.jeremylong.spring.build.analyzer.SensorDrop                           ← new
```

Six classes that were not present in the variant-2 JAR appear in the
variant-3 JAR, all under the same package. None of them have a
counterpart in the published source of `spring-build-analyzer`. That
is the actionable, machine-readable signal.

## Limits of the SBOM-only signal

The diff says **"these new namespaces appeared inside this dependency."**
It does **not** say:
- what those classes *do*
- whether they got loaded at runtime
- whether anything they did landed in the consumer's own bytecode

For *that* level of forensics, the SBOM is not enough. To prove that
`CtxtListener.class` shows up in `BOOT-INF/classes/` of the consumer's
fat JAR, one approach is `extractcode --shallow demo-0.0.1-SNAPSHOT.jar`
followed by `scancode -i --json-pp` over the unpacked tree — that
pipeline emits a SHA-256-fingerprinted file list that includes
`CtxtListener.class`. cdxgen does not enumerate `BOOT-INF/classes/`
entries even with `-c`, and the resulting CycloneDX document does not
carry that level of detail anywhere — that information lives only in
scancode's native JSON.

For the purposes of the talk: **the SBOM diff is the tripwire that
tells you to go look.** What you find when you go look (a benign
reverse shell, in this case) is the work of a different tool.
