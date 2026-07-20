# Xcode's bundled toolchain — immune to whatever swiftly/swift.org toolchain is on PATH.
SWIFT := /usr/bin/swift

build: ; $(SWIFT) build
test: ; $(SWIFT) test
release: ; $(SWIFT) build -c release
install: release ; .build/release/brain install

app: release
	rm -rf Brain.app
	mkdir -p Brain.app/Contents/MacOS
	cp .build/release/BrainApp Brain.app/Contents/MacOS/Brain
	cp Resources/Info.plist Brain.app/Contents/Info.plist
	codesign --force --sign - Brain.app

install-app: app
	rm -rf /Applications/Brain.app
	ditto Brain.app /Applications/Brain.app
	@echo "installed /Applications/Brain.app"

.PHONY: build test release install app install-app
