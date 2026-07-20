# Xcode's bundled toolchain — immune to whatever swiftly/swift.org toolchain is on PATH.
SWIFT := /usr/bin/swift

build: ; $(SWIFT) build
test: ; $(SWIFT) test
release: ; $(SWIFT) build -c release
install: release ; .build/release/brain install

icon:
	$(SWIFT) Resources/Icon/render-layers.swift Resources/Icon/Brain.icon/Assets
	rm -rf .build/icon
	mkdir -p .build/icon
	xcrun actool Resources/Icon/Brain.icon --compile .build/icon --platform macosx --minimum-deployment-target 26.0 --app-icon Brain --output-partial-info-plist .build/icon/partial.plist > .build/icon/actool.log

app: release icon
	rm -rf Brain.app
	mkdir -p Brain.app/Contents/MacOS Brain.app/Contents/Resources
	cp .build/release/BrainApp Brain.app/Contents/MacOS/Brain
	cp Resources/Info.plist Brain.app/Contents/Info.plist
	cp .build/icon/Assets.car .build/icon/Brain.icns Brain.app/Contents/Resources/
	codesign --force --sign - Brain.app

install-app: app
	rm -rf /Applications/Brain.app
	ditto Brain.app /Applications/Brain.app
	@echo "installed /Applications/Brain.app"

.PHONY: build test release install icon app install-app
