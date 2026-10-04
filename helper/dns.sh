#!/bin/bash
# DNS while the tunnel is up. openvpn runs `dns.sh up` and `dns.sh down` as root; `up` starts `dns.sh watch`.
#
# up:    points the primary network service's DNS at dns-relay on 127.0.0.1 (Sources/DNSRelay), which
#        forwards to the VPN's resolver and to the network's own. If the relay is missing or doesn't
#        start, DNS points straight at the VPN's resolver, like the AWS client.
# watch: restarts the relay if it exits, re-applies DNS when DHCP or a network switch overwrites it
#        (the servers it brought become the relay's upstream), and runs `down` if openvpn dies.
# down:  stops both and restores the DNS settings saved by `up`.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
DIR=/usr/local/libexec/aws-autoconnect
RUN=/var/run/aws-autoconnect
# Not openvpn's log: openvpn writes that at its own offset and overwrites what others append.
LOG=/var/log/aws-autoconnect-dns.log
CONF=$RUN/dns-relay.conf
# Both the DHCP (State:) and manual (Setup:) keys are set, like Tunnelblick / the AWS client. With only
# State:, macOS ties the servers to the Wi-Fi interface (scutil --dns shows `if_index (en0)`, Scoped) and
# may send lookups out of Wi-Fi instead of the tunnel.
SAVED=State:/Network/AWSAutoConnect/SavedDNS
SAVED_SETUP=State:/Network/AWSAutoConnect/SavedSetupDNS

primary_service() { echo "show State:/Network/Global/IPv4" | scutil | awk '/PrimaryService/ {print $3}'; }

# ServerAddresses of a dynamic store key, one per line.
servers_of() {
  echo "show $1" | scutil | awk '/ServerAddresses/ {on = 1; next} on && /}/ {on = 0} on {print $3}'
}

exists() { ! echo "show $1" | scutil | grep -q "No such key"; }

flush() { dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true; }

# set_dns <service> <server>...: keeps the VPN's search domains, if it pushed any.
set_dns() {
  local psid=$1; shift
  local search=""
  [ -s "$RUN/dns-search" ] && search="d.add SearchDomains * $(cat "$RUN/dns-search")"
  scutil <<EOF
d.init
d.add ServerAddresses * $*
$search
set State:/Network/Service/$psid/DNS
set Setup:/Network/Service/$psid/DNS
EOF
  flush
}

# save_dns <service> [state-only]: saves its DNS keys for down; a missing key is saved as missing.
# state-only is for DHCP changes mid-session, when Setup: still holds ours.
save_dns() {
  local key saved pairs=("State:/Network/Service/$1/DNS $SAVED")
  [ "${2:-}" = state-only ] || pairs+=("Setup:/Network/Service/$1/DNS $SAVED_SETUP")
  for pair in "${pairs[@]}"; do
    read -r key saved <<< "$pair"
    if exists "$key"; then
      printf 'd.init\nget %s\nset %s\n' "$key" "$saved" | scutil
    else
      printf 'remove %s\n' "$saved" | scutil
    fi
  done
  echo "$1" > "$RUN/primary-service"
}

restore_dns() {
  local psid
  psid=$(cat "$RUN/primary-service" 2>/dev/null) || return 0
  local key saved
  for pair in "State:/Network/Service/$psid/DNS $SAVED" "Setup:/Network/Service/$psid/DNS $SAVED_SETUP"; do
    read -r key saved <<< "$pair"
    if exists "$saved"; then
      printf 'd.init\nget %s\nset %s\nremove %s\n' "$saved" "$key" "$saved" | scutil
    else
      printf 'remove %s\n' "$key" | scutil
    fi
  done
  rm -f "$RUN/primary-service"
  flush
}

# write_conf <upstream>...: the relay reloads it when it changes.
write_conf() {
  {
    sed 's/^/vpn /' "$RUN/dns-vpn"
    for u in "$@"; do echo "upstream $u"; done
    cat "$RUN/dns-routes"
  } > "$CONF.tmp" && mv -f "$CONF.tmp" "$CONF"
}

# Servers other than ours (the relay and the VPN's), i.e. the network's own.
network_servers() { grep -v '^127\.' | grep -vxF -f "$RUN/dns-vpn"; }

# What DNS should point at right now.
wanted() { if [ -f "$RUN/dns-relay.ready" ]; then echo 127.0.0.1; else cat "$RUN/dns-vpn"; fi; }

case "${1:-}" in
  up)
    rm -f "$RUN/auth"
    servers=() domains=() routes=()
    i=1
    while :; do
      var="foreign_option_$i"; opt="${!var:-}"
      [ -z "$opt" ] && break
      case "$opt" in
        "dhcp-option DNS "*) servers+=("${opt#dhcp-option DNS }") ;;
        "dhcp-option DOMAIN "*) domains+=("${opt#dhcp-option DOMAIN }") ;;
        "dhcp-option DOMAIN-SEARCH "*) domains+=("${opt#dhcp-option DOMAIN-SEARCH }") ;;
      esac
      i=$((i + 1))
    done
    i=1
    while :; do
      net="route_network_$i" mask="route_netmask_$i"
      [ -z "${!net:-}" ] && break
      routes+=("route ${!net} ${!mask}")
      i=$((i + 1))
    done
    [ ${#servers[@]} -eq 0 ] && exit 0
    psid=$(primary_service)
    [ -z "$psid" ] && exit 0

    printf '%s\n' "${servers[@]}" > "$RUN/dns-vpn"
    if [ ${#domains[@]} -gt 0 ]; then echo "${domains[*]}" > "$RUN/dns-search"; else : > "$RUN/dns-search"; fi
    if [ ${#routes[@]} -gt 0 ]; then printf '%s\n' "${routes[@]}" > "$RUN/dns-routes"; else : > "$RUN/dns-routes"; fi

    save_dns "$psid"
    upstream=$(servers_of "$SAVED" | network_servers)
    [ -z "$upstream" ] && upstream=$(servers_of "Setup:/Network/Service/$psid/DNS" | network_servers)
    # shellcheck disable=SC2086
    write_conf $upstream

    rm -f "$RUN/dns-relay.ready"
    : > "$LOG"; chmod 644 "$LOG"
    if [ -x "$DIR/dns-relay" ]; then
      # Not nohup: there's no terminal here, and nothing sends SIGHUP to a non-interactive shell's jobs.
      "$0" watch </dev/null >>"$LOG" 2>&1 &
      for _ in $(seq 30); do [ -f "$RUN/dns-relay.ready" ] && break; sleep 0.1; done
    fi
    if [ -f "$RUN/dns-relay.ready" ]; then echo "$(date +%T) dns.sh: relay up"; else echo "$(date +%T) dns.sh: relay not up, using the VPN's DNS directly"; fi >> "$LOG"
    # shellcheck disable=SC2046
    set_dns "$psid" $(wanted)
    ;;

  watch)
    ovpid=$(cat "$RUN/openvpn.pid" 2>/dev/null)
    echo "$(date +%T) dns.sh: watching (openvpn $ovpid)"
    ( while [ -f "$CONF" ]; do
        "$DIR/dns-relay" "$RUN"
        rm -f "$RUN/dns-relay.ready"
        [ -f "$CONF" ] && sleep 1
      done ) &
    while sleep 2 && [ -f "$CONF" ]; do
      if [ -n "$ovpid" ] && ! kill -0 "$ovpid" 2>/dev/null; then
        echo "dns.sh: openvpn is gone, restoring DNS"
        "$0" down
        exit 0
      fi
      psid=$(cat "$RUN/primary-service" 2>/dev/null)
      now=$(primary_service)
      if [ -n "$now" ] && [ "$now" != "$psid" ]; then
        echo "dns.sh: primary network service changed"
        restore_dns
        save_dns "$now"
        psid=$now
        # shellcheck disable=SC2046
        write_conf $(servers_of "$SAVED" | network_servers)
      fi
      [ -z "$psid" ] && continue
      want=$(wanted | head -1)
      current=$(servers_of "State:/Network/Service/$psid/DNS")
      if [ "$(echo "$current" | head -1)" != "$want" ]; then
        # DHCP renewed or the network changed under us: its servers become the relay's upstream.
        theirs=$(echo "$current" | network_servers)
        if [ -n "$theirs" ]; then
          save_dns "$psid" state-only
          # shellcheck disable=SC2086
          write_conf $theirs
        fi
        # shellcheck disable=SC2046
        set_dns "$psid" $(wanted)
      fi
    done
    ;;

  down)
    rm -f "$CONF"
    [ -f "$RUN/dns-relay.ready" ] && kill "$(cat "$RUN/dns-relay.ready")" 2>/dev/null
    pkill -x dns-relay 2>/dev/null
    restore_dns
    rm -f "$RUN/dns-vpn" "$RUN/dns-search" "$RUN/dns-routes" "$RUN/dns-relay.ready"
    ;;
esac
exit 0
