BUILD_PROFILE ?= release

VERSION ?= $(shell node -p "require('./package.json').version")
BUMP ?= minor
NEXT_VERSION ?= $(shell node -e 'const [maj,min,pat]=require("./package.json").version.split(".").map(Number); const bump="$(BUMP)" || "minor"; if (bump === "major") console.log(`$${maj+1}.0.0`); else if (bump === "patch") console.log(`$${maj}.$${min}.$${pat+1}`); else console.log(`$${maj}.$${min+1}.0`);')
VERSION_TO_TAG := $(if $(filter command line,$(origin VERSION)),$(VERSION),$(NEXT_VERSION))
CONFIRM ?= no

.PHONY: help init dev build ios-init ios-dev ios-build test fmt check update-amaru create-release

help:
	@echo "\033[1;4mBuilding & Running:\033[00m"
	@grep -E '^[a-z]+[^:]+:.*## &build ' Makefile | while read -r l; do printf "  \033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 3- -d'#' | sed 's/^ \&build//')\n"; done
	@echo ""
	@echo "\033[1;4mDev & Testing:\033[00m"
	@grep -E '^[a-z]+[^:]+:.*## &test ' Makefile | while read -r l; do printf "  \033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 3- -d'#' | sed 's/^ \&test//')\n"; done
	@echo ""
	@echo "\033[1;4mConfiguration:\033[00m"
	@grep -E '^[a-zA-Z0-9_]+ \?= ' Makefile | sort | while read -r l; do printf "  \033[36m$$(echo $$l | cut -f 1 -d'=')\033[00m=$$(echo $$l | cut -f 2- -d'=')\n"; done

init: ## &build Install npm dependencies
	npm install

dev: init ## &build Start Tauri development server
	npm run tauri -- dev

build: ## &build Compile for $BUILD_PROFILE
	npm run tauri -- build --profile $(BUILD_PROFILE)

ios-init: init ## &build Initialize the iOS project
	npm run tauri -- ios init

ios-dev: init ## &build Start Tauri development server on iOS simulator
	npm run tauri -- ios dev

ios-build: init ## &build Compile for iOS
	npm run tauri -- ios build

test: ## &test Run Rust tests
	cargo test --manifest-path src-tauri/Cargo.toml

fmt: ## &test Format Rust code
	cargo fmt --manifest-path src-tauri/Cargo.toml

check: ## &test Run clippy lints
	cargo clippy --manifest-path src-tauri/Cargo.toml

update-amaru: ## &build Update amaru git dependencies to latest commits
	cargo update --manifest-path src-tauri/Cargo.toml amaru amaru-kernel amaru-stores amaru-tracing-json

create-release: ## &build Propose release version (default), tag/push with CONFIRM=yes. Supports BUMP=major|minor|patch or VERSION=x.y.z
	@echo "Proposed release tag: v$(VERSION_TO_TAG)"
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "No tag created. Re-run with CONFIRM=yes to create and push v$(VERSION_TO_TAG)."; \
	else \
		git -c tag.gpgSign=false tag --no-sign v$(VERSION_TO_TAG); \
		git push origin v$(VERSION_TO_TAG); \
	fi
