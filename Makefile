# NowBar developer shortcuts. Run `make` (or `make help`) to list the targets.

SWIFT ?= swift

# With only the Command Line Tools installed (no Xcode), Swift Testing's macro plugin isn't on the
# compiler's default plugin path, so `swift test` needs it passed in. Override with `make test TEST_FLAGS=`.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
TEST_FLAGS ?= -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
endif

.DEFAULT_GOAL := help
.PHONY: help build app install demo test snapshots icon clean

help: ## Show this list
	@printf 'NowBar\n\nUsage: make <target>\n\n'
	@awk -F ':.*## ' '/^[a-z]+:.*## / { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Debug build of every target
	$(SWIFT) build

app: ## Release build, packaged and signed as build/NowBar.app
	scripts/build-app.sh

install: ## Build, install to ~/Applications/NowBar.app and launch it
	scripts/build-app.sh --install --open

demo: ## Build and launch build/NowBar.app with a fake playlist (no Music needed)
	scripts/build-app.sh --open --demo

test: ## Run the tests
	$(SWIFT) test $(TEST_FLAGS)

snapshots: ## Render the panel to PNGs in build/snapshots
	$(SWIFT) run NowBarSnapshots build/snapshots

icon: ## Regenerate Resources/AppIcon.icns from scripts/make-icon.swift
	$(SWIFT) scripts/make-icon.swift

clean: ## Remove .build, build and .build-*
	rm -rf .build build .build-*
