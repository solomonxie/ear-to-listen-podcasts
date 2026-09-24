.PHONY: help gen test ios release archive screenshots size clean

# The one simulator the tests run on. Overridable, because a wiped simulator list
# is the usual reason a green checkout stops building: make test SIMULATOR='iPhone 17'
SIMULATOR ?= iPhone 18 Pro

XCB = xcodebuild -project EarToListen.xcodeproj -scheme EarToListen \
      -skipPackagePluginValidation -skipMacroValidation

help:
	@echo "make ios          build + install onto the paired iPhone"
	@echo "make release      test, then archive + upload to App Store Connect"
	@echo "make archive      same, but stop at the .ipa (no upload)"
	@echo "make test         unit tests on the $(SIMULATOR) simulator"
	@echo "make size         Release .app size — the budget is 35 MB and falling"
	@echo "make screenshots  SHOTS=<dir>  resize to the App Store slots"
	@echo "make gen          regenerate the Xcode project from project.yml"
	@echo ""
	@echo "Signing reads DEVELOPMENT_TEAM from the environment or .env.local (gitignored)."
	@echo "Uploading needs one of these pairs in the same place:"
	@echo "  ASC_KEY_ID + ASC_ISSUER_ID          App Store Connect API key"
	@echo "  APPLE_ID   + APP_SPECIFIC_PASSWORD  Apple ID"
	@echo "With neither, make release stops at the .ipa and prints its path."

gen:
	xcodegen generate

# The one thing a simulator is for here — compiling and running tests. Installing
# or launching to look at a change goes on the phone (CLAUDE.md).
test: gen
	$(XCB) -destination 'platform=iOS Simulator,name=$(SIMULATOR)' test

install-ios:
	scripts/install-ios-device.sh

# Replaces Product > Archive > Distribute App. Build number is a timestamp, so
# every run sorts above the last without editing anything.
release: test
	@git diff --quiet HEAD -- || echo "warning: uncommitted changes are going into this build"
	scripts/release-ios.sh

# For when the upload is going through Transporter by hand. Blanking the credential
# variables here wouldn't do it — the script sources .env.local and would set them again.
archive:
	NO_UPLOAD=1 scripts/release-ios.sh

screenshots:
	scripts/store-screenshots.sh $(SHOTS)

# Release, never Debug: a Debug build carries a ~50 MB .debug.dylib and means nothing.
size: gen
	$(XCB) -configuration Release -destination 'generic/platform=iOS' \
	  -derivedDataPath build/dd-release CODE_SIGNING_ALLOWED=NO build
	@du -sh build/dd-release/Build/Products/Release-iphoneos/EarToListen.app

clean:
	rm -rf build
