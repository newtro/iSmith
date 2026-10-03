# iSmith: build, test and run from the command line.
# The Xcode project is generated from project.yml (XcodeGen) and not committed.
#
# Debug builds are "iSmith Dev" (bundle id com.scottsmith.ismith.debug, data in
# ~/Library/Application Support/iSmith Dev, their own Keychain items). Release is the installed
# "iSmith" (com.scottsmith.ismith).

PROJECT := iSmith.xcodeproj
DERIVED := build
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme iSmith -configuration Debug -derivedDataPath $(DERIVED)
XCODEBUILD_RELEASE := xcodebuild -project $(PROJECT) -scheme iSmith -configuration Release -derivedDataPath $(DERIVED)
APP := $(DERIVED)/Build/Products/Debug/iSmith.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/iSmith.app
INSTALLED := /Applications/iSmith.app

.PHONY: build test test-package test-app run release install project clean

build: project
	$(XCODEBUILD) build

# The package tests (SignInSync: sync, vault and config; BraveImport: Brave profiles, bookmarks
# and passwords; Blocking: ad and tracker blocking; Passwords: store, matching, autofill;
# BrowserData: history, bookmarks, site settings, downloads), then the app-hosted tests.
test: test-package test-app

test-package:
	cd Packages/SignInSync && swift test
	cd Packages/BraveImport && swift test
	cd Packages/Blocking && swift test
	cd Packages/Passwords && swift test
	cd Packages/BrowserData && swift test

test-app: project
	$(XCODEBUILD) test

# Builds and opens the Debug app, "iSmith Dev". It never touches the installed iSmith's data.
run: build
	open $(APP)

release: project
	$(XCODEBUILD_RELEASE) build

# Builds Release and installs it as /Applications/iSmith.app. Quit iSmith first: replacing a
# running app's bundle can crash it.
install: release
	@if pgrep -f '$(INSTALLED)/Contents/MacOS/iSmith' >/dev/null; then \
		echo "iSmith is running. Quit it, then run make install again."; exit 1; fi
	rm -rf '$(INSTALLED).installing'
	ditto '$(RELEASE_APP)' '$(INSTALLED).installing'
	rm -rf '$(INSTALLED)'
	mv '$(INSTALLED).installing' '$(INSTALLED)'
	@echo "Installed $(INSTALLED)"

project: $(PROJECT)

# Regenerated when project.yml changes or files are added to or removed from a source folder.
$(PROJECT): project.yml App AppTests
	xcodegen generate
	@touch $(PROJECT)

clean:
	rm -rf $(DERIVED) $(PROJECT) Packages/SignInSync/.build Packages/BraveImport/.build Packages/Blocking/.build Packages/Passwords/.build Packages/BrowserData/.build
