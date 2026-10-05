APP := build/AWS AutoConnect.app
# /Applications when it's writable (admin accounts), like the app's own Homebrew copy.
DEST := $(shell test -w /Applications && echo /Applications || echo "$(HOME)/Applications")

.PHONY: app openvpn install run clean

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

clean:
	rm -rf build .build
