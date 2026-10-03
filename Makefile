# iSmith: build, test and run from the command line.
# The Xcode project is generated from project.yml (XcodeGen) and not committed.

PROJECT := iSmith.xcodeproj
DERIVED := build
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme iSmith -configuration Debug -derivedDataPath $(DERIVED)
APP := $(DERIVED)/Build/Products/Debug/iSmith.app

.PHONY: build test test-package test-app run project clean

build: project
	$(XCODEBUILD) build

# The packages (SignInSync: sync, vault and config; BraveImport: Brave profiles, bookmarks and
# passwords), then the app-hosted tests.
test: test-package test-app

test-package:
	cd Packages/SignInSync && swift test
	cd Packages/BraveImport && swift test

test-app: project
	$(XCODEBUILD) test

run: build
	open $(APP)

project: $(PROJECT)

# Regenerated when project.yml changes or files are added to or removed from a source folder.
$(PROJECT): project.yml App AppTests
	xcodegen generate
	@touch $(PROJECT)

clean:
	rm -rf $(DERIVED) $(PROJECT) Packages/SignInSync/.build Packages/BraveImport/.build
