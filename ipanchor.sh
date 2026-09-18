#!/bin/sh
# IPanchor 1.0 - pins the network config of a Linux or macOS server and puts it back on every boot.
# Windows servers: ipanchor.ps1
DIR=/etc/ipanchor   # per mode (local, virtual): current.MODE = applied now, saved.MODE = restored on every boot
BIN=/usr/local/sbin/ipanchor

# ================= shared =================
say() { printf '%s\n' "$@"; }
fail() { say "failed: $*"; return 1; }
ask() { printf '%s ' "$1"; read -r A || exit 1; }
yn() { ask "$1 y/n"; case $A in [yYsS]*) return 0 ;; esac; return 1; }
field() { ask "$(printf '%-8s [%s]' "$2" "$3")"; eval "$1=\${A:-\$3}"; }
line() { echo "$MODE $IF $IP $MASK $GW $DNS $DNS2"; }
final() { say "" "The configuration is set." "" "THX for using IPanchor 1.0!!"; exit 0; }

is_ip() { printf '%s' "$1" | grep -Eq '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'; }
ip2int() { set -- $(echo "$1" | tr . ' '); echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
int2ip() { echo "$(($1 >> 24 & 255)).$(($1 >> 16 & 255)).$(($1 >> 8 & 255)).$(($1 & 255))"; }
cidr2mask() { int2ip $(( (4294967295 << (32 - $1)) & 4294967295 )); }
mask2cidr() { n=0; while [ $n -le 32 ]; do [ "$(cidr2mask $n)" = "$1" ] && echo $n && return; n=$((n + 1)); done; return 1; }
netaddr() { echo "$(int2ip $(( $(ip2int "$IP") & $(ip2int "$MASK") )))/$P"; }

netconfig() {
  say "" "Net config:" "----------------------"
  IF=- IP= MASK=255.255.255.0 GW=- DNS=- DNS2=-
  if [ $MODE = local ]; then
    ifs=$(ifaces); def=$(default_iface)
    say "Interfaces: $ifs"
    field IF IFACE "${def:-${ifs%% *}}"
    case $IF in '' | *[!A-Za-z0-9_.:-]*) fail "bad interface '$IF'"; return 1 ;; esac
    iface_ok "$IF" || { fail "there is no interface $IF"; return 1; }
    GW= DNS2=8.8.8.8
    iface_now "$IF"   # current IP, MASK and GW become the defaults
  fi
  ask "Paste the saved config (Enter to type it):"
  if [ -n "$A" ]; then
    set -- $A
    IP=$1 MASK=${2:-$MASK}
    if [ $MODE = local ]; then [ "${3:--}" = - ] || GW=$3; DNS=${4:--}; [ "${5:--}" = - ] || DNS2=$5; fi
  else
    field IP IPv4 "$IP"
    field MASK MASK "$MASK"
    if [ $MODE = local ]; then field GW GATEWAY "$GW"; field DNS DNS "$GW"; field DNS2 DNS2 "$DNS2"; fi
  fi
  [ $MODE = local ] && [ "$DNS" = - ] && DNS=$GW   # blank DNS = the gateway
  for v in "$IP" "$GW" "$DNS" "$DNS2"; do [ "$v" = - ] || is_ip "$v" || { fail "bad IP '$v'"; return 1; }; done
  P=$(mask2cidr "$MASK") || { fail "bad MASK '$MASK'"; return 1; }
  say "----------------------" "IFACE    $IF" "IPv4     $IP" "MASK     $MASK" "GATEWAY  $GW" "DNS      $DNS" "DNS2     $DNS2"
  ask "  > Save    > Cancel   [s/c]"
  case $A in [cC]*) return 1 ;; esac
}

apply() {  # bring $MODE up; the other mode is not touched
  mkdir -p $DIR
  c=$DIR/current.$MODE   # line: MODE IF IP MASK GW DNS DNS2
  if [ -f $c ]; then
    read -r om oif x < $c   # a new local config on the same interface replaces the old one in place
    [ "$om $oif" = "local $IF" ] || [ "$(cat $c)" = "$(line)" ] || undo $MODE
  fi
  line > $c
  up_$MODE
}

undo() {  # $1 = mode: take back what it has applied (local goes back to DHCP)
  [ -f $DIR/current.$1 ] || return 0
  read -r om oif x < $DIR/current.$1; rm -f $DIR/current.$1
  if [ $1 = virtual ]; then undo_virtual; else undo_local "$oif"; fi
  return 0
}

restore() {  # $1 = mode: back to its saved config, or take it away when nothing is saved
  if [ -f $DIR/saved.$1 ]; then read -r MODE IF IP MASK GW DNS DNS2 < $DIR/saved.$1; P=$(mask2cidr "$MASK"); apply
  else undo $1; fi
}

cleanup() {  # nothing applied or saved in any mode: the boot hook is not needed any more
  for f in $DIR/current.* $DIR/saved.*; do [ -e "$f" ] && return 0; done
  boot_off; rm -rf $DIR
}

taken() {  # another device already answers on $IP (ping, or ARP when it blocks ping)
  mine "$IP" && return 1
  forget "$IP"
  pong "$IP" || seen "$IP"
}

verify() {  # local: the gateway must answer (ping, or at least ARP) within 15 s
  [ $MODE = virtual ] && return 0
  command -v ping >/dev/null 2>&1 || return 0
  forget "$GW"; t=0
  while [ $t -lt 15 ]; do pong "$GW" || seen "$GW" && return 0; sleep 1; t=$((t + 1)); done
  return 1
}

save_desktop() {
  u=${SUDO_USER:-root}; case $u in *[!A-Za-z0-9._-]*) u=root ;; esac
  h=$(eval echo "~$u"); d=$h/Desktop; [ -d "$d" ] || d=$h
  say "IPanchor config - paste this line in \"Net config\":" "$IP $MASK $GW $DNS $DNS2" > "$d/ipanchor-config.txt" &&
    { [ $u = root ] || chown "$u" "$d/ipanchor-config.txt"; say "Saved: $d/ipanchor-config.txt"; }
}

# ================= Linux =================
BR=ipanchor0   # bridge of "set virtual"
SYSNAME=$(awk -F= '$1 == "PRETTY_NAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release 2>/dev/null)

ifaces() { ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2) } $2 != "lo" { printf "%s ", $2 }'; }
default_iface() { ip route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'; }
iface_ok() { ip link show "$1" >/dev/null 2>&1; }
iface_now() {
  c=$(ip -o -4 addr show dev "$1" scope global | awk '{ print $4; exit }')
  [ -n "$c" ] && IP=${c%/*} && MASK=$(cidr2mask "${c#*/}")
  GW=$(ip route show default dev "$1" | awk '{ print $3; exit }')
}
mine() { ip -o addr show | grep -q " $1/"; }
pong() { ping -c 1 -W 1 "$1" >/dev/null 2>&1; }
seen() { ip neigh show "$1" | grep -q lladdr; }
forget() { ip neigh flush to "$1" 2>/dev/null; }

backend() {  # who owns interface $1: NetworkManager, systemd-networkd (Ubuntu Server/netplan), ifupdown (Debian/Alpine) or nobody
  if s=$(nmcli -g GENERAL.STATE device show "$1" 2>/dev/null) && [ -n "$s" ] && [ "${s#*unmanaged}" = "$s" ]; then echo nm
  elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then echo networkd
  elif [ -f /etc/network/interfaces ]; then echo ifupdown
  else echo none; fi
}

ip_up() {  # runtime config with plain iproute2, for when no network manager rewrites it
  pkill -f "dhc.* $IF" 2>/dev/null   # a running DHCP client would take the interface back
  ip link set "$IF" up
  ip addr flush dev "$IF" scope global
  ip addr add "$IP/$P" dev "$IF" && ip route replace default via "$GW" dev "$IF" || return 1
  resolvectl dns "$IF" "$DNS" "$DNS2" 2>/dev/null ||
    { rm -f /etc/resolv.conf; printf 'nameserver %s\n' "$DNS" "$DNS2" > /etc/resolv.conf; }
}

dhcp_now() {  # $1 = interface: drop static addresses and ask for a DHCP lease in the background
  ip addr flush dev "$1" scope global
  if command -v dhclient >/dev/null 2>&1; then dhclient "$1"
  elif command -v udhcpc >/dev/null 2>&1; then udhcpc -b -i "$1"
  elif command -v dhcpcd >/dev/null 2>&1; then dhcpcd "$1"
  fi >/dev/null 2>&1 &
}

up_local() {
  case $(backend "$IF") in
  nm)
    src=$(nmcli -g GENERAL.CONNECTION device show "$IF")
    if [ "$src" != ipanchor ]; then   # clone the active profile so vlan/bond/wifi settings survive
      nmcli con delete ipanchor >/dev/null 2>&1
      if [ -n "$src" ]; then nmcli con clone "$src" ipanchor; else nmcli con add type ethernet con-name ipanchor ifname "$IF"; fi >/dev/null || return 1
    fi
    nmcli con mod ipanchor connection.interface-name "$IF" connection.autoconnect yes connection.autoconnect-priority 100 \
      ipv4.method manual ipv4.addresses "$IP/$P" ipv4.gateway "$GW" ipv4.dns "$DNS,$DNS2" ipv4.ignore-auto-dns yes &&
      nmcli con up ipanchor >/dev/null ;;
  networkd)   # 09- sorts before netplan's 10-netplan-*.network and networkd uses the first file that matches
    printf '[Match]\nName=%s\n\n[Network]\nAddress=%s/%s\nGateway=%s\nDNS=%s\nDNS=%s\n' "$IF" "$IP" "$P" "$GW" "$DNS" "$DNS2" \
      > /etc/systemd/network/09-ipanchor.network && ip addr flush dev "$IF" scope global && systemctl restart systemd-networkd ;;
  ifupdown)
    [ -f $DIR/interfaces.bak ] || cp /etc/network/interfaces $DIR/interfaces.bak
    { awk -v i="$IF" '$1 == "iface" { skip = ($2 == i) } $1 ~ /^(auto|allow-|source|mapping)/ { skip = 0 } !skip' $DIR/interfaces.bak
      printf '\niface %s inet static\n    address %s\n    netmask %s\n    gateway %s\n    dns-nameservers %s %s\n' "$IF" "$IP" "$MASK" "$GW" "$DNS" "$DNS2"
    } > /etc/network/interfaces && ip_up ;;
  *) ip_up ;;
  esac
}

undo_local() {  # $1 = interface, back to DHCP
  case $(backend "$1") in
  nm) nmcli con delete ipanchor >/dev/null 2>&1; nmcli device connect "$1" >/dev/null 2>&1 & ;;
  networkd) rm -f /etc/systemd/network/09-ipanchor.network; ip addr flush dev "$1" scope global; systemctl restart systemd-networkd ;;
  ifupdown) mv $DIR/interfaces.bak /etc/network/interfaces 2>/dev/null; dhcp_now "$1" ;;
  *) dhcp_now "$1" ;;
  esac
}

nat_down() {
  nft delete table ip ipanchor 2>/dev/null
  iptables -t nat -D POSTROUTING -j IPANCHOR 2>/dev/null
  iptables -t nat -F IPANCHOR 2>/dev/null; iptables -t nat -X IPANCHOR 2>/dev/null
  return 0
}

up_virtual() {  # bridge with the fixed IP + NAT out through whatever uplink the server has
  ip link add $BR type bridge 2>/dev/null
  ip link set $BR up && ip addr flush dev $BR && ip addr add "$IP/$P" dev $BR || return 1
  echo 1 > /proc/sys/net/ipv4/ip_forward
  nat_down
  nft "add table ip ipanchor; add chain ip ipanchor post { type nat hook postrouting priority 100; }; add rule ip ipanchor post ip saddr $(netaddr) oifname != $BR masquerade" 2>/dev/null ||
    { iptables -t nat -N IPANCHOR && iptables -t nat -A IPANCHOR -s "$(netaddr)" ! -o $BR -j MASQUERADE && iptables -t nat -A POSTROUTING -j IPANCHOR; }
}

undo_virtual() { nat_down; ip link del $BR 2>/dev/null; return 0; }

boot_on() {  # run "ipanchor boot" on every start
  mkdir -p "${BIN%/*}"; cp "$0" $BIN 2>/dev/null; chmod 755 $BIN
  if [ -d /run/systemd/system ]; then
    printf '[Unit]\nDescription=IPanchor: restore the pinned network config\nWants=network-online.target\nAfter=network-online.target NetworkManager.service systemd-networkd.service\n\n[Service]\nType=oneshot\nExecStart=%s boot\n\n[Install]\nWantedBy=multi-user.target\n' $BIN \
      > /etc/systemd/system/ipanchor.service
    systemctl daemon-reload && systemctl enable --quiet ipanchor.service
  elif [ -d /etc/local.d ]; then   # OpenRC
    printf '#!/bin/sh\n%s boot\n' $BIN > /etc/local.d/ipanchor.start; chmod 755 /etc/local.d/ipanchor.start
    rc-update add local default >/dev/null 2>&1
  else
    [ -f /etc/rc.local ] || echo '#!/bin/sh' > /etc/rc.local
    sed -i '/^exit 0/d' /etc/rc.local; grep -q "$BIN boot" /etc/rc.local || echo "$BIN boot" >> /etc/rc.local; chmod 755 /etc/rc.local
  fi
}

boot_off() {
  systemctl disable --quiet ipanchor.service 2>/dev/null
  rm -f /etc/systemd/system/ipanchor.service /etc/local.d/ipanchor.start
  [ -f /etc/rc.local ] && sed -i "\\#$BIN boot#d" /etc/rc.local
  return 0
}

certs() {  # refresh the root CA bundle with the distro package manager
  for pm in apt-get dnf yum zypper apk pacman; do command -v $pm >/dev/null 2>&1 && break; pm=; done
  case $pm in
  apt-get) apt-get -q update; apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates && update-ca-certificates --fresh ;;
  dnf | yum) $pm install -y ca-certificates && $pm update -y ca-certificates && update-ca-trust ;;
  zypper) zypper -n install ca-certificates && zypper -n update ca-certificates && update-ca-certificates ;;
  apk) apk add --upgrade ca-certificates && update-ca-certificates ;;
  pacman) pacman -Sy --noconfirm ca-certificates ;;
  *) false ;;
  esac || { fail "ca-certificates could not be installed${pm:+ with $pm}"; return 1; }
  for b in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do
    [ -f $b ] && say "$(grep -c 'BEGIN CERTIFICATE' $b) root certificates installed ($b)" && return 0
  done
}

# ================= macOS: same functions with macOS tools =================
if [ "$(uname -s)" = Darwin ]; then
BR=bridge77
SYSNAME="macOS $(sw_vers -productVersion)"
PLIST=/Library/LaunchDaemons/com.ipanchor.boot.plist

ifaces() { networksetup -listallhardwareports | awk '/^Device: / { printf "%s ", $2 }'; }
default_iface() { route -n get default 2>/dev/null | awk '/interface:/ { print $2 }'; }
service() {  # network service name ("Ethernet", "Wi-Fi"...) of device $1
  networksetup -listnetworkserviceorder | awk -v d="$1)" '
    /^\([0-9*]+\) / { n = $0; sub(/^\([0-9*]+\) /, "", n); sub(/ \(Hardware Port:.*/, "", n) }
    $NF == d { print n; exit }'
}
iface_ok() { [ -n "$(service "$1")" ]; }
iface_now() {
  i=$(networksetup -getinfo "$(service "$1")")
  c=$(say "$i" | awk -F': ' '/^IP address: [0-9]/ { print $2 }'); [ -n "$c" ] && IP=$c
  c=$(say "$i" | awk -F': ' '/^Subnet mask: [0-9]/ { print $2 }'); [ -n "$c" ] && MASK=$c
  GW=$(say "$i" | awk -F': ' '/^Router: [0-9]/ { print $2 }')
}
mine() { ifconfig | grep -q "inet $1 "; }
pong() { ping -c 1 -t 1 "$1" >/dev/null 2>&1; }
seen() { arp -n "$1" 2>/dev/null | grep -q ' at [0-9a-f]'; }
forget() { arp -d "$1" >/dev/null 2>&1; }

up_local() { s=$(service "$IF"); networksetup -setmanual "$s" "$IP" "$MASK" "$GW" && networksetup -setdnsservers "$s" "$DNS" "$DNS2"; }
undo_local() { s=$(service "$1"); networksetup -setdhcp "$s"; networksetup -setdnsservers "$s" Empty; }

up_virtual() {  # bridge with the fixed IP + pf NAT out through any hardware port
  ifconfig $BR create 2>/dev/null
  ifconfig $BR inet "$IP" netmask "$MASK" up || return 1
  sysctl -w net.inet.ip.forwarding=1 >/dev/null
  networksetup -listallhardwareports | awk -v n="$(netaddr)" '/^Device: / { printf "nat on %s inet from %s to any -> (%s)\n", $2, n, $2 }' |
    pfctl -a com.apple/ipanchor -f - 2>/dev/null || return 1
  pfctl -e 2>/dev/null; return 0
}

undo_virtual() { pfctl -a com.apple/ipanchor -F all 2>/dev/null; ifconfig $BR destroy 2>/dev/null; return 0; }

boot_on() {  # launchd runs "ipanchor boot" on every start (it is not loaded now: that would run it now)
  mkdir -p "${BIN%/*}"; cp "$0" $BIN 2>/dev/null; chmod 755 $BIN
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n  <key>Label</key><string>com.ipanchor.boot</string>\n  <key>ProgramArguments</key><array><string>%s</string><string>boot</string></array>\n  <key>RunAtLoad</key><true/>\n</dict></plist>\n' $BIN > $PLIST
  chown root:wheel $PLIST; chmod 644 $PLIST
}

boot_off() { rm -f $PLIST; launchctl bootout system/com.ipanchor.boot 2>/dev/null; return 0; }

certs() {  # macOS keeps its root certificates inside the system and updates them with Software Update
  n=$(security find-certificate -a /System/Library/Keychains/SystemRootCertificates.keychain 2>/dev/null | grep -c '^keychain:')
  [ "$n" -gt 0 ] || { fail "could not read the system root certificates"; return 1; }
  say "$n root certificates installed (macOS updates them with Software Update)"
}
fi

# ================= main =================
if [ "$1" = selftest ]; then
  [ "$(cidr2mask 24)" = 255.255.255.0 ] && [ "$(cidr2mask 0)" = 0.0.0.0 ] && [ "$(mask2cidr 255.255.255.255)" = 32 ] &&
    [ "$(mask2cidr 255.255.240.0)" = 20 ] && ! mask2cidr 255.0.255.0 >/dev/null &&
    is_ip 10.0.0.1 && ! is_ip 256.1.1.1 && ! is_ip 1.2.3 && ! is_ip 01.2.3.4 &&
    IP=10.0.50.77 MASK=255.255.255.0 P=24 && [ "$(netaddr)" = 10.0.50.0/24 ] && say "selftest ok" && exit 0
  say "selftest FAILED"; exit 1
fi
command -v ip >/dev/null 2>&1 || command -v networksetup >/dev/null 2>&1 || { say "IPanchor runs on Linux and macOS (Windows: ipanchor.ps1)"; exit 1; }
[ -f "$0" ] || { say "Download ipanchor.sh and run that file (the boot service needs it): sh ipanchor.sh"; exit 1; }
if [ "$(id -u)" != 0 ]; then   # ask for root and rerun there
  command -v sudo >/dev/null 2>&1 || { say "Run it as root: su -c 'sh $0'"; exit 1; }
  exec sudo sh "$0" "$@"
fi
for f in current saved; do [ -f $DIR/$f ] && read -r m x < $DIR/$f && mv $DIR/$f $DIR/$f.$m; done   # state of the single-mode version
[ "$1" = boot ] && { restore virtual; restore local; cleanup; exit 0; }

while :; do
  say "" " ----------------------" "  Welcome to IPanchor" " \\--------------------/" "  ${SYSNAME:-$(uname -s)}" "" \
    "  1 > set on virtual" "  2 > set on local network" "  3 > reset on virtual" "  4 > reset on local network" "  5 > reset all" "  6 > quit" ""
  ask ">"
  case $A in
  1) MODE=virtual ;;
  2) MODE=local ;;
  3 | 4 | 5)
    case $A in 3) ms=virtual ;; 4) ms=local ;; *) ms="virtual local" ;; esac
    for m in $ms; do
      [ -f $DIR/current.$m ] || say "Nothing applied on $m."
      undo $m; rm -f $DIR/saved.$m
    done
    cleanup; final ;;
  6 | q | Q) exit 0 ;;
  *) continue ;;
  esac
  netconfig || continue
  yn "Disable one time only? (y = keep it after reboot, n = only until reboot)" && keep=1 || keep=
  if taken; then fail "$IP is already taken by another device"; continue; fi
  [ $MODE = local ] && say "If you are on SSH through $IF you will be disconnected: log in again at $IP"
  say "Applying..."
  trap '' HUP   # an SSH drop must not kill us halfway
  if ! apply; then fail "the config could not be applied, restoring the previous one"; restore $MODE; cleanup; continue; fi
  if ! verify; then fail "gateway $GW does not answer from $IP/$P, restoring the previous one"; restore $MODE; cleanup; continue; fi
  [ -n "$keep" ] && cp $DIR/current.$MODE $DIR/saved.$MODE
  boot_on
  yn "Save config on desktop" && save_desktop
  yn "Download all the certifications" && certs
  final
done
