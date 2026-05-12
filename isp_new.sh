#!/usr/bin/env bash
set -euo pipefail

VMID_DEF=105
FQDN_DEF="isp.au-team.irpo"
TZ_DEF="Asia/Yekaterinburg"

WAN_DEF=net0
HQ_DEF=net1
BR_DEF=net2

HQ_IP_DEF="172.16.50.1/28"
BR_IP_DEF="172.16.60.1/28"

MP_DEF="/mnt/isp"

log(){ echo "[ISP-OFFLINE] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "нет команды $1"; }

ask(){
  local t="$1" d="$2" v
  read -r -p "$t [$d]: " v
  echo "${v:-$d}"
}

yn(){
  local t="$1" d="$2" v
  while true; do
    read -r -p "$t [$d]: " v
    v="${v:-$d}"
    case "$v" in
      y|Y|yes|YES) echo y; return ;;
      n|N|no|NO) echo n; return ;;
      *) echo "Введите y/n" ;;
    esac
  done
}

q(){ printf "%q" "$1"; }

cidr_ok(){
  python3 - "$1" <<'PY'
import ipaddress, sys
ipaddress.ip_interface(sys.argv[1])
PY
}

cidr_priv(){
  python3 - "$1" <<'PY'
import ipaddress, sys
assert ipaddress.ip_interface(sys.argv[1]).ip.is_private
PY
}

cidr_net(){
  python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

mac_of(){
  qm config "$1" \
    | awk -v s="$2:" '$1==s{print}' \
    | sed -nE 's/.*(virtio|e1000|rtl8139|vmxnet3)=([0-9A-Fa-f:]+).*/\2/p'
}

disk_of(){
  local line vol d
  line="$(qm config "$1" | awk -F': ' '/^(scsi0|virtio0|sata0|ide0):/{print $2; exit}')"
  [ -n "$line" ] || die "диск ВМ не найден"

  vol="${line%%,*}"

  case "$vol" in
    local-lvm:*)
      d="${vol#local-lvm:}"
      lvchange -a y "pve/$d" >/dev/null 2>&1 || true
      sleep 1
      echo "/dev/pve/$d"
      ;;
    /dev/*)
      echo "$vol"
      ;;
    *)
      die "неподдерживаемый диск $vol"
      ;;
  esac
}

stop_vm(){
  local s i
  s="$(qm status "$1" | awk '{print $2}')"

  if [ "$s" = stopped ]; then
    log "VM $1 уже остановлена"
    return
  fi

  log "Останавливаю VM $1"
  qm shutdown "$1" || true

  for i in $(seq 1 45); do
    s="$(qm status "$1" | awk '{print $2}')"
    [ "$s" = stopped ] && return
    sleep 2
  done

  log "Принудительная остановка VM $1"
  qm stop "$1"
}

mount_root(){
  local disk="$1" mp="$2" loop p src

  mkdir -p "$mp"

  if mountpoint -q "$mp"; then
    log "$mp уже смонтирован, использую его"
    src="$(findmnt -no SOURCE "$mp" || true)"

    if [[ "$src" =~ ^(/dev/loop[0-9]+)p[0-9]+$ ]]; then
      echo "${BASH_REMATCH[1]}"
    else
      echo EXISTING
    fi

    return
  fi

  loop="$(losetup -Pf --show "$disk")"
  sleep 1

  for p in "${loop}p2" "${loop}p1" "${loop}p3"; do
    [ -b "$p" ] || continue

    if mount "$p" "$mp" 2>/dev/null; then
      if [ -d "$mp/etc" ] && [ -d "$mp/usr" ]; then
        echo "$loop"
        return
      fi

      umount "$mp" || true
    fi
  done

  losetup -d "$loop" 2>/dev/null || true
  die "root-раздел не найден"
}

cleanup(){
  sync || true

  if mountpoint -q "$MP"; then
    umount "$MP" || true
  fi

  if [ "${LOOP:-}" != EXISTING ] && [ -n "${LOOP:-}" ]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}

write_files(){
  local r="$1"
  local short="${FQDN%%.*}"

  log "Пишу настройки в $r"

  echo "$FQDN" > "$r/etc/hostname"
  echo "$FQDN" > "$r/etc/HOSTNAME" 2>/dev/null || true

  touch "$r/etc/hosts"
  grep -vE "[[:space:]](${FQDN}|${short})([[:space:]]|$)" "$r/etc/hosts" > "$r/etc/hosts.tmp" || true
  cat "$r/etc/hosts.tmp" > "$r/etc/hosts"
  rm -f "$r/etc/hosts.tmp"
  echo "127.0.1.1 $FQDN $short" >> "$r/etc/hosts"

  if [ -f "$r/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" "$r/etc/localtime"
  fi

  echo "$TZ" > "$r/etc/timezone" 2>/dev/null || true

  mkdir -p "$r/usr/local/sbin"
  mkdir -p "$r/etc/systemd/system/multi-user.target.wants"
  mkdir -p "$r/etc/net"
  mkdir -p "$r/etc/sysctl.d"

  cat > "$r/usr/local/sbin/isp-apply.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

FQDN=$(q "$FQDN")
TZ=$(q "$TZ")

WAN_MAC=$(q "$WAN_MAC")
HQ_MAC=$(q "$HQ_MAC")
BR_MAC=$(q "$BR_MAC")

HQ_IP=$(q "$HQ_IP")
BR_IP=$(q "$BR_IP")

NAT=$(q "$NAT")
NAT_NETS=$(q "$NAT_NETS")

exec >>/var/log/isp-apply.log 2>&1

echo "=== ISP apply \$(date) ==="

find_if(){
  local w d c
  w="\$(echo "\$1" | tr A-Z a-z)"

  for d in /sys/class/net/*; do
    [ -f "\$d/address" ] || continue
    c="\$(tr A-Z a-z < "\$d/address")"

    if [ "\$c" = "\$w" ]; then
      basename "\$d"
      return 0
    fi
  done

  return 1
}

eth_dhcp(){
  mkdir -p "/etc/net/ifaces/\$1"

  cat > "/etc/net/ifaces/\$1/options" <<EOT
BOOTPROTO=dhcp
TYPE=eth
ONBOOT=yes
CONFIG_IPV4=yes
CONFIG_IPV6=no
DISABLED=no
NM_CONTROLLED=no
EOT

  rm -f "/etc/net/ifaces/\$1/ipv4address" "/etc/net/ifaces/\$1/ipv4route"
}

eth_static(){
  mkdir -p "/etc/net/ifaces/\$1"

  cat > "/etc/net/ifaces/\$1/options" <<EOT
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
CONFIG_IPV4=yes
CONFIG_IPV6=no
DISABLED=no
NM_CONTROLLED=no
EOT

  echo "\$2" > "/etc/net/ifaces/\$1/ipv4address"
  rm -f "/etc/net/ifaces/\$1/ipv4route"
}

WAN="\$(find_if "\$WAN_MAC" || true)"
HQ="\$(find_if "\$HQ_MAC" || true)"
BR="\$(find_if "\$BR_MAC" || true)"

echo "WAN=\$WAN HQ=\$HQ BR=\$BR"

[ -n "\$WAN" ] || exit 1
[ -n "\$HQ" ] || exit 1
[ -n "\$BR" ] || exit 1

hostname "\$FQDN" || true

if command -v hostnamectl >/dev/null 2>&1; then
  hostnamectl set-hostname "\$FQDN" || true
fi

if [ -f "/usr/share/zoneinfo/\$TZ" ]; then
  ln -snf "/usr/share/zoneinfo/\$TZ" /etc/localtime
fi

echo "\$TZ" >/etc/timezone 2>/dev/null || true

eth_dhcp "\$WAN"
eth_static "\$HQ" "\$HQ_IP"
eth_static "\$BR" "\$BR_IP"

echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/99-isp-forward.conf
echo 'net.ipv4.ip_forward = 1' >/etc/net/sysctl.conf 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1 >/dev/null || true

ip link set "\$WAN" up || true
ip link set "\$HQ" up || true
ip link set "\$BR" up || true

ip addr flush dev "\$HQ" scope global 2>/dev/null || true
ip addr flush dev "\$BR" scope global 2>/dev/null || true

ip addr replace "\$HQ_IP" dev "\$HQ"
ip addr replace "\$BR_IP" dev "\$BR"

if command -v ifup >/dev/null 2>&1; then
  ifup "\$WAN" || true
  ifup "\$HQ" || true
  ifup "\$BR" || true
fi

if command -v dhcpcd >/dev/null 2>&1; then
  dhcpcd -x "\$WAN" 2>/dev/null || true
  dhcpcd -b "\$WAN" || true
fi

if command -v dhclient >/dev/null 2>&1; then
  dhclient -r "\$WAN" >/dev/null 2>&1 || true
  dhclient "\$WAN" || true
fi

if [ "\$NAT" = y ]; then
  if command -v iptables >/dev/null 2>&1; then
    iptables -P FORWARD ACCEPT || true

    for n in \$NAT_NETS; do
      iptables -C FORWARD -s "\$n" -o "\$WAN" -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -s "\$n" -o "\$WAN" -j ACCEPT || true

      iptables -C FORWARD -d "\$n" -i "\$WAN" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
        || iptables -A FORWARD -d "\$n" -i "\$WAN" -m state --state ESTABLISHED,RELATED -j ACCEPT || true

      iptables -t nat -C POSTROUTING -s "\$n" -o "\$WAN" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "\$n" -o "\$WAN" -j MASQUERADE || true
    done

  elif command -v nft >/dev/null 2>&1; then
    nft add table ip isp_nat 2>/dev/null || true
    nft 'add chain ip isp_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true

    for n in \$NAT_NETS; do
      nft add rule ip isp_nat postrouting ip saddr "\$n" oifname "\$WAN" masquerade 2>/dev/null || true
    done

  else
    echo "no iptables/nft"
  fi
fi

echo "--- addresses"
ip -4 -br a || true

echo "--- routes"
ip r || true

echo "--- ip_forward"
cat /proc/sys/net/ipv4/ip_forward || true

echo "--- nat"
iptables -t nat -S 2>/dev/null | grep MASQUERADE || nft list ruleset 2>/dev/null | grep masquerade || true

echo "=== done ==="
EOF

  chmod +x "$r/usr/local/sbin/isp-apply.sh"

  cat > "$r/etc/systemd/system/isp-apply.service" <<'EOF'
[Unit]
Description=Apply ISP offline network config
After=systemd-udev-settle.service local-fs.target
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/isp-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  ln -snf ../isp-apply.service "$r/etc/systemd/system/multi-user.target.wants/isp-apply.service"
}

need qm
need awk
need sed
need grep
need python3
need losetup
need mount
need umount
need findmnt

echo "=== ISP offline configurator ==="
echo "Без qemu-agent/SSH. ВМ остановится, диск изменится offline."
echo

VMID="$(ask "VMID ISP" "$VMID_DEF")"

qm config "$VMID" >/dev/null 2>&1 || die "VMID не найден"

echo
echo "Текущие интерфейсы VM:"
qm config "$VMID" | grep -E '^net[0-9]+:' || die "net-интерфейсы не найдены"

echo
FQDN="$(ask "Полное доменное имя (FQDN) устройства" "$FQDN_DEF")"
TZ="$(ask "Часовой пояс согласно месту проведения экзамена" "$TZ_DEF")"

echo
WAN_NET="$(ask "Интерфейс, подключенный к магистральному провайдеру (DHCP)" "$WAN_DEF")"
HQ_NET="$(ask "Сетевой интерфейс, к которому подключен HQ-RTR" "$HQ_DEF")"
BR_NET="$(ask "Сетевой интерфейс, к которому подключен BR-RTR" "$BR_DEF")"

[[ "$WAN_NET" =~ ^net[0-9]+$ ]] || die "WAN net неверный"
[[ "$HQ_NET" =~ ^net[0-9]+$ ]] || die "HQ net неверный"
[[ "$BR_NET" =~ ^net[0-9]+$ ]] || die "BR net неверный"

WAN_MAC="$(mac_of "$VMID" "$WAN_NET")"
HQ_MAC="$(mac_of "$VMID" "$HQ_NET")"
BR_MAC="$(mac_of "$VMID" "$BR_NET")"

[ -n "$WAN_MAC" ] || die "не смог получить MAC WAN"
[ -n "$HQ_MAC" ] || die "не смог получить MAC HQ"
[ -n "$BR_MAC" ] || die "не смог получить MAC BR"

echo
HQ_IP="$(ask "Интерфейс, к которому подключен HQ-RTR, подключен к сети (IP-адрес шлюза/CIDR)" "$HQ_IP_DEF")"
BR_IP="$(ask "Интерфейс, к которому подключен BR-RTR, подключен к сети (IP-адрес шлюза/CIDR)" "$BR_IP_DEF")"

cidr_ok "$HQ_IP" || die "неверный HQ CIDR"
cidr_ok "$BR_IP" || die "неверный BR CIDR"

cidr_priv "$HQ_IP" || die "HQ IP не private"
cidr_priv "$BR_IP" || die "BR IP не private"

HQ_NET_CIDR="$(cidr_net "$HQ_IP")"
BR_NET_CIDR="$(cidr_net "$BR_IP")"

echo
NAT="$(yn "Настроить динамическую сетевую трансляцию (NAT) для доступа к сети Интернет?" y)"
NAT_NETS="$(ask "Приватные сети (в сторону HQ и BR) для трансляции NAT" "$HQ_NET_CIDR $BR_NET_CIDR")"

DISK="$(disk_of "$VMID")"
[ -b "$DISK" ] || die "диск не найден: $DISK"

echo
cat <<EOF
=== Проверка ===
VMID: $VMID
Disk: $DISK
FQDN: $FQDN

WAN: $WAN_NET / $WAN_MAC / DHCP
HQ:  $HQ_NET / $HQ_MAC / $HQ_IP
BR:  $BR_NET / $BR_MAC / $BR_IP

NAT: $NAT
NAT-сети: $NAT_NETS
EOF

echo
[ "$(yn "Продолжить" y)" = y ] || exit 0

MP="$MP_DEF"
LOOP=""

trap cleanup EXIT

stop_vm "$VMID"

LOOP="$(mount_root "$DISK" "$MP")"

[ -d "$MP/etc" ] || die "не тот root-раздел"
[ -d "$MP/usr" ] || die "не тот root-раздел"

write_files "$MP"

cleanup
trap - EXIT

log "Запускаю VM $VMID"
qm start "$VMID"

echo
echo "DONE. ISP запущен."
echo "Лог внутри ВМ: /var/log/isp-apply.log"