# Build, test and deploy Pinball. `make help` lists the targets; see README.md.

PROJECT   = Pinball.xcodeproj
SCHEME    = Pinball
BUNDLE_ID = com.igorchernakov.pinball
CONFIG   ?= Release
# Empty for the only connected iPhone. Otherwise a name or identifier from `make list-devices`.
DEVICE   ?=
# Empty for the team of the installed Apple Development certificate.
TEAM     ?=
SIMULATOR ?= iPhone 17

DEVICE_APP    = Build/Products/$(CONFIG)-iphoneos/Pinball.app
SIMULATOR_APP = Build/Products/Debug-iphonesimulator/Pinball.app

.DEFAULT_GOAL := help
.PHONY: help iphone iphone-deploy iphone-device list-devices simulator simulator-run test previews scenes spacing playtest

help:
	@echo "iphone         - Build a signed app for iPhone (CONFIG=Release, TEAM=...)"
	@echo "iphone-deploy  - Build, install and launch on the connected iPhone (DEVICE=...)"
	@echo "list-devices   - List paired devices and simulators"
	@echo "simulator      - Build for the iOS Simulator"
	@echo "simulator-run  - Build, install and launch in the Simulator (SIMULATOR='iPhone 17')"
	@echo "scenes         - Build tables and meshes from Scenes/*.xml"
	@echo "spacing        - List parts too close together on screen"
	@echo "playtest       - Play every level headlessly and list problems (--tune via PLAYTEST=)"
	@echo "test           - Run the headless tests on this Mac"
	@echo "previews       - Render Art/Previews from the real scene"

scenes:
	python3 tools/scene/compile_scenes.py
	tools/compile_models.sh

playtest:
	python3 tools/playtest/run_playtests.py $(PLAYTEST)

spacing:
	python3 tools/scene/check_spacing.py --list 10

iphone:
	@team="$(TEAM)"; \
	if [ -z "$$team" ]; then \
		team="$$(security find-certificate -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
			| awk -F' = ' '/organizationalUnitName/ { print $$2; exit }')"; \
	fi; \
	if [ -z "$$team" ]; then \
		echo "No Apple Development certificate found. Sign in to Xcode, or set TEAM=..." >&2; \
		exit 1; \
	fi; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination generic/platform=iOS \
		-derivedDataPath Build/Device -allowProvisioningUpdates DEVELOPMENT_TEAM="$$team" build

# Prints the DEVICE to use, or the only available physical iPhone, ignoring simulators and iPads.
iphone-device:
	@if [ -n "$(DEVICE)" ]; then echo "$(DEVICE)"; exit 0; fi; \
	devices="$$(xcrun devicectl list devices)" || exit $$?; \
	found="$$(printf '%s\n' "$$devices" | awk '/iPhone/ && !/simulated/ { \
		for (i = 1; i <= NF; i++) { \
			if ($$i !~ /^[[:xdigit:]]{8}-[[:xdigit:]]{16}$$/) continue; \
			state = i + 1; if ($$state == "(UDID)") state++; \
			if ($$state == "available" || $$state == "connected") print $$i; \
		} \
	}')"; \
	count="$$(printf '%s\n' "$$found" | sed '/^$$/d' | wc -l | tr -d ' ')"; \
	if [ "$$count" -ne 1 ]; then \
		echo "Expected exactly one available iPhone; found $$count. Use make list-devices and set DEVICE=..." >&2; \
		exit 1; \
	fi; \
	echo "$$found"

iphone-deploy: iphone
	@device="$$($(MAKE) -s iphone-device)" || exit $$?; \
	echo "Deploying to $$device"; \
	xcrun devicectl device install app --device "$$device" "$(DEVICE_APP)" && \
	xcrun devicectl device process launch --device "$$device" --terminate-existing $(BUNDLE_ID)

list-devices:
	xcrun devicectl list devices

simulator:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination "platform=iOS Simulator,name=$(SIMULATOR)" \
		-derivedDataPath Build/Sim build

simulator-run: simulator
	-xcrun simctl boot "$(SIMULATOR)"
	xcrun simctl bootstatus "$(SIMULATOR)" -b
	xcrun simctl install "$(SIMULATOR)" "$(SIMULATOR_APP)"
	xcrun simctl launch --terminate-running-process "$(SIMULATOR)" $(BUNDLE_ID)

test:
	python3 tools/scene/test_scenes.py
	xcodebuild -project $(PROJECT) -scheme PinballCoreTests -destination platform=macOS -derivedDataPath Build/Mac test

previews:
	tools/render_preview.sh "$(CURDIR)/Art/Previews"
