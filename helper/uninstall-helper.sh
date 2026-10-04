#!/bin/bash
# Removes everything install-helper.sh put in place.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
DIR=/usr/local/libexec/aws-autoconnect
[ -x "$DIR/vpn-helper" ] && SUDO_UID=0 "$DIR/vpn-helper" disconnect
rm -rf "$DIR" /usr/local/etc/aws-autoconnect /var/run/aws-autoconnect
rm -f /etc/sudoers.d/aws-autoconnect /var/log/aws-autoconnect.log /var/log/aws-autoconnect-dns.log
echo "uninstalled"
