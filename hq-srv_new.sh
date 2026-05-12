#!/usr/bin/env bash
set -euo pipefail

# === Настройки по умолчанию ===
VMID_DEF=108
FQDN_DEF="hq-srv.au-team.irpo"
TZ_DEF="Asia/Yekaterinburg"
DNS_DOMAIN_DEF="au-team.irpo"

IFACE_DEF="net0"
VLAN_ID_DEF=113
HOSTS_DEF=32
IP_ADDR_DEF="192.168.100.10"
GW_DEF="192.168.100.1"

DNS_FWD_DEF="77.88.8.7 77.88.8.3"
SSH_USER_DEF="sshuser"
SSH_PASS_DEF="P@ssword"
SSH_UID_DEF="2013"
SSH_PORT_DEF="2013"
SSH_TRIES_DEF="2"
SSH_BANNER_DEF="Authorized access only"

HQ_RTR_IP_DEF="192.168.100.1"
HQ_CLI_IP_DEF="192.168.200.2"
BR_RTR_IP_DEF="192.168.0.1"
BR_SRV_IP_DEF="192.168.0.2"
ISP_HQ_IP_DEF="172.16.50.1"
ISP_BR_IP_DEF="172.16.60.1"

MP="/mnt/hq-srv"

# === Базовые функции ===
log(){ echo "[HQ-SRV OFFLINE] $*"; }
die(){ echo "ОШИБКА: $*" >&2; exit 1; }
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

mac_of(){
  qm config "$1" | awk -v s="$2:" '$1==s{print}' | sed -nE 's/.*(virtio|e1000|rtl8139|vmxnet3)=([0-9A-Fa-f:]+).*/\2/p'
}

disk_of(){
  local line vol d
  line="$(qm config "$1" | awk -F': ' '/^(scsi[0-9]|virtio[0-9]|sata[0-9]|ide[0-9]):/ && !/media=cdrom/ && !/\.iso/ {print $2; exit}')"
  [ -n "$line" ] || die "Диск ВМ не найден или это CD-ROM"

  vol="${line%%,*}"
  case "$vol" in
    local-lvm:*)
      d="${vol#local-lvm:}"
      lvchange -a y "pve/$d" >/dev/null 2>&1 || true
      sleep 1
      echo "/dev/pve/$d"
      ;;
    /dev/*) echo "$vol" ;;
    *) die "Неподдерживаемый тип диска: $vol" ;;
  esac
}

stop_vm(){
  local s i
  s="$(qm status "$1" | awk '{print $2}')"
  if [ "$s" = stopped ]; then return; fi
  log "Останавливаю VM $1..."
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
    log "$mp уже смонтирован"
    src="$(findmnt -no SOURCE "$mp" || true)"
    if [[ "$src" =~ ^(/dev/loop[0-9]+)p[0-9]+$ ]]; then echo "${BASH_REMATCH[1]}"; else echo EXISTING; fi
    return
  fi

  loop="$(losetup -Pf --show "$disk")"
  sleep 1

  # Ищем корень Alt Linux
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
  die "Корневой раздел не найден на диске $disk"
}

cleanup(){
  sync || true
  if mountpoint -q "$MP"; then umount "$MP" || true; fi
  if [ "${LOOP:-}" != EXISTING ] && [ -n "${LOOP:-}" ]; then losetup -d "$LOOP" 2>/dev/null || true; fi
}

calc_prefix(){
  python3 - "$1" <<'PY'
import sys, math
try:
    addrs = int(sys.argv[1])
    p = 1
    while p < addrs: p *= 2
    print(32 - int(math.log2(p)))
except Exception:
    print("24")
PY
}

# === Генерация настроек ===
write_files(){
  local r="$1"
  local short="${FQDN%%.*}"

  log "Записываю настройки в $r..."

  echo "$FQDN" > "$r/etc/hostname"
  touch "$r/etc/hosts"
  grep -vE "[[:space:]](${FQDN}|${short})([[:space:]]|$)" "$r/etc/hosts" > "$r/etc/hosts.tmp" || true
  cat "$r/etc/hosts.tmp" > "$r/etc/hosts"
  rm -f "$r/etc/hosts.tmp"
  echo "127.0.1.1 $FQDN $short" >> "$r/etc/hosts"

  if [ -f "$r/usr/share/zoneinfo/$TZ" ]; then ln -snf "/usr/share/zoneinfo/$TZ" "$r/etc/localtime"; fi
  echo "$TZ" > "$r/etc/timezone" 2>/dev/null || true

  mkdir -p "$r/usr/local/sbin" "$r/etc/systemd/system/multi-user.target.wants" "$r/etc/net"

  # Создаем env-файл
  cat > "$r/etc/hq-srv.env" <<EOF
FQDN="$FQDN"
MAC="$MAC"
VLAN_ID="$VLAN_ID"
IP_CIDR="$IP_CIDR"
IP_ONLY="$IP_ONLY"
GW="$GW"
DNS_DOMAIN="$DNS_DOMAIN"
DNS_FWD="$DNS_FWD"
SSH_USER="$SSH_USER"
SSH_PASS="$SSH_PASS"
SSH_UID="$SSH_UID"
SSH_PORT="$SSH_PORT"
SSH_TRIES="$SSH_TRIES"
SSH_BANNER="$SSH_BANNER"
HQ_RTR_IP="$HQ_RTR_IP"
HQ_CLI_IP="$HQ_CLI_IP"
BR_RTR_IP="$BR_RTR_IP"
BR_SRV_IP="$BR_SRV_IP"
ISP_HQ_IP="$ISP_HQ_IP"
ISP_BR_IP="$ISP_BR_IP"
EOF

  # Внутренний скрипт
  cat > "$r/usr/local/sbin/hq-srv-apply.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec >>/var/log/hq-srv-apply.log 2>&1
echo "=== HQ-SRV Init $(date) ==="

source /etc/hq-srv.env

# 1. Настройка сети
IFACE=""
for d in /sys/class/net/*; do
  [ -f "$d/address" ] || continue
  c="$(tr A-Z a-z < "$d/address")"
  if [ "$c" = "$(echo "$MAC" | tr A-Z a-z)" ]; then
    IFACE="$(basename "$d")"
    break
  fi
done

if [ -n "$IFACE" ]; then
  mkdir -p "/etc/net/ifaces/$IFACE"
  cat > "/etc/net/ifaces/$IFACE/options" <<EOT
BOOTPROTO=static
TYPE=eth
ONBOOT=yes
CONFIG_IPV4=yes
CONFIG_IPV6=no
NM_CONTROLLED=no
EOT

  VLAN_IFACE="${IFACE}.${VLAN_ID}"
  mkdir -p "/etc/net/ifaces/$VLAN_IFACE"
  cat > "/etc/net/ifaces/$VLAN_IFACE/options" <<EOT
TYPE=vlan
HOST=$IFACE
VID=$VLAN_ID
BOOTPROTO=static
ONBOOT=yes
CONFIG_IPV4=yes
CONFIG_IPV6=no
NM_CONTROLLED=no
EOT
  
  echo "$IP_CIDR" > "/etc/net/ifaces/$VLAN_IFACE/ipv4address"
  echo "default via $GW" > "/etc/net/ifaces/$VLAN_IFACE/ipv4route"
  
  cat > "/etc/net/ifaces/$VLAN_IFACE/resolv.conf" <<EOT
search $DNS_DOMAIN
nameserver 127.0.0.1
EOT
  
  ip link set "$IFACE" up || true
  ip addr flush dev "$IFACE" scope global 2>/dev/null || true
  
  ip link show "$VLAN_IFACE" >/dev/null 2>&1 || ip link add link "$IFACE" name "$VLAN_IFACE" type vlan id "$VLAN_ID"
  ip link set "$VLAN_IFACE" up || true
  ip addr flush dev "$VLAN_IFACE" scope global 2>/dev/null || true
  ip addr add "$IP_CIDR" dev "$VLAN_IFACE" || true
  ip route add default via "$GW" || true
fi

# 2. Настройка SSH и пользователя
if ! id "$SSH_USER" >/dev/null 2>&1; then
  useradd -m -u "$SSH_UID" -s /bin/bash "$SSH_USER"
fi
echo "$SSH_USER:$SSH_PASS" | chpasswd
mkdir -p /etc/sudoers.d
echo "$SSH_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-$SSH_USER"
chmod 0440 "/etc/sudoers.d/90-$SSH_USER"

echo "$SSH_BANNER" > /etc/issue.net
SSHD_CONF="/etc/openssh/sshd_config"
[ -f "$SSHD_CONF" ] || SSHD_CONF="/etc/ssh/sshd_config"

sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSHD_CONF" || echo "Port $SSH_PORT" >> "$SSHD_CONF"
grep -q "^AllowUsers $SSH_USER" "$SSHD_CONF" || echo "AllowUsers $SSH_USER" >> "$SSHD_CONF"
grep -q "^MaxAuthTries $SSH_TRIES" "$SSHD_CONF" || echo "MaxAuthTries $SSH_TRIES" >> "$SSHD_CONF"
grep -q "^Banner /etc/issue.net" "$SSHD_CONF" || echo "Banner /etc/issue.net" >> "$SSHD_CONF"
grep -q "^PasswordAuthentication yes" "$SSHD_CONF" || echo "PasswordAuthentication yes" >> "$SSHD_CONF"

systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true

# 3. Настройка DNS (dnsmasq)
cat > /etc/dnsmasq.conf <<EOT
port=53
domain-needed
bogus-priv
no-hosts
no-resolv
bind-interfaces
listen-address=127.0.0.1,$IP_ONLY
domain=$DNS_DOMAIN
local=/$DNS_DOMAIN/
EOT

for f in $DNS_FWD; do
  echo "server=$f" >> /etc/dnsmasq.conf
done

cat >> /etc/dnsmasq.conf <<EOT
host-record=hq-rtr.$DNS_DOMAIN,hq-rtr,$HQ_RTR_IP
host-record=hq-srv.$DNS_DOMAIN,hq-srv,$IP_ONLY
host-record=hq-cli.$DNS_DOMAIN,hq-cli,$HQ_CLI_IP
address=/br-rtr.$DNS_DOMAIN/$BR_RTR_IP
address=/br-rtr/$BR_RTR_IP
address=/br-srv.$DNS_DOMAIN/$BR_SRV_IP
address=/br-srv/$BR_SRV_IP
address=/docker.$DNS_DOMAIN/$ISP_HQ_IP
address=/docker/$ISP_HQ_IP
address=/web.$DNS_DOMAIN/$ISP_BR_IP
address=/web/$ISP_BR_IP
EOT

echo "=== Done ==="
EOF

  chmod +x "$r/usr/local/sbin/hq-srv-apply.sh"

  cat > "$r/etc/systemd/system/hq-srv-apply.service" <<'EOF'
[Unit]
Description=Apply HQ-SRV offline config
After=network-pre.target local-fs.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hq-srv-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  ln -snf ../hq-srv-apply.service "$r/etc/systemd/system/multi-user.target.wants/hq-srv-apply.service"

  cat > "$r/root/install-dns.sh" <<'EOF'
#!/usr/bin/env bash
set -e
echo "Проверяем доступ в интернет..."
if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
  echo "Интернет есть! Устанавливаем dnsmasq..."
  apt-get update
  apt-get install -y dnsmasq
  systemctl enable --now dnsmasq
  echo "Готово! dnsmasq установлен и подхватил настройки."
else
  echo "ОШИБКА: Нет интернета."
fi
EOF
  chmod +x "$r/root/install-dns.sh"
}

# === Основная логика ===
need qm; need awk; need sed; need grep; need losetup; need mount; need umount; need findmnt; need python3

echo "=== HQ-SRV Offline Configurator ==="
VMID="$(ask "VMID сервера HQ-SRV" "$VMID_DEF")"
qm config "$VMID" >/dev/null 2>&1 || die "VMID не найден"

IFACE_NET="$(ask "Сетевой интерфейс HQ-SRV" "$IFACE_DEF")"
MAC="$(mac_of "$VMID" "$IFACE_NET")"
[ -n "$MAC" ] || die "MAC адрес для интерфейса $IFACE_NET не найден"

echo -e "\n--- Базовая настройка ---"
FQDN="$(ask "Имя устройства согласно топологии (FQDN)" "$FQDN_DEF")"
TZ="$(ask "Часовой пояс согласно месту проведения экзамена" "$TZ_DEF")"
DNS_DOMAIN="$(ask "DNS-суффикс для офисов" "$DNS_DOMAIN_DEF")"

echo -e "\n--- Локальная сеть и VLAN ---"
VLAN_ID="$(ask "Сервер HQ-SRV должен находиться в ID VLAN" "$VLAN_ID_DEF")"

HOSTS="$(ask "Локальная сеть в сторону HQ-SRV (VLAN $VLAN_ID) должна вмещать не более (адресов)" "$HOSTS_DEF")"
PREFIX="$(calc_prefix "$HOSTS")"
echo "  -> Автоматически рассчитана маска: /$PREFIX"

IP_ONLY="$(ask "IP-адрес сервера HQ-SRV" "$IP_ADDR_DEF")"
IP_CIDR="$IP_ONLY/$PREFIX"
GW="$(ask "Адрес шлюза по умолчанию для HQ-SRV" "$GW_DEF")"

echo -e "\n--- Безопасный удаленный доступ и Пользователи ---"
SSH_USER="$(ask "Создайте пользователя на серверах" "$SSH_USER_DEF")"
SSH_PASS="$(ask "Пароль пользователя $SSH_USER" "$SSH_PASS_DEF")"
SSH_UID="$(ask "Идентификатор пользователя $SSH_USER" "$SSH_UID_DEF")"
SSH_PORT="$(ask "Порт для подключения SSH" "$SSH_PORT_DEF")"
SSH_TRIES="$(ask "Ограничьте количество попыток входа до" "$SSH_TRIES_DEF")"
SSH_BANNER="$(ask "Настройте баннер" "$SSH_BANNER_DEF")"

echo -e "\n--- Настройка DNS ---"
DNS_FWD="$(ask "В качестве DNS-сервера пересылки используйте любой общедоступный DNS-сервер" "$DNS_FWD_DEF")"

echo "--- Для генерации DNS таблиц (Записи A, PTR) ---"
HQ_RTR_IP="$(ask "IP адрес HQ-RTR" "$HQ_RTR_IP_DEF")"
HQ_CLI_IP="$(ask "IP адрес HQ-CLI" "$HQ_CLI_IP_DEF")"
BR_RTR_IP="$(ask "IP адрес BR-RTR" "$BR_RTR_IP_DEF")"
BR_SRV_IP="$(ask "IP адрес BR-SRV" "$BR_SRV_IP_DEF")"
ISP_HQ_IP="$(ask "IP адрес ISP (docker.au-team.irpo)" "$ISP_HQ_IP_DEF")"
ISP_BR_IP="$(ask "IP адрес ISP (web.au-team.irpo)" "$ISP_BR_IP_DEF")"

DISK="$(disk_of "$VMID")"

echo
cat <<EOF
=== Сводка ===
VMID: $VMID | Диск: $DISK
FQDN: $FQDN
Сеть: MAC $MAC -> VLAN: $VLAN_ID | IP: $IP_CIDR | GW: $GW
SSH:  $SSH_USER / $SSH_PASS (Port $SSH_PORT)
EOF

echo
[ "$(yn "Начать настройку?" y)" = y ] || exit 0

LOOP=""
trap cleanup EXIT

stop_vm "$VMID"
LOOP="$(mount_root "$DISK" "$MP")"
write_files "$MP"
cleanup
trap - EXIT

log "Запускаю VM $VMID..."
qm start "$VMID"

echo
echo "DONE! Сервер запущен. Настройки применятся автоматически."
echo "Лог внутри ВМ: /var/log/hq-srv-apply.log"