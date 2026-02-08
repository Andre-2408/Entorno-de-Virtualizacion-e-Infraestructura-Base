

if [ "$EUID" -ne 0 ]; then
    echo "ejecuta con sudo"
    exit 1
fi

if ! rpm -q dnsmasq &>/dev/null; then
    echo "instalando dhcp server"
    dnf install -y dnsmasq
fi

read -p "Rango inicial [192.168.100.50]: " START
START=${START:-192.168.100.50}
read -p "rango final [192.168.100.150] :" END
END=${END:-192.168.100.150}
read -p "GATEWAY [192.168.100.1] " GW
GW=${GW:-192.168.100.1}
read -p "DNS [192.168.100.1]: " DNS
DNS=${DNS:-192.168.100.1}

sudo bash -c 'cat > /etc/dhcp/dhcpd.config << EOF
authoritative;
default-lease-time 7200;
max-lease-time 14400;

subnet 192.168.100.0 netmask 255.255.255.0 {
    range $START $END;
    option routers $GW;
    option subnet-mask 255.255.255.0;
    option domain-name-servers $DNS;
}
EOF'

firewall-cmd --permanent --add-service=dhcp
firewall-cmd --permanent --add-service=dns
firewall-cmd --reload

systemctl enable --now dnsmasq
sudo systemctl status dnsmasq

sudo cat /var/lib/dhcpd/dhcpd.leases