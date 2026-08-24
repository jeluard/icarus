BUILD_PROFILE ?= release
IOS_SIMULATOR ?=

VERSION ?= $(shell node -p "require('./package.json').version")
BUMP ?= patch
BASE_VERSION ?= $(shell node -e 'const fs=require("fs"); const cp=require("child_process"); const semver=/^(\d+)\.(\d+)\.(\d+)$$/; const versions=[]; const add=(v)=>{ if(typeof v!=="string") return; const m=v.trim().match(semver); if(m) versions.push([Number(m[1]),Number(m[2]),Number(m[3])]); }; try { add(JSON.parse(fs.readFileSync("./package.json","utf8")).version); } catch(_) {} try { add(JSON.parse(fs.readFileSync("./src-tauri/tauri.conf.json","utf8")).version); } catch(_) {} try { const cargo=fs.readFileSync("./src-tauri/Cargo.toml","utf8"); const m=cargo.match(/^version\s*=\s*"(\d+\.\d+\.\d+)"/m); if(m) add(m[1]); } catch(_) {} try { const tags=cp.execSync("git tag --list \"v*.*.*\"", {stdio:["ignore","pipe","ignore"]}).toString().trim().split(/\n+/).filter(Boolean); for(const t of tags) add(t.replace(/^v/,"")); } catch(_) {} if(!versions.length){ console.log("0.1.0"); process.exit(0);} versions.sort((a,b)=>a[0]-b[0] || a[1]-b[1] || a[2]-b[2]); const v=versions[versions.length-1]; console.log(v[0]+"."+v[1]+"."+v[2]);')
BASE_MAJOR := $(word 1,$(subst ., ,$(BASE_VERSION)))
BASE_MINOR := $(word 2,$(subst ., ,$(BASE_VERSION)))
BASE_PATCH := $(word 3,$(subst ., ,$(BASE_VERSION)))
NEXT_PATCH_VERSION := $(BASE_MAJOR).$(BASE_MINOR).$(shell expr $(BASE_PATCH) + 1)
NEXT_MINOR_VERSION := $(BASE_MAJOR).$(shell expr $(BASE_MINOR) + 1).0
NEXT_MAJOR_VERSION := $(shell expr $(BASE_MAJOR) + 1).0.0
NEXT_VERSION := $(if $(filter major,$(BUMP)),$(NEXT_MAJOR_VERSION),$(if $(filter minor,$(BUMP)),$(NEXT_MINOR_VERSION),$(NEXT_PATCH_VERSION)))
VERSION_TO_TAG := $(if $(filter command line,$(origin VERSION)),$(VERSION),$(NEXT_VERSION))
CONFIRM ?= no

.PHONY: help init dev build ios-init ios-dev ios-build test fmt check update-amaru apple-secrets create-release

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
	APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:--}" npm run tauri -- build

ios-init: init ## &build Initialize the iOS project
	npm run tauri -- ios init

ios-dev: init ## &build Start Tauri development server on iOS simulator (set IOS_SIMULATOR to force one)
	npm run tauri -- ios dev $(if $(strip $(IOS_SIMULATOR)),"$(IOS_SIMULATOR)")

ios-build: init ## &build Compile for iOS
	npm run tauri -- ios build

test: ## &test Run Rust tests
	cargo test --manifest-path src-tauri/Cargo.toml

fmt: ## &test Format Rust code
	cargo fmt --manifest-path src-tauri/Cargo.toml

check: ## &test Run clippy lints
	cargo clippy --manifest-path src-tauri/Cargo.toml

update-amaru: ## &build Refresh dependencies locked to the configured Amaru branch
	cargo update --manifest-path src-tauri/Cargo.toml amaru-bootstrap amaru-node

apple-secrets: ## &build Populate GitHub Actions Apple signing secrets from local defaults and prompts
	bash scripts/setup-gh-apple-secrets.sh $(if $(CERTIFICATE_PATH),--certificate-path "$(CERTIFICATE_PATH)")

create-release: ## &build Propose incremented version; release requires agreed VERSION=x.y.z plus CONFIRM=yes
	@echo "Proposed release tag: v$(VERSION_TO_TAG)"
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "No tag created. Agree on a version, then run: make create-release VERSION=$(VERSION_TO_TAG) CONFIRM=yes"; \
	else \
		if [ "$(origin VERSION)" != "command line" ]; then \
			echo "Select agreed increment from base v$(BASE_VERSION):"; \
			echo "  1) patch -> v$(NEXT_PATCH_VERSION)"; \
			echo "  2) minor -> v$(NEXT_MINOR_VERSION)"; \
			echo "  3) major -> v$(NEXT_MAJOR_VERSION)"; \
			echo "  4) custom semver"; \
			printf "Choice [1/2/3/4] (default 1): "; \
			read choice; \
			case "$$choice" in \
				1) AGREED_VERSION="$(NEXT_PATCH_VERSION)" ;; \
				3) AGREED_VERSION="$(NEXT_MAJOR_VERSION)" ;; \
				4) printf "Enter version (x.y.z): "; read AGREED_VERSION ;; \
				*) AGREED_VERSION="$(NEXT_PATCH_VERSION)" ;; \
			esac; \
			if ! echo "$$AGREED_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
				echo "Invalid version: $$AGREED_VERSION"; \
				exit 2; \
			fi; \
		else \
			AGREED_VERSION="$(VERSION)"; \
		fi; \
		AGREED_VERSION="$$AGREED_VERSION" node -e 'const fs=require("fs"); const version=process.env.AGREED_VERSION; const writeJson=(path)=>{ const data=JSON.parse(fs.readFileSync(path,"utf8")); data.version=version; fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n"); }; writeJson("package.json"); writeJson("src-tauri/tauri.conf.json"); const cargoPath="src-tauri/Cargo.toml"; const cargo=fs.readFileSync(cargoPath,"utf8").replace(/^version\s*=\s*"[^"]*"/m, `version = "$${version}"`); fs.writeFileSync(cargoPath, cargo);' \
			echo "Updated package.json, src-tauri/tauri.conf.json, and src-tauri/Cargo.toml to v$$AGREED_VERSION"; \
		echo "Agreed release tag: v$$AGREED_VERSION"; \
			git add package.json src-tauri/tauri.conf.json src-tauri/Cargo.toml; \
			if ! git diff --cached --quiet -- package.json src-tauri/tauri.conf.json src-tauri/Cargo.toml; then \
				git commit -m "chore(release): v$$AGREED_VERSION"; \
			fi; \
		if git rev-parse -q --verify "refs/tags/v$$AGREED_VERSION" >/dev/null; then \
			echo "Local tag v$$AGREED_VERSION already exists."; \
		else \
			git -c tag.gpgSign=false tag --no-sign v$$AGREED_VERSION; \
		fi; \
		git push origin v$$AGREED_VERSION; \
	fi
