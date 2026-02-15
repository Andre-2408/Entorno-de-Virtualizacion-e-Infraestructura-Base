#!/bin/bash

# ============================================================
# DHCP Server Manager - Linux (dnsmasq)
# ============================================================

DIR="$(cd "$(dirname "$0")" && pwd)"

# ─────────────────────────────────────────
# FUNCIONES DE VALIDACION
# ─────────────────────────────────────────

validar_ip() {
    local ip=$1

    # Formato IPv4
    if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Error: '$ip' no tiene formato IPv4 valido" >&2
        return 1
    fi

    IFS='.' read -r a b c d <<< "$ip"

    # Octetos en rango
    for oct in $a $b $c $d; do
        if [ "$oct" -gt 255 ]; then
            echo "Error: octeto '$oct' fuera de rango (0-255)" >&2
            return 1
        fi
    done

    # IPs no usables
    if [ "$ip" = "0.0.0.0" ]; then
        echo "Error: 0.0.0.0 no es una IP valida" >&2; return 1
    fi
    if [ "$ip" = "255.255.255.255" ]; then
        echo "Error: 255.255.255.255 no es una IP valida" >&2; return 1
    fi
    if [ "$a" = "127" ]; then
        echo "Error: 127.x.x.x es rango loopback, no valido" >&2; return 1
    fi
    if [ "$d" = "0" ]; then
        echo "Error: $ip es direccion de red" >&2; return 1
    fi
    if [ "$d" = "255" ]; then
        echo "Error: $ip es direccion de broadcast" >&2; return 1
    fi

    return 0
}

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

# Misma subred
misma_subred() {
    local ip1=$1
    local ip2=$2
    local mask=$3
    IFS='.' read -r a1 b1 c1 d1 <<< "$ip1"
    IFS='.' read -r a2 b2 c2 d2 <<< "$ip2"
    IFS='.' read -r m1 m2 m3 m4 <<< "$mask"
    [ $(( a1 & m1 )) -eq $(( a2 & m1 )) ] &&
    [ $(( b1 & m2 )) -eq $(( b2 & m2 )) ] &&
    [ $(( c1 & m3 )) -eq $(( c2 & m3 )) ] &&
    [ $(( d1 & m4 )) -eq $(( d2 & m4 )) ]
}

# IP a número
ip_to_int() {
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Calcular mascara desde prefijo
calcular_mascara() {
    local prefix=$1
    local mask=""
    local full=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
    mask="$(( (full >> 24) & 255 )).$(( (full >> 16) & 255 )).$(( (full >> 8) & 255 )).$(( full & 255 ))"
    echo $mask
}

# ─────────────────────────────────────────
# VERIFICAR INSTALACION
# ─────────────────────────────────────────
verificar_instalacion() {
    echo ""
    echo "=== Verificando instalacion ==="
    if rpm -q dnsmasq &>/dev/null; then
        echo "✔ dnsmasq instalado: $(rpm -q dnsmasq)"
    else
        echo "✘ dnsmasq NO esta instalado"
    fi

    echo ""
    if systemctl is-active dnsmasq &>/dev/null; then
        echo "✔ Servicio: ACTIVO"
    else
        echo "✘ Servicio: INACTIVO"
    fi

    echo ""
    if [ -f /etc/dnsmasq.conf ]; then
        echo "✔ Archivo de configuracion existe"
        cat /etc/dnsmasq.conf | grep -v "^#" | grep -v "^$"
    else
        echo "✘ Archivo de configuracion NO existe"
    fi

    echo ""
    read -p "Presiona Enter para volver al menu..." dummy
}

# ─────────────────────────────────────────
# MONITOR
# ─────────────────────────────────────────
monitor() {
    while true; do
        clear
        echo "=== MONITOR DHCP SERVER ==="
        echo ""

        echo "Estado del servicio:"
        systemctl status dnsmasq --no-pager | head -n 8
        echo ""

        echo "Concesiones activas:"
        LEASE_FILE="/var/lib/dnsmasq/dnsmasq.leases"
        if [ -f "$LEASE_FILE" ] && [ -s "$LEASE_FILE" ]; then
            cat "$LEASE_FILE"
            echo "Total: $(wc -l < "$LEASE_FILE")"
        else
            echo "No hay concesiones activas"
        fi
        echo ""

        echo "Configuracion actual:"
        cat /etc/dnsmasq.conf | grep -v "^#" | grep -v "^$" 2>/dev/null
        echo ""

        echo "Ultimos logs:"
        journalctl -u dnsmasq -n 10 --no-pager 2>/dev/null || \
            tail -n 10 /var/log/messages 2>/dev/null | grep dnsmasq || \
            echo "No hay logs disponibles"

        echo ""
        echo "r) Refrescar    0) Volver al menu"
        read -p "> " opt
        [ "$opt" = "0" ] && return
    done
}

# ─────────────────────────────────────────
# INSTALACION
# ─────────────────────────────────────────
instalar() {
    echo ""
    echo "=== Instalacion DHCP Server ==="

    # Verificar si ya esta instalado
    if rpm -q dnsmasq &>/dev/null && systemctl is-active dnsmasq &>/dev/null; then
        echo "dnsmasq ya esta instalado y activo."
        read -p "¿Deseas reinstalar? (s/n): " resp
        if [[ ! "$resp" =~ ^[sS]$ ]]; then
            echo "Volviendo al menu..."
            return
        fi
    fi

    # Instalar si no existe
    if ! rpm -q dnsmasq &>/dev/null; then
        echo "Instalando dnsmasq..."
        dnf install -y dnsmasq
    fi

    # Obtener IP del servidor
    SERVER_IP=$(ip -4 addr show ens224 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)192\.168\.\d+\.\d+' | head -1)
    fi

    if [ -z "$SERVER_IP" ]; then
        echo "Advertencia: No se detectó IP fija del servidor."
        SERVER_IP=$(pedir_ip "IP fija del servidor" "192.168.100.20")
    else
        echo "IP del servidor detectada: $SERVER_IP"
    fi

    # Prefijo de red
    read -p "Prefijo de subred [24]: " PREFIX
    PREFIX=${PREFIX:-24}
    MASK=$(calcular_mascara $PREFIX)
    echo "Mascara calculada: $MASK"

    # Rango inicial
    START=$(pedir_ip "Rango inicial" "192.168.100.50")

    # Rango final
    while true; do
        END=$(pedir_ip "Rango final" "192.168.100.150")

        # End debe ser mayor que Start
        if [ $(ip_to_int "$END") -le $(ip_to_int "$START") ]; then
            echo "Error: el rango final debe ser mayor que el inicial ($START)" >&2
            continue
        fi
        break
    done

    # Primera IP del rango → IP fija del servidor
    IFS='.' read -r a b c d <<< "$START"
    SERVER_STATIC="$a.$b.$c.$d"
    START_REAL="$a.$b.$c.$((d + 1))"
    echo "IP fija del servidor: $SERVER_STATIC"
    echo "Rango DHCP real:      $START_REAL - $END"

    # Asignar IP fija al servidor en ens224
    echo "Configurando IP fija $SERVER_STATIC/$PREFIX en ens224..."
    nmcli connection modify ens224 ipv4.addresses "$SERVER_STATIC/$PREFIX" ipv4.method manual 2>/dev/null || \
    nmcli connection add type ethernet con-name ens224 ifname ens224 ipv4.addresses "$SERVER_STATIC/$PREFIX" ipv4.method manual 2>/dev/null
    nmcli connection up ens224 &>/dev/null
    echo "IP fija asignada correctamente"

    # Gateway (opcional)
    read -p "Gateway (Enter para omitir): " GW
    if [ -n "$GW" ]; then
        while ! validar_ip "$GW" 2>/dev/null; do
            read -p "Gateway invalido. Intenta de nuevo (Enter para omitir): " GW
            [ -z "$GW" ] && break
        done
    fi

    # DNS (opcional)
    DNS_OPTS=""
    read -p "¿Configurar DNS primario? (s/n) [n]: " conf_dns1
    if [[ "$conf_dns1" =~ ^[sS]$ ]]; then
        DNS1=$(pedir_ip "DNS primario" "192.168.100.1")
        
        read -p "¿Configurar DNS alternativo? (s/n) [n]: " conf_dns2
        if [[ "$conf_dns2" =~ ^[sS]$ ]]; then
            DNS2=$(pedir_ip "DNS alternativo" "8.8.8.8")
            DNS_OPTS="dhcp-option=6,$DNS1,$DNS2"
        else
            DNS_OPTS="dhcp-option=6,$DNS1"
        fi
    fi

    # Crear directorio de leases
    mkdir -p /var/lib/dnsmasq
    touch /var/lib/dnsmasq/dnsmasq.leases
    chown dnsmasq:dnsmasq /var/lib/dnsmasq
    chown dnsmasq:dnsmasq /var/lib/dnsmasq/dnsmasq.leases
    chmod 755 /var/lib/dnsmasq
    chmod 664 /var/lib/dnsmasq/dnsmasq.leases

    # Crear configuracion
    cat > /etc/dnsmasq.conf << EOF
interface=ens224
dhcp-range=$START_REAL,$END,$MASK,12h
dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases
EOF

    [ -n "$GW" ] && echo "dhcp-option=3,$GW" >> /etc/dnsmasq.conf
    [ -n "$DNS_OPTS" ] && echo "$DNS_OPTS" >> /etc/dnsmasq.conf

    # Firewall
    firewall-cmd --permanent --add-service=dhcp &>/dev/null
    firewall-cmd --permanent --add-service=dns &>/dev/null
    firewall-cmd --reload &>/dev/null

    # SELinux permissive si está activo
    if command -v getenforce &>/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
        setenforce 0
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        echo "SELinux configurado en permissive"
    fi

    # Iniciar servicio
    systemctl enable --now dnsmasq
    systemctl restart dnsmasq

    echo ""
    echo "=== INSTALACION COMPLETADA ==="
    echo "Rango:   $START_REAL - $END"
    echo "Mascara: $MASK"
    [ -n "$GW" ] && echo "Gateway: $GW"
    [ -n "$DNS_OPTS" ] && echo "DNS:     $DNS_OPTS"

    read -p "Presiona Enter para volver al menu..." dummy
}

# ─────────────────────────────────────────
# MODIFICAR CONFIGURACION
# ─────────────────────────────────────────
modificar() {
    echo ""
    echo "=== Modificar configuracion DHCP ==="

    if [ ! -f /etc/dnsmasq.conf ]; then
        echo "Error: No hay configuracion existente. Instala primero."
        read -p "Presiona Enter para volver al menu..." dummy
        return
    fi

    # Mostrar config actual
    echo "Configuracion actual:"
    cat /etc/dnsmasq.conf | grep -v "^#" | grep -v "^$"
    echo ""

    # Obtener IP del servidor
    SERVER_IP=$(ip -4 addr show ens224 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)192\.168\.\d+\.\d+' | head -1)

    # Prefijo de subred
    read -p "Prefijo de subred [24]: " PREFIX
    PREFIX=${PREFIX:-24}
    MASK=$(calcular_mascara $PREFIX)
    echo "Mascara: $MASK"

    # Rango inicial
    START=$(pedir_ip "Rango inicial" "192.168.100.50")

    # Rango final
    while true; do
        END=$(pedir_ip "Rango final" "192.168.100.150")

        # End debe ser mayor que Start
        if [ $(ip_to_int "$END") -le $(ip_to_int "$START") ]; then
            echo "Error: el rango final debe ser mayor que el inicial ($START)" >&2
            continue
        fi
        break
    done

    # Primera IP del rango → IP fija del servidor
    IFS='.' read -r a b c d <<< "$START"
    SERVER_STATIC="$a.$b.$c.$d"
    START_REAL="$a.$b.$c.$((d + 1))"
    echo "IP fija del servidor: $SERVER_STATIC"
    echo "Rango DHCP real:      $START_REAL - $END"

    # Asignar IP fija al servidor en ens224
    echo "Configurando IP fija $SERVER_STATIC/$PREFIX en ens224..."
    nmcli connection modify ens224 ipv4.addresses "$SERVER_STATIC/$PREFIX" ipv4.method manual 2>/dev/null || \
    nmcli connection add type ethernet con-name ens224 ifname ens224 ipv4.addresses "$SERVER_STATIC/$PREFIX" ipv4.method manual 2>/dev/null
    nmcli connection up ens224 &>/dev/null
    echo "IP fija asignada correctamente"

    # Gateway (opcional)
    read -p "Gateway (Enter para omitir): " GW
    if [ -n "$GW" ]; then
        while ! validar_ip "$GW" 2>/dev/null; do
            read -p "Gateway invalido. Intenta de nuevo (Enter para omitir): " GW
            [ -z "$GW" ] && break
        done
    fi

    # DNS (opcional)
    DNS_OPTS=""
    read -p "¿Configurar DNS primario? (s/n) [n]: " conf_dns1
    if [[ "$conf_dns1" =~ ^[sS]$ ]]; then
        DNS1=$(pedir_ip "DNS primario" "192.168.100.1")
        
        read -p "¿Configurar DNS alternativo? (s/n) [n]: " conf_dns2
        if [[ "$conf_dns2" =~ ^[sS]$ ]]; then
            DNS2=$(pedir_ip "DNS alternativo" "8.8.8.8")
            DNS_OPTS="dhcp-option=6,$DNS1,$DNS2"
        else
            DNS_OPTS="dhcp-option=6,$DNS1"
        fi
    fi

    # Escribir nueva configuracion
    cat > /etc/dnsmasq.conf << EOF
interface=ens224
dhcp-range=$START_REAL,$END,$MASK,12h
dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases
EOF

    [ -n "$GW" ] && echo "dhcp-option=3,$GW" >> /etc/dnsmasq.conf
    [ -n "$DNS_OPTS" ] && echo "$DNS_OPTS" >> /etc/dnsmasq.conf

    # Reiniciar servicio
    systemctl restart dnsmasq

    echo ""
    echo "=== CONFIGURACION ACTUALIZADA ==="
    echo "Rango:   $START_REAL - $END"
    echo "Mascara: $MASK"
    [ -n "$GW" ] && echo "Gateway: $GW"
    [ -n "$DNS_OPTS" ] && echo "DNS:     $DNS_OPTS"

    read -p "Presiona Enter para volver al menu..." dummy
}

# ─────────────────────────────────────────
# RESTART
# ─────────────────────────────────────────
reiniciar() {
    echo ""
    echo "Reiniciando dnsmasq..."
    systemctl restart dnsmasq
    systemctl status dnsmasq --no-pager | head -5
    read -p "Presiona Enter para volver al menu..." dummy
}

# ─────────────────────────────────────────
# MENU PRINCIPAL
# ─────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta con sudo"
    exit 1
fi

while true; do
    clear
    echo "================================"
    echo "   DHCP Server Manager - Linux  "
    echo "================================"
    echo "1) Verificar instalacion"
    echo "2) Instalar DHCP"
    echo "3) Modificar configuracion"
    echo "4) Monitor"
    echo "5) Reiniciar servicio"
    echo "6) Salir"
    echo "--------------------------------"
    read -p "> " opt

    case "$opt" in
        1) verificar_instalacion ;;
        2) instalar ;;
        3) modificar ;;
        4) monitor ;;
        5) reiniciar ;;
        6) echo "Saliendo..."; exit 0 ;;
        *) echo "Opcion invalida"; sleep 1 ;;
    esac
done