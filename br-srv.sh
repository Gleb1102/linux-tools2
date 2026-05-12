#!/usr/bin/env bash
set -euo pipefail

# === Настройки по умолчанию ===
VMID_DEF=109
FQDN_DEF="br-srv.au-team.irpo"
TZ_DEF="Asia/Yekaterinburg"

IFACE_DEF="net0"
HOSTS_DEF=16
IP_ADDR_DEF="192.168.0.2"
GW_DEF="192.168.0.1"

DNS_DEF="192.168.100.10"
DNS_DOMAIN_DEF="au-team.irpo"

SSH_USER_DEF="sshuser"
SSH_PASS_DEF="P@ssword"
SSH_UID_DEF="2013"
SSH_PORT_DEF="2013"
SSH_TRIES_DEF="2"
SSH_BANNER_DEF="Authorized access only"

MP="/mnt/br-srv"

# === Базовые функции ===
log(){ echo "[BR-SRV OFFLINE] $*"; }
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

  cat > "$r/etc/br-srv.env" <<EOF
FQDN="$FQDN"
MAC="$MAC"
IP_CIDR="$IP_CIDR"
GW="$GW"
DNS_SRV="$DNS_SRV"
DNS_DOMAIN="$DNS_DOMAIN"
SSH_USER="$SSH_USER"
SSH_PASS="$SSH_PASS"
SSH_UID="$SSH_UID"
SSH_PORT="$SSH_PORT"
SSH_TRIES="$SSH_TRIES"
SSH_BANNER="$SSH_BANNER"
EOF

  cat > "$r/usr/local/sbin/br-srv-apply.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec >>/var/log/br-srv-apply.log 2>&1
echo "=== BR-SRV Init $(date) ==="

source /etc/br-srv.env

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
  echo "$IP_CIDR" > "/etc/net/ifaces/$IFACE/ipv4address"
  echo "default via $GW" > "/etc/net/ifaces/$IFACE/ipv4route"
  
  cat > "/etc/net/ifaces/$IFACE/resolv.conf" <<EOT
search $DNS_DOMAIN
nameserver $DNS_SRV
EOT
  
  ip link set "$IFACE" up || true
  ip addr flush dev "$IFACE" scope global 2>/dev/null || true
  ip addr add "$IP_CIDR" dev "$IFACE" || true
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

echo "=== Done ==="
EOF

  chmod +x "$r/usr/local/sbin/br-srv-apply.sh"

  cat > "$r/etc/systemd/system/br-srv-apply.service" <<'EOF'
[Unit]
Description=Apply BR-SRV offline config
After=network-pre.target local-fs.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/br-srv-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  ln -snf ../br-srv-apply.service "$r/etc/systemd/system/multi-user.target.wants/br-srv-apply.service"
}

# === Основная логика ===
need qm; need awk; need sed; need grep; need losetup; need mount; need umount; need findmnt; need python3

echo "=== BR-SRV Offline Configurator ==="
VMID="$(ask "VMID сервера BR-SRV" "$VMID_DEF")"
qm config "$VMID" >/dev/null 2>&1 || die "VMID не найден"

IFACE_NET="$(ask "Сетевой интерфейс BR-SRV" "$IFACE_DEF")"
MAC="$(mac_of "$VMID" "$IFACE_NET")"
[ -n "$MAC" ] || die "MAC адрес для интерфейса $IFACE_NET не найден"

echo -e "\n--- Базовая настройка ---"
FQDN="$(ask "Имя устройства согласно топологии (FQDN)" "$FQDN_DEF")"
TZ="$(ask "Часовой пояс согласно месту проведения экзамена" "$TZ_DEF")"

echo -e "\n--- Локальная сеть и адресация ---"
HOSTS="$(ask "Локальная сеть в сторону BR-SRV должна вмещать не более (адресов)" "$HOSTS_DEF")"
PREFIX="$(calc_prefix "$HOSTS")"
echo "  -> Автоматически рассчитана маска: /$PREFIX"

IP_ONLY="$(ask "IP-адрес сервера BR-SRV" "$IP_ADDR_DEF")"
IP_CIDR="$IP_ONLY/$PREFIX"
GW="$(ask "Адрес шлюза по умолчанию (маршрутизатор BR-RTR)" "$GW_DEF")"
DNS_SRV="$(ask "Адрес DNS-сервера (HQ-SRV)" "$DNS_DEF")"
DNS_DOMAIN="$(ask "DNS-суффикс для офисов" "$DNS_DOMAIN_DEF")"

echo -e "\n--- Безопасный удаленный доступ и Пользователи ---"
SSH_USER="$(ask "Создайте пользователя на серверах" "$SSH_USER_DEF")"
SSH_PASS="$(ask "Пароль пользователя $SSH_USER" "$SSH_PASS_DEF")"
SSH_UID="$(ask "Идентификатор пользователя $SSH_USER" "$SSH_UID_DEF")"
SSH_PORT="$(ask "Порт для подключения SSH" "$SSH_PORT_DEF")"
SSH_TRIES="$(ask "Ограничьте количество попыток входа до" "$SSH_TRIES_DEF")"
SSH_BANNER="$(ask "Настройте баннер" "$SSH_BANNER_DEF")"

DISK="$(disk_of "$VMID")"

echo
cat <<EOF
=== Сводка ===
VMID: $VMID | Диск: $DISK
FQDN: $FQDN
Сеть: MAC $MAC -> IP: $IP_CIDR | GW: $GW
DNS:  $DNS_SRV (Поиск: $DNS_DOMAIN)
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
echo "Лог внутри ВМ: /var/log/br-srv-apply.log"