# Foundation Models' @Generable macro ships only with Xcode's toolchain;
# the swiftly/swift.org toolchain on PATH cannot build this package.
SWIFT := /usr/bin/swift

build: ; $(SWIFT) build
test: ; $(SWIFT) test
release: ; $(SWIFT) build -c release
install: release ; .build/release/brain install
.PHONY: build test release install
