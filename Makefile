APP := build/AWS AutoConnect.app
DEST := $(HOME)/Applications

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

run: install
	open "$(DEST)/AWS AutoConnect.app"

clean:
	rm -rf build .build
