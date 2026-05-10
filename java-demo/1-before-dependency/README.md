# Variant 1 — `before-dependency`

Spring Boot Hello-World app with **no** `spring-build-analyzer`
dependency. This is the baseline.

## Files

```
1-before-dependency/
├── README.md          ← you are here
├── pom.xml            ← Maven build file (no analyzer dep)
├── src/               ← demo source: DemoApplication, HelloController, test
└── sboms/
    └── sbom-cdxgen-c.json  ← cdxgen -t jar -c output (30 components)
```

## Reproduce

```sh
# from the repo root:
java-demo/scripts/build-and-sbom.sh 1-before-dependency
```

That is equivalent to:

```sh
# 1. build the fat JAR (Docker, so no host JDK needed)
docker run --rm \
    -v "$PWD:/work" -w /work \
    -v "$(pwd)/../.m2-cache:/root/.m2" \
    maven:3.9-eclipse-temurin-17 \
    mvn -B package -DskipTests=true

# 2. SBOM the fat JAR with cdxgen, -c flag for namespace enumeration
docker run --rm \
    -v "$PWD:/app" -w /app \
    -v "$(pwd)/../.m2-cache:/home/cdx" -e HOME=/home/cdx \
    -u "$(id -u):$(id -g)" \
    --tmpfs /tmp:exec,uid=$(id -u),gid=$(id -g) \
    ghcr.io/cyclonedx/cdxgen:latest \
    -t jar -c -o /app/sboms/sbom-cdxgen-c.json /app/target/demo-0.0.1-SNAPSHOT.jar
```

## What the SBOM contains

30 components: Spring Boot, Tomcat, Jackson, logback, slf4j, the
Spring Boot launcher, plus the demo itself. No `spring-build-analyzer`,
no `javapoet`. This is the "clean" baseline — anything that appears
in variant 2 or variant 3 but *not* here is something the demo
inherits from the analyzer dependency tree.
