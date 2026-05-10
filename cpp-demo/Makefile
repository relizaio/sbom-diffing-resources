SHELL := /bin/bash

# Pinned cdxgen image so the demo is reproducible across talks.
CDXGEN_IMAGE ?= ghcr.io/cyclonedx/cdxgen:latest
DOCKER_RUN := docker run --rm \
    -v "$(PWD):/app" -w /app \
    -u "$$(id -u):$$(id -g)" \
    --tmpfs /tmp:exec,uid=$$(id -u),gid=$$(id -g) \
    $(CDXGEN_IMAGE)

.PHONY: sbom-before sbom-after diff inject revert clean demo

# Generate baseline SBOM with cdxgen (containerised),
# then post-process to attach SHA-256 hashes for in-tree file components.
# (The .tmpl extension on the inject template keeps cdxgen from scanning it.)
sbom-before:
	$(DOCKER_RUN) -t cpp -o sbom-before.json /app
	./scripts/enrich-file-hashes.py sbom-before.json .

# Drop a foreign-looking source file into src/ to mimic a supply-chain
# injection. The file is benign — its mere presence is the signal.
inject:
	@if [ -e src/persistence.cpp ]; then \
	    echo "src/persistence.cpp already exists — run 'make revert' first"; exit 1; \
	fi
	cp stash/inject/persistence.cpp.tmpl src/persistence.cpp
	@grep -q persistence.cpp CMakeLists.txt || \
	    sed -i 's|src/utils.cpp|src/utils.cpp\n    src/persistence.cpp|' CMakeLists.txt
	@echo "Injected: src/persistence.cpp"
	@echo "CMakeLists.txt updated."

# Restore the project to its baseline so the demo is rerunnable.
revert:
	@rm -f src/persistence.cpp
	@sed -i '/src\/persistence.cpp/d' CMakeLists.txt
	@rm -f sbom-before.json sbom-after.json
	@echo "Reverted to baseline."

sbom-after:
	$(DOCKER_RUN) -t cpp -o sbom-after.json /app
	./scripts/enrich-file-hashes.py sbom-after.json .

diff:
	@./scripts/sbom-diff.py sbom-before.json sbom-after.json

# Convenience: full demo loop (revert → before → inject → after → diff).
demo: revert sbom-before inject sbom-after diff

clean:
	rm -f sbom-before.json sbom-after.json *.atom *.slices.json
