CC = clang
CFLAGS = -std=c17 -O2 -Wall -Wextra -Werror -fobjc-arc -mmacosx-version-min=13.0
# Set ARCHS="-arch arm64 -arch x86_64" for a universal build.
ARCHS ?=
FRAMEWORKS = -framework AppKit -framework CoreFoundation -framework CoreGraphics
APP = build/SoftClick.app
CORE = Sources/Haptics.m Sources/Haptics.h

.PHONY: app research hardware-test clean
app: build/SoftClick Resources/Info.plist Resources/AppIcon.icns THIRD-PARTY.md
	/bin/rm -rf "$(APP)"
	/bin/mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	/bin/cp build/SoftClick "$(APP)/Contents/MacOS/SoftClick"
	/bin/cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	/bin/cp Resources/AppIcon.icns THIRD-PARTY.md "$(APP)/Contents/Resources/"
	/usr/bin/codesign --force --sign - --timestamp=none --identifier io.github.vivogf.SoftClick "$(APP)"
	/usr/bin/codesign --verify --strict "$(APP)"

build/SoftClick: Sources/App.m $(CORE) Makefile
	/bin/mkdir -p build
	$(CC) $(CFLAGS) $(ARCHS) -o $@ Sources/App.m Sources/Haptics.m $(FRAMEWORKS) -framework ServiceManagement

research: build/soft-click
build/soft-click: research/soft-click.m research/native-click.c research/native-click.h $(CORE) Makefile
	/bin/mkdir -p build
	$(CC) $(CFLAGS) -o $@ research/soft-click.m research/native-click.c Sources/Haptics.m $(FRAMEWORKS)

# Touches the real trackpad: briefly mutes and restores stock haptics. Quit Soft Click first.
hardware-test: tests/hardware.m Sources/App.m $(CORE)
	/bin/mkdir -p build
	$(CC) $(CFLAGS) -o build/hardware-test tests/hardware.m $(FRAMEWORKS) -framework ServiceManagement
	tmp=$$(/usr/bin/mktemp -d) && build/hardware-test "$$tmp"; status=$$?; /bin/rm -rf "$$tmp"; exit $$status

clean:
	/bin/rm -rf build
