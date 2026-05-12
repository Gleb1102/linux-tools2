#!/usr/bin/env bash

# Функции для расчета масок (те же, что в основных скриптах для точности)
calc_prefix(){
  python3 - "$1" <<'PY'
import sys, math
try:
    p = 1
    while p < int(sys.argv[1]): p *= 2
    print(32 - int(math.log2(p)))
except: print("24")
PY
}

calc_mask(){
  python3 - "$1" <<'PY'
import sys, ipaddress
try: print(ipaddress.IPv4Network(f"0.0.0.0/{sys.argv[1]}").netmask)
except: print("255.255.255.0")
PY
}

ask(){
  local t="$1" d="$2" v
  read -r -p "$t [$d]: " v
  echo "${v:-$d}"
}

clear
echo "====================================================="
echo "   ГЕНЕРАТОР ДАННЫХ ДЛЯ ОТЧЕТА (МОДУЛЬ 1)            "
echo "====================================================="
echo "Введите данные из вашего билета для формирования таблицы:"
echo ""

# Сбор данных
ISP_HQ=$(ask "IP провайдера со стороны HQ (напр. 172.16.50.1)" "172.16.50.1")
ISP_BR=$(ask "IP провайдера со стороны BR (напр. 172.16.60.1)" "172.16.60.1")

HQ_RTR_WAN=$(ask "IP HQ-RTR (WAN)" "172.16.50.2")
BR_RTR_WAN=$(ask "IP BR-RTR (WAN)" "172.16.60.2")

V113_ID=$(ask "VLAN ID для HQ-SRV" "113")
V113_H=$(ask "Кол-во хостов HQ-SRV" "32")
V113_IP=$(ask "IP HQ-SRV" "192.168.100.10")

V213_ID=$(ask "VLAN ID для HQ-CLI" "213")
V213_H=$(ask "Кол-во хостов HQ-CLI (если 'не менее 16', пиши 18)" "18")
V213_IP="DHCP"

V813_ID=$(ask "VLAN ID управления" "813")
V813_H=$(ask "Кол-во хостов управления" "8")

BR_SRV_H=$(ask "Кол-во хостов BR-SRV" "16")
BR_SRV_IP=$(ask "IP BR-SRV" "192.168.0.2")

TUN_IP_HQ=$(ask "Внутренний IP туннеля (HQ)" "172.16.0.1")
TUN_IP_BR=$(ask "Внутренний IP туннеля (BR)" "172.16.0.2")

# Расчеты
P113=$(calc_prefix "$V113_H"); M113=$(calc_mask "$P113")
P213=$(calc_prefix "$V213_H"); M213=$(calc_mask "$P213")
P813=$(calc_prefix "$V813_H"); M813=$(calc_mask "$P813")
PBR=$(calc_prefix "$BR_SRV_H"); MBR=$(calc_mask "$PBR")

clear
echo "====================================================="
echo "   ГОТОВАЯ ТАБЛИЦА АДРЕСАЦИИ (Скопируй в Word)       "
echo "====================================================="
echo "Устройство | Интерфейс | IP-адрес | Маска | VLAN | Подсеть | Шлюз"
echo "---------------------------------------------------------------------"
echo "ISP | ens19 | $ISP_HQ | 255.255.255.240 | - | ${ISP_HQ%.*}.0/28 | -"
echo "ISP | ens20 | $ISP_BR | 255.255.255.240 | - | ${ISP_BR%.*}.0/28 | -"
echo "HQ-RTR | ge0 | $HQ_RTR_WAN | 255.255.255.240 | - | ${ISP_HQ%.*}.0/28 | $ISP_HQ"
echo "HQ-RTR | eth.$V113_ID | ${V113_IP%.*}.1 | $M113 | $V113_ID | ${V113_IP%.*}.0/$P113 | -"
echo "HQ-RTR | bmi.$V213_ID | ${V213_IP%.*}.1 | $M213 | $V213_ID | ${V213_IP%.*}.0/$P213 | -"
echo "HQ-RTR | eth.$V813_ID | 192.168.99.1 | $M813 | $V813_ID | 192.168.99.0/$P813 | -"
echo "HQ-RTR | Tunnel.1 | $TUN_IP_HQ | 255.255.255.252 | - | ${TUN_IP_HQ%.*}.0/30 | -"
echo "BR-RTR | ge0 | $BR_RTR_WAN | 255.255.255.240 | - | ${ISP_BR%.*}.0/28 | $ISP_BR"
echo "BR-RTR | ge1 | ${BR_SRV_IP%.*}.1 | $MBR | - | ${BR_SRV_IP%.*}.0/$PBR | -"
echo "BR-RTR | Tunnel.1 | $TUN_IP_BR | 255.255.255.252 | - | ${TUN_IP_BR%.*}.0/30 | -"
echo "HQ-SRV | eth.$V113_ID | $V113_IP | $M113 | $V113_ID | ${V113_IP%.*}.0/$P113 | ${V113_IP%.*}.1"
echo "BR-SRV | ens18 | $BR_SRV_IP | $MBR | - | ${BR_SRV_IP%.*}.0/$PBR | ${BR_SRV_IP%.*}.1"
echo "HQ-CLI | vlan$V213_ID | DHCP | DHCP | $V213_ID | DHCP | DHCP"
echo "---------------------------------------------------------------------"

echo ""
echo "====================================================="
echo "   ЧЕК-ЛИСТ ДЛЯ СКРИНШОТОВ (Где и что вводить)       "
echo "====================================================="
echo "Раздел 1.2 (VLAN) -> На HQ-RTR: 'show configuration running interface eth.$V113_ID'"
echo "Раздел 1.3 (Туннель) -> На HQ-RTR и BR-RTR: 'show configuration running interface tunnel.1'"
echo "Раздел 1.4 (OSPF) -> На HQ-RTR: 'show ip ospf neighbor' и 'show ip route ospf'"
echo "Раздел 1.5 (DHCP) -> На HQ-RTR: 'show configuration running dhcp-server'"
echo "Раздел 1.6 (DNS) -> На HQ-SRV: 'cat /etc/dnsmasq.conf'"
echo "====================================================="