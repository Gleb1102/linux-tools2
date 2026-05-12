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
VMID_DEF=106
FQDN_DEF="hq-rtr.au-team.irpo"
TZ_NAME_DEF="utc+5"

# Порты
WAN_PORT_DEF="ge0"
LAN_PORT_DEF="ge1"

# Пользователь
ADMIN_USER_DEF="net_admin"
ADMIN_PASS_DEF="P@ssword"

# Внешняя сеть
WAN_IP_DEF="172.16.50.2/28"
WAN_GW_DEF="172.16.50.1"
NAT_LOCAL_POOL_DEF="192.168.0.0-192.168.255.255" 

# VLAN IDs и кол-во адресов
V100_ID_DEF=113
V100_HOSTS_DEF=32
V100_GW_DEF="192.168.100.1"

V200_ID_DEF=213
V200_HOSTS_DEF=18 # Учтено условие "не менее 16" (+2 адреса)
V200_GW_DEF="192.168.200.1"

V999_ID_DEF=813
V999_HOSTS_DEF=8
V999_GW_DEF="192.168.99.1"

# DNS и DHCP
DNS_SRV_DEF="192.168.100.10"
DNS_DOMAIN_DEF="au-team.irpo"

# GRE и OSPF
GRE_REMOTE_DEF="172.16.60.2"
GRE_INNER_DEF="172.16.0.1/30"
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

calc_netmask(){
  python3 - "$1" <<'PY'
import sys, ipaddress
try:
    print(ipaddress.IPv4Network(f"0.0.0.0/{sys.argv[1]}").netmask)
except:
    print("255.255.255.0")
PY
}

calc_dhcp_range(){
  python3 - "$1" "$2" <<'PY'
import sys, ipaddress
try:
    net = ipaddress.IPv4Network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False)
    gw = ipaddress.IPv4Address(sys.argv[1])
    hosts = list(net.hosts())
    hosts = [h for h in hosts if h != gw]
    if hosts:
        print(f"{hosts[0]}-{hosts[-1]}")
    else:
        print("")
except:
    print("")
PY
}

# === Сбор данных ===
echo "=== HQ-RTR (EcoRouter Rose) Interactive Configurator ==="
VMID="$(ask "VMID устройства HQ-RTR" "$VMID_DEF")"

echo -e "\n--- Базовая настройка ---"
FQDN="$(ask "Настройте имена устройств согласно топологии (FQDN)" "$FQDN_DEF")"
TZ_NAME="$(ask "Часовой пояс (напр. utc+5)" "$TZ_NAME_DEF")"

ADMIN_USER="$(ask "Создайте пользователя на маршрутизаторах" "$ADMIN_USER_DEF")"
ADMIN_PASS="$(ask "Пароль пользователя $ADMIN_USER" "$ADMIN_PASS_DEF")"

echo -e "\n--- Привязка физических портов ---"
WAN_PORT="$(ask "Порт в сторону ISP (Провайдера)" "$WAN_PORT_DEF")"
LAN_PORT="$(ask "Порт в сторону локальной сети (HQ-SW)" "$LAN_PORT_DEF")"

echo -e "\n--- ISP (WAN) ---"
WAN_IP="$(ask "Интерфейс HQ-RTR подключен к сети (IP роутера/CIDR)" "$WAN_IP_DEF")"
WAN_GW="$(ask "Шлюз магистрального провайдера" "$WAN_GW_DEF")"
NAT_LOCAL_POOL="$(ask "Пул приватных адресов для динамической трансляции (NAT)" "$NAT_LOCAL_POOL_DEF")"

echo -e "\n--- Локальные сети (VLAN) ---"
V100_ID="$(ask "Сервер HQ-SRV должен находиться в ID VLAN" "$V100_ID_DEF")"
V100_HOSTS="$(ask "Вмещать адресов для HQ-SRV (Введи число из задания)" "$V100_HOSTS_DEF")"
V100_PREF="$(calc_prefix "$V100_HOSTS")"
V100_GW="$(ask "IP-адрес роутера для HQ-SRV (VLAN $V100_ID)" "$V100_GW_DEF")"
V100_IP="$V100_GW/$V100_PREF"
echo "  -> IP/CIDR: $V100_IP"

V200_ID="$(ask "Клиент HQ-CLI должен находиться в ID VLAN" "$V200_ID_DEF")"
V200_HOSTS="$(ask "Вмещать адресов для HQ-CLI (ВАЖНО: если 'не менее 16', вводи 18)" "$V200_HOSTS_DEF")"
V200_PREF="$(calc_prefix "$V200_HOSTS")"
V200_MASK="$(calc_netmask "$V200_PREF")"
V200_GW="$(ask "IP-адрес роутера для HQ-CLI (VLAN $V200_ID)" "$V200_GW_DEF")"
V200_IP="$V200_GW/$V200_PREF"
DHCP_RANGE="$(calc_dhcp_range "$V200_GW" "$V200_PREF")"
echo "  -> IP/CIDR: $V200_IP | Маска: $V200_MASK | DHCP Пул: $DHCP_RANGE"

V999_ID="$(ask "Создайте подсеть управления с ID VLAN" "$V999_ID_DEF")"
V999_HOSTS="$(ask "Вмещать адресов для управления" "$V999_HOSTS_DEF")"
V999_PREF="$(calc_prefix "$V999_HOSTS")"
V999_GW="$(ask "IP-адрес роутера для управления (VLAN $V999_ID)" "$V999_GW_DEF")"
V999_IP="$V999_GW/$V999_PREF"
echo "  -> IP/CIDR: $V999_IP"

echo -e "\n--- DHCP и DNS ---"
DNS_SRV="$(ask "Адрес DNS-сервера для машины HQ-CLI" "$DNS_SRV_DEF")"
DNS_DOMAIN="$(ask "DNS-суффикс для офисов HQ" "$DNS_DOMAIN_DEF")"

echo -e "\n--- GRE и OSPF ---"
GRE_REM_OUTER="$(ask "Внешний IP BR-RTR для туннеля" "$GRE_REMOTE_DEF")"
GRE_INNER="$(ask "Внутренний IP/CIDR GRE" "$GRE_INNER_DEF")"
OSPF_PASS="$(ask "Пароль для защиты OSPF" "$OSPF_PASS_DEF")"

echo -e "\n--- Авторизация для выполнения скрипта ---"
read -r -p "Введите текущий логин EcoRouter: " RTR_USER
read -r -s -p "Введите текущий пароль EcoRouter: " RTR_PASS
echo

# --- Расчет подсетей ---
GRE_IP_ONLY="${GRE_INNER%%/*}"
WAN_ONLY_IP="${WAN_IP%%/*}"

V100_NET="${V100_GW%.*}.0/$V100_PREF"
V200_NET="${V200_GW%.*}.0/$V200_PREF"
GRE_NET="${GRE_IP_ONLY%.*}.0/${GRE_INNER##*/}"

export VMID FQDN TZ_NAME ADMIN_USER ADMIN_PASS
export WAN_PORT LAN_PORT WAN_IP WAN_GW NAT_LOCAL_POOL WAN_ONLY_IP
export V100_ID V100_IP V100_NET
export V200_ID V200_IP V200_GW V200_MASK V200_NET DHCP_RANGE
export V999_ID V999_IP
export DNS_SRV DNS_DOMAIN
export GRE_REM_OUTER GRE_INNER GRE_NET OSPF_PASS
export RTR_USER RTR_PASS

# === Запуск Expect ===
expect <<'EOF'
set timeout 25
spawn qm terminal $env(VMID)
send "\r"

expect {
    "*login:" { send "$env(RTR_USER)\r"; exp_continue }
    "*assword:" { send "$env(RTR_PASS)\r"; exp_continue }
    "*>" { send "en\r"; exp_continue }
    "*#" { }
    timeout { send_user "\n[ОШИБКА]: Тайм-аут при входе\n"; exit 1 }
}

proc cmd {c} {
    send "$c\r"
    expect {
        "*#" { }
        "*(config-if)#" { }
        "*(config-port)#" { }
        "*(config-service-instance)#" { }
        "*(config-sub-map)#" { }
        "*(config-sub-policy)#" { }
        "*(config-sub-service)#" { }
        "*(config-filter-map-ipv4)#" { }
        "*(config-filter-map-policy-ipv4)#" { }
        "*(config-if-bmi)#" { }
        "*(config-dhcp-server)#" { }
        "*(config-ip-pool)#" { }
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
cmd "no service-instance $env(V100_ID)"
cmd "no service-instance $env(V200_ID)"
cmd "no service-instance $env(V999_ID)"
cmd "exit"
cmd "port $env(WAN_PORT)"
cmd "no service-instance 1"
cmd "exit"
cmd "no interface eth.wan"
cmd "no interface eth.$env(V100_ID)"
cmd "no interface bmi.$env(V200_ID)"
cmd "no interface eth.$env(V999_ID)"
cmd "no ip pool CLI_POOL"
cmd "no dhcp-server 1"
log_user 1

# 1. Создание L3 интерфейсов
cmd "interface eth.wan"
cmd "ip address $env(WAN_IP)"
cmd "ip nat outside"
cmd "exit"

cmd "interface eth.$env(V100_ID)"
cmd "ip address $env(V100_IP)"
cmd "ip nat inside"
cmd "exit"

cmd "interface bmi.$env(V200_ID)"
cmd "ip address $env(V200_IP)"
cmd "ip nat inside"
cmd "exit"

cmd "interface eth.$env(V999_ID)"
cmd "ip address $env(V999_IP)"
cmd "ip nat inside"
cmd "exit"

# 2. DHCP Сервер и Пул
cmd "ip pool CLI_POOL"
cmd "range $env(DHCP_RANGE)"
cmd "exit"

cmd "dhcp-server 1"
cmd "pool CLI_POOL 10"
cmd "gateway $env(V200_GW)"
cmd "mask $env(V200_MASK)"
cmd "dns $env(DNS_SRV)"
cmd "domain-name $env(DNS_DOMAIN)"
cmd "exit"

# 3. Subscriber Management (Авторизация и Политики)
cmd "ip prefix-list ALL_NET permit 0.0.0.0/0"

cmd "filter-map policy ipv4 ALLOW_ALL 10"
cmd "match any any any"
cmd "set accept"
cmd "exit"

cmd "subscriber-policy POL_LAN"
cmd "bandwidth in kbps 100000"
cmd "bandwidth out kbps 100000"
cmd "set filter-map in ALLOW_ALL"
cmd "set filter-map out ALLOW_ALL"
cmd "exit"

cmd "subscriber-service SERV_LAN"
cmd "set policy POL_LAN"
cmd "exit"

cmd "subscriber-map MAP_LAN 10"
cmd "match dynamic prefix-list ALL_NET"
cmd "set subscriber-service SERV_LAN"
cmd "exit"

# 4. Привязка к физическим портам (EVC Model)
cmd "port $env(WAN_PORT)"
cmd "no shutdown"
cmd "service-instance 1"
cmd "encapsulation untagged"
cmd "connect ip interface eth.wan"
cmd "exit"
cmd "exit"

cmd "port $env(LAN_PORT)"
cmd "no shutdown"
cmd "service-instance $env(V100_ID)"
cmd "encapsulation dot1q $env(V100_ID) exact"
cmd "rewrite pop 1"
cmd "connect ip interface eth.$env(V100_ID)"
cmd "exit"

cmd "service-instance $env(V200_ID)"
cmd "encapsulation dot1q $env(V200_ID) exact"
cmd "connect ip interface bmi.$env(V200_ID)"
cmd "exit"

cmd "service-instance $env(V999_ID)"
cmd "encapsulation dot1q $env(V99