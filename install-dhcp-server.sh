if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Debes ejecutar como root (sudo $0)"
    exit 1
fi


echo "Actualizando sistema..."
dnf update -y


echo "Instalando ISC DHCP Server..."
dnf install -y dhcp-server


echo "Verificando instalación..."
rpm -qa | grep dhcp
dhcpd --version
echo "Configurando servicio..."
systemctl enable dhcpd
systemctl start dhcpd


echo "Configurando firewall..."
firewall-cmd --permanent --add-service=dhcp
firewall-cmd --permanent --add-service=dhcpv6
firewall-cmd --reload


echo "Verificando estado del servicio..."
systemctl status dhcpd --no-pager
