# GOAT: build like it's 1337
CONFIG ?= Debug
-include signing.local.mk
SWIFT_FLAGS ?=
TEST_PLAN ?= All
MODULE ?=
XCODE_FLAGS ?=
# Optional Xcode compilation cache store (ADR-0095). Empty keeps Xcode's default behaviour.
CAS_PATH ?=
CACHE_FLAGS = $(if $(CAS_PATH),COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH="$(CAS_PATH)",)
DERIVED := .build/DerivedData
APP := $(DERIVED)/Build/Products/$(CONFIG)/GOAT.app
MODULES := Modules
RELEASE_CHANNEL ?= Development
RELEASE_TAG ?=
export MARKETING_VERSION CURRENT_PROJECT_VERSION GOAT_CODENAME RELEASE_CHANNEL RELEASE_TAG
CODE_SIGN_IDENTITY ?= -
RELEASE_SIGNING_IDENTITY ?= $(CODE_SIGN_IDENTITY)
DEVELOPMENT_TEAM ?=
SIGNING_FLAGS = CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)"
RELEASE_SIGNING_FLAGS = CODE_SIGN_IDENTITY="$(RELEASE_SIGNING_IDENTITY)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)"
DIST := dist

.PHONY: test-module test-package test-tools test-web gen prepare open build run test test-app format lint verify clean release check-signing verify-signing build-signed dmg

# Compatibility alias: never regenerate or overwrite the maintained project.
gen: prepare

prepare:
	python3 scripts/release-metadata.py check --channel "$(RELEASE_CHANNEL)" $(if $(RELEASE_TAG),--tag "$(RELEASE_TAG)",)
	python3 scripts/check-xcode-project.py
	python3 scripts/check-test-layout.py

open: prepare
	open GOAT.xcodeproj

# Command-line ARCHS also applies to Swift package dependencies.
build: prepare
	xcodebuild -project GOAT.xcodeproj -scheme GOAT -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -onlyUsePackageVersionsFromResolvedFile $(SIGNING_FLAGS) GOAT_RELEASE_CHANNEL="$(RELEASE_CHANNEL)" RELEASE_TAG="$(RELEASE_TAG)" $(CACHE_FLAGS) $(XCODE_FLAGS) build

run: build
	@osascript -e 'tell application id "dev.leet.goat" to quit' >/dev/null 2>&1 || true
	@for _ in 1 2 3 4 5 6 7 8 9 10; do \
		pgrep -f '$(APP)/Contents/MacOS/GOAT' >/dev/null || break; \
		sleep 0.1; \
	done
	@pkill -TERM -f '$(APP)/Contents/MacOS/GOAT' >/dev/null 2>&1 || true
	open -n $(APP)

# MODULE selects both layers; unfiltered test retains the full package gate.
test:
ifeq ($(strip $(MODULE)),)
	$(MAKE) test-package
else
	$(MAKE) test-module
endif

test-module:
	python3 scripts/test-domain.py "$(MODULE)"

test-package:
	$(if $(MODULE),@test -d "Modules/Tests/$(MODULE)Tests" || { echo "Unknown package test domain: $(MODULE)"; exit 2; },@true)
	swift test $(SWIFT_FLAGS) --arch arm64 --package-path $(MODULES) --no-parallel $(if $(MODULE),--filter '^$(MODULE)Tests[.]',)

test-tools:
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'
	python3 -m unittest discover -s ../../scripts/tests -p 'test_*.py'

test-web:
	npm --prefix ../../web run test:unit

test-app: prepare
	python3 scripts/run-host-tests.py xcodebuild -project GOAT.xcodeproj -scheme GOAT -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -onlyUsePackageVersionsFromResolvedFile ENABLE_TESTABILITY=YES $(SIGNING_FLAGS) GOAT_RELEASE_CHANNEL="$(RELEASE_CHANNEL)" RELEASE_TAG="$(RELEASE_TAG)" -testPlan "$(TEST_PLAN)" GOAT_APP_BUNDLE_IDENTIFIER=dev.leet.goat.test-host $(CACHE_FLAGS) $(XCODE_FLAGS) test

format:
	swift format --in-place --recursive App/Sources App/Tests Modules/Sources Modules/Tests

lint:
	python3 scripts/release-metadata.py check
	$(MAKE) test-tools
	python3 scripts/sync-module-docs.py --check
	python3 scripts/check-xcode-project.py
	python3 scripts/check-test-layout.py
	python3 scripts/check-module-boundaries.py
	python3 scripts/check-judas-boundaries.py
	swift format lint --strict --recursive App/Sources App/Tests Modules/Sources Modules/Tests

# A focused shell selection must never silently narrow the release gate.
verify: lint
	$(MAKE) test-package MODULE= SWIFT_FLAGS="-c $(shell echo $(CONFIG) | tr A-Z a-z)"
	$(MAKE) test-app TEST_PLAN=All XCODE_FLAGS=
	$(MAKE) build

clean:
	rm -rf .build $(DIST)

# Release build: Release config, Hardened Runtime on (required for notarization, ADR-0007).
# Signing stays ad-hoc unless a local or command-line release identity is supplied.
release: RELEASE_CHANNEL = Candidate
release: prepare
	xcodebuild -project GOAT.xcodeproj -scheme GOAT -configuration Release \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' ARCHS=arm64 \
	  -onlyUsePackageVersionsFromResolvedFile \
	  ENABLE_HARDENED_RUNTIME=YES \
	  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
	  $(RELEASE_SIGNING_FLAGS) GOAT_RELEASE_CHANNEL="$(RELEASE_CHANNEL)" RELEASE_TAG="$(RELEASE_TAG)" \
	  OTHER_CODE_SIGN_FLAGS="$(if $(filter -,$(RELEASE_SIGNING_IDENTITY)),,--timestamp)" \
	  build
	python3 scripts/release-metadata.py bundle --channel "$(RELEASE_CHANNEL)" $(if $(RELEASE_TAG),--tag "$(RELEASE_TAG)",) --app "$(DERIVED)/Build/Products/Release/GOAT.app"

# A signed build is successful only after its Developer ID publisher, team,
# hardened runtime, secure timestamp and release entitlements are verified.
check-signing:
	@CODE_SIGN_IDENTITY="$(RELEASE_SIGNING_IDENTITY)" APPLE_TEAM_ID="$(DEVELOPMENT_TEAM)" \
	  python3 scripts/check-release-signing.py --local

verify-signing:
	@CODE_SIGN_IDENTITY="$(RELEASE_SIGNING_IDENTITY)" APPLE_TEAM_ID="$(DEVELOPMENT_TEAM)" \
	  python3 scripts/check-release-signing.py --verify "$(DERIVED)/Build/Products/Release/GOAT.app"

build-signed: RELEASE_CHANNEL = Candidate
build-signed: check-signing
	$(MAKE) release RELEASE_CHANNEL="$(RELEASE_CHANNEL)" RELEASE_TAG="$(RELEASE_TAG)"
	$(MAKE) verify-signing

# Package the Release .app into a distributable DMG under dist/.
dmg: RELEASE_CHANNEL = Candidate
dmg: release
	$(MAKE) CONFIG=Release cli
	codesign --force --options runtime $(if $(filter -,$(RELEASE_SIGNING_IDENTITY)),,--timestamp) --sign "$(RELEASE_SIGNING_IDENTITY)" Modules/.build/release/goat
	CLI="Modules/.build/release/goat" CONFIG=Release APP="$(DERIVED)/Build/Products/Release/GOAT.app" DIST="$(DIST)" \
	  ./scripts/package-dmg.sh

# Build the local-only CLI. The DMG ships it inside CLI Tools.
.PHONY: cli
cli:
	swift build --arch arm64 --package-path Modules --product goat -c $(shell echo $(CONFIG) | tr A-Z a-z)

.PHONY: module-docs
module-docs:
	python3 scripts/sync-module-docs.py
