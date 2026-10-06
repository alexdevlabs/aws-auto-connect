APP := build/AWS AutoConnect.app
# /Applications when it's writable (admin accounts), like the app's own Homebrew copy.
DEST := $(shell test -w /Applications && echo /Applications || echo "$(HOME)/Applications")

.PHONY: app openvpn install run dev clean

app:
	scripts/bundle.sh

openvpn:
	scripts/build-openvpn.sh

install: app
	pkill -x AWSAutoConnect || true
	mkdir -p "$(DEST)"
	rm -rf "$(DEST)/AWS AutoConnect.app"
	cp -R "$(APP)" "$(DEST)/"
	@if [ "$(DEST)" = /Applications ]; then rm -rf "$(HOME)/Applications/AWS AutoConnect.app"; fi

run: install
	open "$(DEST)/AWS AutoConnect.app"

# A test build (orange menu bar mark, DEV label) run from build/; quits any running copy first.
# Its own build folder, so -DDEV never ends up in a release build.
dev:
	SWIFT_BUILD_FLAGS="-Xswiftc -DDEV --scratch-path .build/dev" scripts/bundle.sh
	pkill -x AWSAutoConnect || true
	open "$(APP)"

clean:
	rm -rf build .build
