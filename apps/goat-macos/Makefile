# GOAT: build like it's 1337
CONFIG ?= Debug
-include signing.local.mk
SWIFT_FLAGS ?=
XCODE_FLAGS ?=
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

.PHONY: gen build run test test-app format lint verify clean release dmg

gen:
	python3 scripts/release-metadata.py generate --channel "$(RELEASE_CHANNEL)" $(if $(RELEASE_TAG),--tag "$(RELEASE_TAG)",)
	xcodegen generate
	mkdir -p GOAT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
	cp Package.resolved GOAT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

build: gen
	xcodebuild -project GOAT.xcodeproj -scheme GOAT -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile $(SIGNING_FLAGS) build

run: build
	@osascript -e 'tell application id "dev.leet.goat" to quit' >/dev/null 2>&1 || true
	@for _ in 1 2 3 4 5 6 7 8 9 10; do \
		pgrep -f '$(APP)/Contents/MacOS/GOAT' >/dev/null || break; \
		sleep 0.1; \
	done
	@pkill -TERM -f '$(APP)/Contents/MacOS/GOAT' >/dev/null 2>&1 || true
	open -n $(APP)

test:
	swift test $(SWIFT_FLAGS) --package-path $(MODULES) --no-parallel

test-app: gen
	xcodebuild -project GOAT.xcodeproj -scheme GOAT -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile ENABLE_TESTABILITY=YES $(SIGNING_FLAGS) $(XCODE_FLAGS) test

format:
	swift format --in-place --recursive App/Sources App/Tests Modules/Sources Modules/Tests

lint:
	python3 scripts/release-metadata.py check
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'
	python3 scripts/sync-module-docs.py --check
	python3 scripts/check-module-boundaries.py
	python3 scripts/check-judas-boundaries.py
	swift format lint --strict --recursive App/Sources App/Tests Modules/Sources Modules/Tests

verify: lint test test-app
	$(MAKE) build

clean:
	rm -rf .build GOAT.xcodeproj $(DIST)

# Release build: Release config, Hardened Runtime on (required for notarization, ADR-0007).
# Signing stays ad-hoc unless a local or command-line release identity is supplied.
release: RELEASE_CHANNEL = Candidate
release: gen
	xcodebuild -project GOAT.xcodeproj -scheme GOAT -configuration Release \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS' \
	  -onlyUsePackageVersionsFromResolvedFile \
	  ENABLE_HARDENED_RUNTIME=YES \
	  $(RELEASE_SIGNING_FLAGS) \
	  OTHER_CODE_SIGN_FLAGS="$(if $(filter -,$(RELEASE_SIGNING_IDENTITY)),,--timestamp)" \
	  build
	python3 scripts/release-metadata.py bundle --channel "$(RELEASE_CHANNEL)" $(if $(RELEASE_TAG),--tag "$(RELEASE_TAG)",) --app "$(DERIVED)/Build/Products/Release/GOAT.app"

# Package the Release .app into a distributable DMG under dist/.
dmg: RELEASE_CHANNEL = Candidate
dmg: release
	$(MAKE) CONFIG=Release cli
	codesign --force --options runtime $(if $(filter -,$(RELEASE_SIGNING_IDENTITY)),,--timestamp) --sign "$(RELEASE_SIGNING_IDENTITY)" Modules/.build/release/goat
	CLI="Modules/.build/release/goat" CONFIG=Release APP="$(DERIVED)/Build/Products/Release/GOAT.app" DIST="$(DIST)" \
	  ./scripts/package-dmg.sh

# Build the local-only CLI. The DMG ships it beside GOAT.app.
.PHONY: cli
cli:
	swift build --package-path Modules --product goat -c $(shell echo $(CONFIG) | tr A-Z a-z)

.PHONY: module-docs
module-docs:
	python3 scripts/sync-module-docs.py
