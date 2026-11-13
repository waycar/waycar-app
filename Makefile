# Task runner for Waycar. Typical flows:
#   make install                 # build Debug and run it on the connected iPhone
#   make install-ipad            # same, on the connected iPad
#   make install NOTES=notes.txt # same, with a local What's New (or NOTES=auto)
#   make bump && make testflight # interim TestFlight build, no version cut
#   make publish                 # cut a release: see docs/guides/releasing.md

PROJECT := Waycar.xcodeproj
SCHEME  := Waycar
ARCHIVE := build/Waycar.xcarchive
DERIVED := build/DerivedData
APP_ID  := com.otreva.waycar
# The iPhone model for tests and screenshots: 6.9-inch, so README shots match the
# App Store's 1320x2868 slot even when SIM is overridden for a bug repro. A base
# model name gets any free simulator of that model's pool (`make sim-pool`); a
# copy's own name (`iPhone 17 Pro Max 2`) gets only that copy.
SCREENSHOT_SIM ?= iPhone 17 Pro Max
SIM     ?= $(SCREENSHOT_SIM)
SIM_IPAD ?= iPad Pro 13-inch (M5)
SIM_DESTINATION ?= platform=iOS Simulator,name=$(SIM)
SIMULATOR_UDID ?=
TEST_FLAGS ?=
BUILD_FLAGS ?=
IOS_WATCH_DEBOUNCE ?= 1s

# Actor-isolation gate (AGENTS.md, Conventions). `make test-app` fails on its
# findings; every other build into $(DERIVED) runs it non-fatally with
# `--touch`, so an offender it compiled is recompiled, and reported, by the
# next `make test-app` instead of slipping past it.
ACTOR_ISOLATION_HINT := View members used off the main actor (see above): make pure members nonisolated or the caller @MainActor (AGENTS.md, Conventions).
actor_isolation_soft_gate = { scripts/check-actor-isolated-calls.sh --touch $(1) || { [ $$? -ne 1 ] || echo "actor-isolation warnings found; touched the files so \`make test-app\` reports them. $(ACTOR_ISOLATION_HINT)" >&2; }; }

# First physical iPhone / iPad paired with devicectl; override with
# `make install DEVICE=<udid>` or `make install-ipad DEVICE_IPAD=<udid>`.
DEVICE ?= $(shell python3 scripts/find-ios-device.py iPhone)
DEVICE_IPAD ?= $(shell python3 scripts/find-ios-device.py iPad)

.PHONY: help generate resolve build test test-app test-swiftmosh test-ipad test-ci-app build-device install install-device install-ipad watch-ios-device sim sim-ipad build-sim sim-id sim-status sim-release sim-pool sim-doctor archive check-deployed-installer upload distribute testflight bump publish review-smoke clean check-device check-device-ipad ssh-artifacts verify-ssh-artifacts test-libssh2-patches screenshots

help: ## Show available targets
	@awk -F':.*## ' '/^[a-z-]+:.*## / { printf "  make %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

ssh-artifacts: ## Rebuild the pinned WaycarSSH XCFrameworks
	Packages/WaycarSSH/Scripts/build-native.sh

verify-ssh-artifacts: ## Verify WaycarSSH artifact hashes, slices, and policy
	Packages/WaycarSSH/Scripts/verify-native.sh

test-libssh2-patches: ## Test the libssh2 patches against a disposable local sshd (host, no simulator)
	Packages/WaycarSSH/Scripts/test-libssh2-patches.sh

generate: ## Regenerate the Xcode project from project.yml (XcodeGen)
	xcodegen generate

resolve: generate ## Resolve pinned Swift packages into .ci/source-packages
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME) \
		-clonedSourcePackagesDirPath .ci/source-packages

build: SHELL := /bin/bash
build: generate ## Build Debug for a physical device without installing
	@mkdir -p $(DERIVED)
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates build 2>&1 | tee $(DERIVED)/build.log; build_status=$$?; \
		$(call actor_isolation_soft_gate,$(DERIVED)/build.log); exit $$build_status

# Compiles before it queues, so the slot isn't held while it builds; once it has
# the slot, `test` rebuilds only what changed meanwhile. The slot stays held
# until `make sim-release`. The build log goes through the actor-isolation gate
# (AGENTS.md, Conventions), even when the build fails: an incremental rebuild
# prints warnings only for files it recompiles, so `--touch` marks offenders.
test-app: SHELL := /bin/bash
test-app: check-state-machines generate ## Run the app test suite (SIM_DESTINATION, TEST_FLAGS)
	@mkdir -p $(DERIVED)
	set -o pipefail; xcodebuild build-for-testing -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED) $(TEST_FLAGS) \
		2>&1 | tee $(DERIVED)/build-for-testing.log || { build_status=$$?; \
		scripts/check-actor-isolated-calls.sh --touch $(DERIVED)/build-for-testing.log || { \
		[ $$? -ne 1 ] || echo "$(ACTOR_ISOLATION_HINT)" >&2; }; \
		exit $$build_status; }
	scripts/check-actor-isolated-calls.sh --touch $(DERIVED)/build-for-testing.log || { \
		echo "$(ACTOR_ISOLATION_HINT)" >&2; \
		exit 1; }
	udid=$$(scripts/sim-slot.py acquire '$(SIM_DESTINATION)') && \
	python3 scripts/run-app-simulator-tests.py -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,id=$$udid" -derivedDataPath $(DERIVED) \
		$(TEST_FLAGS) test

# docs/design/state-machines.md indexes every StateMachine type; Python only,
# so it also runs on the agent host and in .github/workflows/state-machines.yml.
.PHONY: check-state-machines
check-state-machines: ## Check that docs/design/state-machines.md indexes every state machine
	python3 scripts/test-check-state-machines.py
	python3 scripts/check-state-machines.py

test: test-app ## Run the app, WaycarSSH, and SwiftMosh unit test suites
	udid=$$(scripts/sim-slot.py acquire '$(SIM_DESTINATION)') && \
	scripts/run-waycarssh-package-tests.sh "platform=iOS Simulator,id=$$udid"
	$(MAKE) test-swiftmosh

# Runs on the Mac host; the real-server tests skip unless SWIFTMOSH_REAL_E2E=1.
test-swiftmosh: ## Run the vendored SwiftMosh package test suite
	swift test --package-path Packages/SwiftMosh

# Requires a fresh New Agent form on the installed candidate.
.PHONY: test-directory-browser-ui
test-directory-browser-ui: ## Check first Browse presentation (SIMULATOR_UDID, requires idb)
	@test -n "$(SIMULATOR_UDID)" || { echo "SIMULATOR_UDID is required"; exit 1; }
	python3 scripts/test-remote-directory-browser.py --udid '$(SIMULATOR_UDID)' \
		--output-dir '$(DERIVED)/DirectoryBrowserUI'

test-ipad: ## Run the app, WaycarSSH, and SwiftMosh unit test suites on the iPad simulator
	$(MAKE) test SIM='$(SIM_IPAD)'

test-ci-app: ## Run the committed-project CI app lane (no generate)
	WAYCAR_CI_LANE=app WAYCAR_CI_SIMULATOR_UDID='$(or $(SIMULATOR_UDID),$(WAYCAR_CI_SIMULATOR_UDID))' \
		scripts/run-ci-ios-tests.sh

# TmuxTransportE2ETests against a Linux test box (scripts/testboxes) instead of
# the local sshd fixture; acquires and releases SIM through sim-slot. Options
# are variables, as for `publish`: DRY_RUN=1 probes the box and prints the
# fixture configuration only.
.PHONY: test-tmux-remote
test-tmux-remote: ## Run the tmux e2e suite against a test box (BOX=ubuntu-24.04, DRY_RUN=1, HERDR_STUB=auto|on|off, KEEP_SIM=1)
	@test -n "$(BOX)" || { echo "BOX is required: ubuntu-24.04, ubuntu-22.04, debian-12, fedora or rocky-9"; exit 1; }
	$(if $(DRY_RUN),,$(MAKE) generate)
	SIM='$(SIM)' DERIVED='$(DERIVED)' scripts/run-tmux-e2e-remote.sh $(if $(DRY_RUN),--dry-run) \
		$(if $(KEEP_SIM),--keep-simulator) --herdr-stub '$(or $(HERDR_STUB),auto)' '$(BOX)'

.PHONY: test-device-discovery
test-device-discovery: ## Test physical-device selection and explicit overrides
	python3 scripts/test-find-ios-device.py

# Harness lab (scripts/harness-lab): a mock model server plus an Ubuntu host
# with herdr, tmux and 17 agent harnesses, on the Colima context
# colima-waycar-harness. See scripts/harness-lab/README.md.
.PHONY: harness-lab-up harness-lab-down harness-lab-shell harness-lab-reinstall-plugin test-harness-lab
harness-lab-up: ## Build and start the harness lab (mock + host); SSH on 127.0.0.1:22300
	scripts/harness-lab/lab.sh up

harness-lab-down: ## Remove the harness lab's containers and network
	scripts/harness-lab/lab.sh down

harness-lab-shell: ## SSH into the harness lab host as waycar
	scripts/harness-lab/lab.sh shell

harness-lab-reinstall-plugin: ## Reinstall Waycar Host Tools on the lab host from plugin/
	scripts/harness-lab/lab.sh reinstall-plugin

# HarnessLabE2ETests against the lab (scripts/harness-lab/run-e2e.sh): starts
# the lab when its SSH does not answer, builds, leases SIM through sim-slot,
# and hands the suite its configuration through the Simulator's launchd
# environment, which plain `make test` never sets, so it skips there.
test-harness-lab: ## Run the harness lab e2e suite (KINDS=claude,agy BACKENDS=herdr,tmux KEEP_SIM=1 DRY_RUN=1)
	$(if $(DRY_RUN),,$(MAKE) generate)
	SIM='$(SIM)' DERIVED='$(DERIVED)' scripts/harness-lab/run-e2e.sh $(if $(DRY_RUN),--dry-run) \
		$(if $(KEEP_SIM),--keep-simulator) $(if $(KINDS),--kinds '$(KINDS)') \
		$(if $(BACKENDS),--backends '$(BACKENDS)')

check-device:
	@test -n "$(DEVICE)" || { echo "No physical iPhone found; pass DEVICE=<device identifier>"; exit 1; }

# Builds against the concrete device so automatic signing can register it
# in the development profile; the generic `build` target cannot. With the
# App Store Connect key (ASC_AUTH_FLAGS) it registers a new device without an
# account signed in to Xcode, which the Mac's GUI session lacks.
# `BUILD_NUMBER=<n>` overrides CFBundleVersion for this build only.
build-device: SHELL := /bin/bash
build-device: check-device generate
	@mkdir -p $(DERIVED)
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=iOS,id=$(DEVICE)' -derivedDataPath $(DERIVED) \
		$(if $(BUILD_NUMBER),CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)) \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration $(ASC_AUTH_FLAGS) build \
		2>&1 | tee $(DERIVED)/build-device.log; build_status=$$?; \
		$(call actor_isolation_soft_gate,$(DERIVED)/build-device.log); exit $$build_status

# `NOTES=<file|auto>` bundles a local What's New for this install
# (scripts/write-local-whats-new.sh) and always restores the committed seed.
install: check-device ## Build Debug, install on the iPhone, and relaunch it (NOTES=<file|auto> for What's New)
	@if [ -z "$(NOTES)" ]; then exec $(MAKE) install-device DEVICE="$(DEVICE)"; fi; \
	trap 'git checkout -- Sources/Waycar/Resources/WhatsNew.json' EXIT; \
	head=$$(git rev-parse HEAD) \
		&& scripts/write-local-whats-new.sh "$(NOTES)" "$(DEVICE)" \
		&& $(MAKE) install-device DEVICE="$(DEVICE)" LOCAL_INSTALL_SHA=$$head

install-device: build-device
	xcrun devicectl device install app --device $(DEVICE) \
		$(DERIVED)/Build/Products/Debug-iphoneos/Waycar.app
	xcrun devicectl device process launch --terminate-existing --device $(DEVICE) $(APP_ID) \
		|| echo "Installed, but the launch was refused (device locked?). Unlock it and open Waycar."
	$(if $(LOCAL_INSTALL_SHA),mkdir -p build/local-installs && echo $(LOCAL_INSTALL_SHA) > "build/local-installs/$(DEVICE)")

check-device-ipad:
	@test -n "$(DEVICE_IPAD)" || { echo "No physical iPad found; pass DEVICE_IPAD=<device identifier>"; exit 1; }

install-ipad: check-device-ipad ## Build Debug, install on the iPad, and relaunch it
	$(MAKE) install DEVICE="$(DEVICE_IPAD)"

watch-ios-device: ## Watch iOS code and install to a connected iPhone/iPad
	@command -v watchexec >/dev/null || { echo "watchexec not found. Install with: brew install watchexec"; exit 1; }
	watchexec \
		--watch Sources \
		--watch Packages/WaycarSSH/Sources \
		--watch Packages/WaycarSSH/NativeSupport \
		--watch Packages/WaycarSSH/Package.swift \
		--watch Packages/GhosttyTerminal/Sources \
		--watch Packages/GhosttyTerminal/Package.swift \
		--watch project.yml \
		--exts swift,h,modulemap,yml,plist,xcprivacy,entitlements,resolved,json,png,ttf \
		--debounce "$(IOS_WATCH_DEBOUNCE)" \
		--on-busy-update queue \
		-- make install DEVICE="$(DEVICE)"

sim: SHELL := /bin/bash
sim: generate ## Build Debug and run it on the simulator (override with SIM=<name>)
	@mkdir -p $(DERIVED)
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED) build \
		2>&1 | tee $(DERIVED)/sim.log; build_status=$$?; \
		$(call actor_isolation_soft_gate,$(DERIVED)/sim.log); exit $$build_status
	udid=$$(scripts/sim-slot.py acquire '$(SIM)') && \
	open -a Simulator && \
	xcrun simctl install "$$udid" $(DERIVED)/Build/Products/Debug-iphonesimulator/Waycar.app && \
	xcrun simctl launch --terminate-running-process "$$udid" $(APP_ID)

sim-ipad: ## Build Debug and run it on the iPad simulator (override with SIM_IPAD=<name>)
	$(MAKE) sim SIM='$(SIM_IPAD)'

build-sim: SHELL := /bin/bash
build-sim: generate ## Build Debug for SIM_DESTINATION using .ci/source-packages
	@mkdir -p $(DERIVED)
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED) \
		-clonedSourcePackagesDirPath .ci/source-packages $(BUILD_FLAGS) build \
		2>&1 | tee $(DERIVED)/build-sim.log; build_status=$$?; \
		$(call actor_isolation_soft_gate,$(DERIVED)/build-sim.log); exit $$build_status

sim-id: build-sim ## Install and launch the app on SIMULATOR_UDID only
	@test -n "$(SIMULATOR_UDID)" || { echo "SIMULATOR_UDID is required; pass SIMULATOR_UDID=<uuid>"; exit 1; }
	@case '$(SIM_DESTINATION)' in \
	  *booted*) echo "sim-id refuses a generic booted destination"; exit 1 ;; \
	  *id=$(SIMULATOR_UDID)*) ;; \
	  *) echo "SIM_DESTINATION must include id=$(SIMULATOR_UDID) (got '$(SIM_DESTINATION)')"; exit 1 ;; \
	esac
	scripts/sim-slot.py acquire '$(SIMULATOR_UDID)'
	xcrun simctl install '$(SIMULATOR_UDID)' $(DERIVED)/Build/Products/Debug-iphonesimulator/Waycar.app
	xcrun simctl launch --terminate-running-process '$(SIMULATOR_UDID)' $(APP_ID)

sim-status: ## Show the machine-wide simulator queue
	@scripts/sim-slot.py status

sim-release: ## Shut down this worktree's simulators and free their slots
	scripts/sim-slot.py release --all

sim-pool: ## Create missing copies: 3 SCREENSHOT_SIM iPhones and 2 SIM_IPAD iPads in all
	scripts/sim-slot.py ensure-pool --size 3 '$(SCREENSHOT_SIM)'
	scripts/sim-slot.py ensure-pool --size 2 '$(SIM_IPAD)'

sim-doctor: ## Diagnose a stuck simulator queue and apply only its safe fixes
	scripts/sim-slot.py doctor

screenshots: generate ## Regenerate README + waycar.dev screenshots (OMP demo terminal) on SCREENSHOT_SIM and SIM_IPAD
	python3 scripts/demo-terminal/make_omp_frames.py
	scripts/capture-screenshots.sh '$(SCREENSHOT_SIM)' '$(SIM_IPAD)'

# ADMIN_BUILD=1 (exactly 1) compiles in the admin panel (ADR 0032):
# interim TestFlight builds only; any other value, 0 included, leaves it out.
# `make publish` archives without it, and that is the only build to submit to
# App Review.
ADMIN_BUILD ?=
check-deployed-installer: ## Fail unless waycar.dev serves a plugin at least every WaycarPluginRequirement minimum (archive runs it first)
	sh scripts/check-deployed-installer.sh

archive: check-deployed-installer generate ## Archive a Release build for distribution (ADMIN_BUILD=1: interim TestFlight build with the admin panel)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates \
		$(if $(filter 1,$(ADMIN_BUILD)),WAYCAR_ADMIN_CONDITION=WAYCAR_ADMIN) archive
	sh scripts/archive-stub-dsyms.sh $(ARCHIVE)

# Authenticate the export with the App Store Connect API key when available
# (same as testflight.yml) instead of relying on an Xcode-signed-in account.
# A launchd job or bare SSH session reads no ~/.env, so the key's ids come
# from there unless already set, as scripts/asc_client.py does.
ASC_FROM_DOTENV = $(shell sed -n 's/^\(export \)\{0,1\}$(1)=//p' $(HOME)/.env 2>/dev/null | tail -n 1 | tr -d "\"'")
ASC_API_KEY_ID ?= $(call ASC_FROM_DOTENV,ASC_API_KEY_ID)
ASC_API_ISSUER_ID ?= $(call ASC_FROM_DOTENV,ASC_API_ISSUER_ID)
ASC_API_KEY_PATH ?= $(HOME)/.appstoreconnect/private/AuthKey_$(ASC_API_KEY_ID).p8
ASC_AUTH_FLAGS = $(if $(and $(ASC_API_KEY_ID),$(ASC_API_ISSUER_ID),$(wildcard $(ASC_API_KEY_PATH))),-authenticationKeyPath "$(ASC_API_KEY_PATH)" -authenticationKeyID "$(ASC_API_KEY_ID)" -authenticationKeyIssuerID "$(ASC_API_ISSUER_ID)")

upload: ## Upload the existing archive to App Store Connect (TestFlight)
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist scripts/ExportOptions.plist \
		-exportPath build/export -allowProvisioningUpdates \
		$(ASC_AUTH_FLAGS)

# The Waycar Testers group has no automatic distribution, so a build only
# reaches testers once attached (same step as testflight.yml's distribute job).
distribute: ## Wait for the project.yml build to process, then add it to Waycar Testers
	scripts/asc-distribute-build.py $$(awk -F'"' '/CURRENT_PROJECT_VERSION: "/ && $$2 ~ /^[0-9]+$$/ { print $$2; exit }' project.yml)

testflight: ADMIN_BUILD := 1
testflight: archive upload distribute ## Archive, upload, and distribute an interim build to Waycar Testers (admin panel included)

bump: ## Increment CURRENT_PROJECT_VERSION in project.yml (app + extension stay in lockstep)
	@CUR=$$(awk -F'"' '/CURRENT_PROJECT_VERSION: "/ && $$2 ~ /^[0-9]+$$/ { print $$2; exit }' project.yml); \
	NEW=$$((CUR + 1)); \
	sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[0-9]+\"/CURRENT_PROJECT_VERSION: \"$$NEW\"/g" project.yml; \
	echo "CURRENT_PROJECT_VERSION: $$CUR -> $$NEW"
	@# Regenerate immediately so the tracked pbxproj changes with project.yml
	@# and one commit carries both (otherwise the next make target regenerates
	@# it after the bump commit and leaves it dirty).
	@$(MAKE) generate

# The last App Store-approved release, which a reviewer's install updates.
# Bump it once a release is live (docs/guides/releasing.md); empty installs
# fresh only. REVIEW_SMOKE_REPO is a clone holding that tag when this one
# does not (default: this checkout).
REVIEW_SMOKE_PREVIOUS ?= v1.3.0
REVIEW_SMOKE_REPO ?=
review-smoke: generate ## Release build on reviewer-shaped simulators: update over REVIEW_SMOKE_PREVIOUS (from REVIEW_SMOKE_REPO), walkthrough, videos
	REVIEW_SMOKE_PREVIOUS='$(REVIEW_SMOKE_PREVIOUS)' REVIEW_SMOKE_REPO='$(REVIEW_SMOKE_REPO)' scripts/review-smoke.sh

# Options are make variables, not flags: make eats `--dry-run` as its own -n and
# rejects unknown long options, so a flag would never reach the recipe.
publish: ## Cut a release from CHANGELOG [Unreleased] (VERSION=x.y.z DRY_RUN=1 YES=1)
	@VERSION='$(VERSION)' DRY_RUN='$(DRY_RUN)' YES='$(YES)' scripts/publish.sh

clean: ## Remove local build products
	rm -rf build
