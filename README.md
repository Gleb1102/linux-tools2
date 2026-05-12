# linux-tools2
## 1. Настройка Proxmox (PVE)
```bash
cd /root
git clone [https://github.com/Gleb1102/linux-tools.git](https://github.com/Gleb1102/linux-tools.git)
cd linux-tools && chmod +x *.sh

echo "nameserver 8.8.8.8" > /etc/resolv.conf

## 2 (HQ-SRV) Установка и запуск DNS
apt-get update
apt-get install dnsmasq -y
systemctl enable --now dnsmasq
systemctl status dnsmasq

## 3 (HQ-CLI) Настройка VLAN 200
nmcli con delete "Wired connection 1" 2>/dev/null || true
nmcli con add type vlan con-name vlanX(указать свой) dev ens18 id x (указать vlan свой) ipv4.method auto ipv6.method ignore
nmcli con up vlan(свой)

# Имя и время
hostnamectl set-hostname hq-cli.au-team.irpo
timedatectl set-timezone Asia/Yekaterinburg

очистка pve:
history -c && history -w
