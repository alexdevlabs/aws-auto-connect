#!/bin/bash
# Installs the root-owned VPN helper. The app runs this through the macOS admin prompt:
#   install-helper.sh <resources-dir> <profile.ovpn> <profile-name> <user>
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

SRC=$1 PROFILE=$2 NAME=$3 USERNAME=$4
DIR=/usr/local/libexec/aws-autoconnect
ETC=/usr/local/etc/aws-autoconnect
SUDOERS=/etc/sudoers.d/aws-autoconnect

die() { echo "$*" >&2; exit 1; }
[[ $USERNAME =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "bad user name"
[ -f "$PROFILE" ] || die "profile not found: $PROFILE"

read -r host port rproto < <(awk '$1 == "remote" { print $2, $3, $4; exit }' "$PROFILE")
proto=${rproto:-$(awk '$1 == "proto" { print $2; exit }' "$PROFILE")}
port=${port:-443}
case "${proto:-udp}" in udp*) proto=udp ;; tcp*) proto=tcp ;; *) die "unsupported proto: $proto" ;; esac
[[ $host =~ ^[A-Za-z0-9.-]+$ ]] || die "no usable 'remote' in profile"
[[ $port =~ ^[0-9]+$ ]] || die "bad port in profile"

install -d -o root -g wheel -m 755 "$DIR" "$ETC"
for f in openvpn dns-relay vpn-helper dns.sh; do
  install -o root -g wheel -m 755 "$SRC/$f" "$DIR/$f"
done
rm -f "$DIR/dns-up.sh" "$DIR/dns-down.sh"  # replaced by dns.sh

# Keep only plain client directives and inline certificates. Anything that can
# run code (up, down, plugin, script-security, ...) is dropped, as are remote and
# auth lines, which the app supplies itself.
awk '
  inblock { print; if ($0 ~ "^</" tag ">") inblock = 0; next }
  match($0, /^<(ca|cert|key|tls-auth|tls-crypt|extra-certs)>/) {
    tag = substr($0, 2, RLENGTH - 2); inblock = 1; print; next
  }
  $1 ~ /^(client|dev|dev-type|proto|nobind|persist-key|persist-tun|remote-cert-tls|cipher|data-ciphers|data-ciphers-fallback|auth|reneg-sec|resolv-retry|tls-client|tls-version-min|key-direction|verify-x509-name|tun-mtu|mssfix|verb)$/ { print }
' "$PROFILE" > "$ETC/profile.ovpn"
echo "$host $port $proto" > "$ETC/endpoint"
printf '%s\n' "$NAME" > "$ETC/profile.name"
chown root:wheel "$ETC"/*
chmod 644 "$ETC"/*

tmp=$(mktemp)
echo "$USERNAME ALL=(root) NOPASSWD: $DIR/vpn-helper" > "$tmp"
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers check failed"; }
install -o root -g wheel -m 440 "$tmp" "$SUDOERS"
rm -f "$tmp"
echo "installed"
