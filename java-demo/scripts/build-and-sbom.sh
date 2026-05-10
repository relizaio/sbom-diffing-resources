#!/usr/bin/env bash
# build-and-sbom.sh — reproducer for the three Java variants.
#
# What this does:
#   1. Builds the analyzer JAR (benign or malicious) and installs it to a
#      shared local Maven repo at $M2_CACHE.
#   2. Builds the demo Spring Boot app for the requested variant.
#   3. Runs cdxgen -c against the resulting fat JAR and writes the SBOM
#      to <variant>/sboms/sbom-cdxgen-c.json.
#
# Usage:
#   ./build-and-sbom.sh 1-before-dependency
#   ./build-and-sbom.sh 2-with-benign-dependency
#   ./build-and-sbom.sh 3-with-malicious-dependency
#   ./build-and-sbom.sh all
#
# Requires Docker. No host JDK or Maven needed.

set -euo pipefail

VARIANT="${1:?usage: build-and-sbom.sh <variant>|all}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_DEMO="$(cd "$SCRIPT_DIR/.." && pwd)"
M2_CACHE="${M2_CACHE:-$JAVA_DEMO/.m2-cache}"
mkdir -p "$M2_CACHE"

MAVEN_IMAGE=${MAVEN_IMAGE:-maven:3.9-eclipse-temurin-17}
CDXGEN_IMAGE=${CDXGEN_IMAGE:-ghcr.io/cyclonedx/cdxgen:latest}

run_mvn() {
    local workdir="$1"; shift
    docker run --rm \
        -v "$workdir:/work" -w /work \
        -v "$M2_CACHE:/root/.m2" \
        "$MAVEN_IMAGE" \
        "$@"
}

run_cdxgen() {
    local workdir="$1"; shift
    docker run --rm \
        -v "$workdir:/app" -w /app \
        -v "$M2_CACHE:/home/cdx" -e HOME=/home/cdx \
        -u "$(id -u):$(id -g)" \
        --tmpfs /tmp:exec,uid="$(id -u)",gid="$(id -g)" \
        "$CDXGEN_IMAGE" \
        "$@"
}

# --- analyzer build (only for variants 2 and 3) ---

build_analyzer_for() {
    local variant="$1"
    case "$variant" in
        1-before-dependency)
            : ;;  # no analyzer needed
        2-with-benign-dependency)
            echo ">> building benign spring-build-analyzer v0.0.0 ..."
            run_mvn "$JAVA_DEMO/$variant/analyzer" \
                mvn -B clean install ;;
        3-with-malicious-dependency)
            echo ">> building Jeremy Long's spring-build-analyzer v0.0.1-SNAPSHOT ..."
            # README: "DO NOT shorten ... to 'mvn clean install' — separate clean and install."
            run_mvn "$JAVA_DEMO/$variant/analyzer" mvn -B clean
            run_mvn "$JAVA_DEMO/$variant/analyzer" mvn -B install ;;
        *)
            echo "unknown variant: $variant"; exit 1 ;;
    esac
}

# --- demo build + SBOM ---

build_and_sbom_demo() {
    local variant="$1"
    local dir="$JAVA_DEMO/$variant"
    echo ">> packaging demo for $variant ..."
    run_mvn "$dir" mvn -B package -DskipTests=true
    mkdir -p "$dir/sboms"
    echo ">> running cdxgen -c against the fat JAR ..."
    run_cdxgen "$dir" \
        -t jar -c -o /app/sboms/sbom-cdxgen-c.json \
        /app/target/demo-0.0.1-SNAPSHOT.jar
    echo ">> SBOM written to $dir/sboms/sbom-cdxgen-c.json"
    echo ">> components: $(jq '.components | length' "$dir/sboms/sbom-cdxgen-c.json")"
}

# --- main ---

if [[ "$VARIANT" == "all" ]]; then
    for v in 1-before-dependency 2-with-benign-dependency 3-with-malicious-dependency; do
        build_analyzer_for "$v"
        build_and_sbom_demo "$v"
    done
else
    build_analyzer_for "$VARIANT"
    build_and_sbom_demo "$VARIANT"
fi
