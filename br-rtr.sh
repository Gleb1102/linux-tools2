#!/usr/bin/env bash
set -euo pipefail

echo "=== Проверка зависимостей хоста Proxmox ==="
if ! command -v expect &> /dev/null; then
    echo "[!] Установка пакета expect..."
    apt-get install expect -y
else
    echo "[OK] Пакет expect уже установлен."
fi

if ! command -v python3 &> /dev/null; then
    echo "[!] Установка python3..."
    apt-get install python3 -y
fi
echo "==========================================="
echo ""

# === Настройки по умолчанию ===
VMID_DEF=107
FQDN_DEF="br-rtr.au-team.irpo"
TZ_NAME_DEF="utc+5"

# Порты
WAN_PORT_DEF="ge0"
LAN_PORT_DEF="ge1"

# Пользователь
ADMIN_USER_DEF="net_admin"
ADMIN_PASS_DEF="P@ssword"

# Внешняя сеть
WAN_IP_DEF="172.16.60.2/28"
WAN_GW_DEF="172.16.60.1"
NAT_LOCAL_POOL_DEF="192.168.0.0-192.168.255.255" 

# Локальная сеть (BR-SRV)
LAN_HOSTS_DEF=16
LAN_GW_DEF="192.168.0.1"

# GRE и OSPF
GRE_REMOTE_DEF="172.16.50.2"  # Внешний IP HQ-RTR
GRE_INNER_DEF="172.16.0.2/30"
OSPF_PASS_DEF="P@ssword"

# === Функции ===
ask(){
  local t="$1" d="$2" v
  read -r -p "$t [$d]: " v
  echo "${v:-$d}"
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

# === Сбор данных ===
echo "=== BR-RTR (EcoRouter Rose) Interactive Configurator ==="
VMID="$(ask "VMID устройства BR-RTR" "$VMID_DEF")"

echo -e "\n--- Базовая настройка ---"
FQDN="$(ask "Настройте имена устройств согласно топологии (FQDN)" "$FQDN_DEF")"
TZ_NAME="$(ask "Часовой пояс (напр. utc+5)" "$TZ_NAME_DEF")"

ADMIN_USER="$(ask "Создайте пользователя на маршрутизаторах" "$ADMIN_USER_DEF")"
ADMIN_PASS="$(ask "Пароль пользователя $ADMIN_USER" "$ADMIN_PASS_DEF")"

echo -e "\n--- Привязка физических портов ---"
WAN_PORT="$(ask "Порт в сторону ISP (Провайдера)" "$WAN_PORT_DEF")"
LAN_PORT="$(ask "Порт в сторону BR-SRV (Локалка)" "$LAN_PORT_DEF")"

echo -e "\n--- ISP (WAN) ---"
WAN_IP="$(ask "Интерфейс BR-RTR подключен к сети (IP роутера/CIDR)" "$WAN_IP_DEF")"
WAN_GW="$(ask "Шлюз магистрального провайдера" "$WAN_GW_DEF")"
NAT_LOCAL_POOL="$(ask "Пул приватных адресов для динамической трансляции (NAT)" "$NAT_LOCAL_POOL_DEF")"

echo -e "\n--- Локальная сеть (LAN) ---"
LAN_HOSTS="$(ask "Локальная сеть в сторону BR-SRV должна вмещать не более (адресов)" "$LAN_HOSTS_DEF")"
LAN_PREF="$(calc_prefix "$LAN_HOSTS")"
LAN_GW="$(ask "IP-адрес роутера для локальной сети" "$LAN_GW_DEF")"
LAN_IP="$LAN_GW/$LAN_PREF"
echo "  -> IP/CIDR: $LAN_IP"

echo -e "\n--- GRE и OSPF ---"
GRE_REM_OUTER="$(ask "Внешний IP HQ-RTR (цель туннеля)" "$GRE_REMOTE_DEF")"
GRE_INNER="$(ask "Внутренний IP/CIDR GRE" "$GRE_INNER_DEF")"
OSPF_PASS="$(ask "Обеспечьте защиту протокола (OSPF) посредством парольной защиты" "$OSPF_PASS_DEF")"

echo -e "\n--- Авторизация ---"
read -r -p "Введите логин EcoRouter: " RTR_USER
read -r -s -p "Введите пароль EcoRouter: " RTR_PASS
echo

# --- ЧИСТЫЙ РАСЧЕТ ПОДСЕТЕЙ ---
LAN_IP_ONLY="${LAN_IP%%/*}"
GRE_IP_ONLY="${GRE_INNER%%/*}"
WAN_ONLY_IP="${WAN_IP%%/*}"

LAN_NET="${LAN_GW%.*}.0/$LAN_PREF"
GRE_NET="${GRE_IP_ONLY%.*}.0/${GRE_INNER##*/}"

export VMID FQDN TZ_NAME ADMIN_USER ADMIN_PASS
export WAN_PORT LAN_PORT WAN_IP WAN_GW NAT_LOCAL_POOL WAN_ONLY_IP
export LAN_IP LAN_NET LAN_IP_ONLY
export GRE_REM_OUTER GRE_INNER GRE_NET OSPF_PASS
export RTR_USER RTR_PASS

# === Запуск Expect ===
expect <<'EOF'
set timeout 15
spawn qm terminal $env(VMID)
send "\r"

expect {
    "*login:" { send "$env(RTR_USER)\r"; exp_continue }
    "*assword:" { send "$env(RTR_PASS)\r"; exp_continue }
    "*>" { send "en\r"; exp_continue }
    "*#" { }
    timeout { send_user "\nОШИБКА: Тайм-аут при входе\n"; exit 1 }
}

proc cmd {c} {
    send "$c\r"
    expect {
        "*#" { }
        "*(config-if)#" { }
        "*(config-port)#" { }
        "*(config-service-instance)#" { }
        "*(config-router)#" { }
        "*(config-user)#" { }
        timeout { send_user "\n\[ТАЙМАУТ НА КОМАНДЕ: $c\]\n" }
    }
}

cmd "conf t"
cmd "hostname $env(FQDN)"

# Настройка часового пояса через NTP
cmd "ntp timezone $env(TZ_NAME)"

# Настройка пользователя и прав
cmd "username $env(ADMIN_USER)"
cmd "password $env(ADMIN_PASS)"
cmd "role admin"
cmd "exit"

# Очистка старой конфигурации
log_user 0
cmd "port $env(LAN_PORT)"
cmd "no service-instance 2"
cmd "exit"
cmd "port $env(WAN_PORT)"
cmd "no service-instance 1"
cmd "exit"
cmd "no interface eth.wan"
cmd "no interface eth.lan"
log_user 1

# 1. Создание L3 интерфейсов
cmd "interface eth.wan"
cmd "ip address $env(WAN_IP)"
cmd "ip nat outside"
cmd "exit"

cmd "interface eth.lan"
cmd "ip address $env(LAN_IP)"
cmd "ip nat inside"
cmd "exit"

# 2. Привязка к физическим портам (Обе сети untagged, без VLAN)
cmd "port $env(WAN_PORT)"
cmd "no shutdown"
cmd "service-instance 1"
cmd "encapsulation untagged"
cmd "connect ip interface eth.wan"
cmd "exit"
cmd "exit"

cmd "port $env(LAN_PORT)"
cmd "no shutdown"
cmd "service-instance 2"
cmd "encapsulation untagged"
cmd "connect ip interface eth.lan"
cmd "exit"
cmd "exit"

# 3. Маршрутизация и NAT
cmd "ip route 0.0.0.0/0 $env(WAN_GW)"
cmd "ip nat pool LOCAL_NETS $env(NAT_LOCAL_POOL)"
cmd "ip nat source dynamic inside pool LOCAL_NETS overload interface eth.wan"

# 4. GRE Туннель и OSPF с паролем
cmd "interface tunnel.1"
cmd "ip address $env(GRE_INNER)"
cmd "ip tunnel $env(WAN_ONLY_IP) $env(GRE_REM_OUTER) mode gre"
cmd "ip ospf message-digest-key 1 md5 $env(OSPF_PASS)"
cmd "exit"

cmd "router ospf 1"
cmd "ospf router-id $env(WAN_ONLY_IP)"
cmd "network $env(GRE_NET) area 0"
cmd "network $env(LAN_NET) area 0"
cmd "area 0 authentication message-digest"
cmd "exit"

# Сохранение конфигурации
cmd "end"
cmd "write memory"

send_user "\nФИНАЛ: Настройка BR-RTR завершена успешно.\n"
send "\x0f"
EOF

echo "Настройка завершена."