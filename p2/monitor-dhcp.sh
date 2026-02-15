#!/bin/bash

echo "Monitor DHCP SERVER"
echo ""

echo "Estado del Servicio:"
systemctl status dnsmasq --no-pager | head -n 10
echo ""

echo "Concesiones Activas:"
# Crear archivo de leases si no existe
if [ ! -f /var/lib/misc/dnsmasq.leases ]; then
    mkdir -p /var/lib/misc
    touch /var/lib/misc/dnsmasq.leases
fi

# Agregar leasefile al config si no está
if ! grep -q "dhcp-leasefile" /etc/dnsmasq.conf; then
    echo "dhcp-leasefile=/var/lib/misc/dnsmasq.leases" >> /etc/dnsmasq.conf
    systemctl restart dnsmasq
fi

if [ -s /var/lib/misc/dnsmasq.leases ]; then
    cat /var/lib/misc/dnsmasq.leases
    echo ""
    echo "Total concesiones: $(wc -l < /var/lib/misc/dnsmasq.leases)"
else
    echo "No hay concesiones activas"
fi
echo ""

echo "Configuracion Actual:"
cat /etc/dnsmasq.conf | grep -v "^#" | grep -v "^$"
echo ""

echo "Ultimos Logs:"
journalctl -u dnsmasq -n 10 --no-pager