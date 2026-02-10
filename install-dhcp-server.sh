#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "ejecuta con sudo"
    exit 1
fi

# Funcion para validar IP
validar_ip() {
    local ip=$1

    if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Error: formato IPv4 invalido" >&2
        return 1
    fi

    IFS='.' read -r a b c d <<< "$ip"
    if [ $a -gt 255 ] || [ $b -gt 255 ] || [ $c -gt 255 ] || [ $d -gt 255 ]; then
        echo "Error: octetos fuera de rango (0-255)" >&2
        return 1
    fi

    if [ "$ip" = "0.0.0.0" ]; then
        echo "Error: 0.0.0.0 no es una IP valida" >&2
        return 1
    fi

    if [ "$ip" = "255.255.255.255" ]; then
        echo "Error: 255.255.255.255 no es una IP valida" >&2
        return 1
    fi

    if [ "$d" = "0" ]; then
        echo "Error: $ip es una direccion de red" >&2
        return 1
    fi

    if [ "$d" = "255" ]; then
        echo "Error: $ip es una direccion de broadcast" >&2
        return 1
    fi

    return 0
}

# Funcion para pedir IP con validacion
pedir_ip() {
    local mensaje=$1
    local default=$2
    local ip=""

    while true; do
        read -p "$mensaje [$default]: " ip >&2
        ip=${ip:-$default}
        if validar_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done
}

# Instalar dnsmasq si no existe
if ! rpm -q dnsmasq &>/dev/null; then
    echo "instalando dhcp server"
    dnf install -y dnsmasq
fi

# Solicitar y validar parametros
START=$(pedir_ip "Rango inicial" "192.168.100.50")
END=$(pedir_ip "Rango final" "192.168.100.150")
GW=$(pedir_ip "GATEWAY" "192.168.100.1")
DNS=$(pedir_ip "DNS" "192.168.100.1")

# Crear configuracion
cat > /etc/dnsmasq.conf << EOF
interface=ens224
dhcp-range=$START,$END,255.255.255.0,12h
dhcp-option=3,$GW
dhcp-option=6,$DNS
EOF

# Configurar firewall
firewall-cmd --permanent --add-service=dhcp
firewall-cmd --permanent --add-service=dns
firewall-cmd --reload

# Iniciar servicio
systemctl enable --now dnsmasq
systemctl status dnsmasq

# Ver concesiones
cat /var/lib/misc/dnsmasq.leases