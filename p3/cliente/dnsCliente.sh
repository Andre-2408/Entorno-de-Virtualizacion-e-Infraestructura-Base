#!/bin/bash
# =========================================================
# Script de validacion DNS - Cliente POP!_OS
# Dominio: reprobados.com | Interfaz: ens37
# =========================================================

DOMINIO_BASE="reprobados.com"
INTERFAZ="ens37"
EVIDENCIA_DIR="$HOME/evidencias_dns_cliente"
LOG="${EVIDENCIA_DIR}/cliente_dns.log"
IP_SERVIDOR_DNS=""
IP_CLIENTE=""

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
B='\033[1m'
N='\033[0m'

msg_ok()   { echo -e "  ${G}[OK]${N} $1"; }
msg_err()  { echo -e "  ${R}[ERROR]${N} $1"; }
msg_info() { echo -e "  ${C}[INFO]${N} $1"; }
msg_warn() { echo -e "  ${Y}[AVISO]${N} $1"; }
pausar()   { echo ""; read -rp "  Presione ENTER para continuar... " _; }

validar_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a o <<< "$ip"
        for oct in "${o[@]}"; do (( oct < 0 || oct > 255 )) && return 1; done
        return 0
    fi
    return 1
}

actualizar_ip() {
    IP_CLIENTE=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
}

if [[ $EUID -ne 0 ]]; then
    echo "Error: ejecute como root (sudo)."
    exit 1
fi

mkdir -p "$EVIDENCIA_DIR"

# =========================================================
# MENU PRINCIPAL
# =========================================================
while true; do
    clear
    actualizar_ip

    echo ""
    echo -e "  ${B}CLIENTE DNS - POP!_OS${N}"
    echo "  ================================================"
    echo "  Interfaz: $INTERFAZ | IP: ${IP_CLIENTE:-N/A} | DNS: ${IP_SERVIDOR_DNS:-sin configurar}"
    echo "  ================================================"
    echo ""
    echo "  1) Verificar configuracion de red"
    echo "  2) Configurar IP estatica"
    echo "  3) Configurar servidor DNS"
    echo "  4) Ejecutar pruebas de resolucion"
    echo "  5) Release / Renew (renovar IP)"
    echo "  6) Instalar herramientas DNS"
    echo "  0) Salir"
    echo ""
    read -rp "  Opcion: " opc

    case $opc in

# =========================================================
# 1) VERIFICAR RED
# =========================================================
    1)
        clear
        echo ""
        echo "  -- VERIFICACION DE RED --"
        echo ""

        echo "  Interfaz: $INTERFAZ"
        if ip link show "$INTERFAZ" &>/dev/null; then
            EST=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
            IP_C=$(ip -4 addr show "$INTERFAZ" | grep inet | awk '{print $2}' | head -1)
            msg_ok "$EST | $IP_C"

            CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
            if [[ -n "$CON" ]]; then
                MET=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)
                [[ "$MET" == "manual" ]] && msg_ok "IP estatica" || msg_warn "DHCP"
            fi
        else
            msg_err "interfaz no encontrada"
        fi

        echo ""
        echo "  Gateway:"
        GW=$(ip route | grep default | awk '{print $3}' | head -1)
        [[ -n "$GW" ]] && msg_ok "$GW" || msg_warn "sin gateway"

        echo ""
        echo "  DNS configurado:"
        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -n "$CON" ]]; then
            DNS_C=$(nmcli -g ipv4.dns connection show "$CON" 2>/dev/null)
            [[ -n "$DNS_C" ]] && msg_ok "$DNS_C" || msg_warn "usando defaults"
        fi

        echo ""
        echo "  resolv.conf:"
        cat /etc/resolv.conf 2>/dev/null | sed 's/^/    /'

        echo ""
        echo "  Herramientas:"
        for cmd in nslookup dig ping; do
            command -v "$cmd" &>/dev/null && msg_ok "$cmd disponible" || msg_err "$cmd no instalado"
        done

        pausar
        ;;

# =========================================================
# 2) IP ESTATICA
# =========================================================
    2)
        clear
        echo ""
        echo "  -- CONFIGURAR IP ESTATICA --"
        echo ""

        if ! ip link show "$INTERFAZ" &>/dev/null; then
            msg_err "Interfaz $INTERFAZ no existe."
            pausar
            continue
        fi

        msg_info "Interfaz: $INTERFAZ | IP actual: ${IP_CLIENTE:-N/A}"

        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -z "$CON" ]]; then
            CON=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        fi
        if [[ -z "$CON" ]]; then
            nmcli connection add type ethernet ifname "$INTERFAZ" con-name "cliente-${INTERFAZ}" 2>/dev/null
            CON="cliente-${INTERFAZ}"
        fi

        MET=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)
        if [[ "$MET" == "manual" ]]; then
            msg_ok "Ya tiene IP estatica."
            echo -e "  Reconfigurar? (s/n) [n]: \c"
            read -r resp
            [[ ! "$resp" =~ ^[sS]$ ]] && { pausar; continue; }
        fi

        echo ""
        while true; do
            read -rp "  IP [$IP_CLIENTE]: " IN_IP
            IN_IP="${IN_IP:-$IP_CLIENTE}"
            validar_ip "$IN_IP" && break
            msg_err "IP invalida."
        done

        PREF=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | head -1 | cut -d/ -f2)
        PREF="${PREF:-24}"
        read -rp "  Prefijo [$PREF]: " IN_P; IN_P="${IN_P:-$PREF}"

        GW=$(ip route | grep default | awk '{print $3}' | head -1)
        while true; do
            read -rp "  Gateway [$GW]: " IN_GW
            IN_GW="${IN_GW:-$GW}"
            validar_ip "$IN_GW" && break
            msg_err "IP invalida."
        done

        read -rp "  DNS primario (IP servidor DNS) [$IP_SERVIDOR_DNS]: " IN_D1
        IN_D1="${IN_D1:-$IP_SERVIDOR_DNS}"
        read -rp "  DNS secundario [8.8.8.8]: " IN_D2
        IN_D2="${IN_D2:-8.8.8.8}"

        nmcli connection modify "$CON" ipv4.addresses "${IN_IP}/${IN_P}"
        nmcli connection modify "$CON" ipv4.gateway "$IN_GW"
        nmcli connection modify "$CON" ipv4.dns "${IN_D1} ${IN_D2}"
        nmcli connection modify "$CON" ipv4.ignore-auto-dns yes
        nmcli connection modify "$CON" ipv4.method manual
        nmcli connection down "$CON" 2>/dev/null && nmcli connection up "$CON" 2>/dev/null
        sleep 3

        IP_CLIENTE="$IN_IP"
        IP_SERVIDOR_DNS="$IN_D1"
        msg_ok "IP configurada: $IP_CLIENTE/$IN_P | DNS: $IP_SERVIDOR_DNS"

        pausar
        ;;

# =========================================================
# 3) CONFIGURAR DNS
# =========================================================
    3)
        clear
        echo ""
        echo "  -- CONFIGURAR SERVIDOR DNS --"
        echo ""

        while true; do
            read -rp "  IP del servidor DNS: " IP_SERVIDOR_DNS
            validar_ip "$IP_SERVIDOR_DNS" && break
            msg_err "IP invalida."
        done

        read -rp "  DNS respaldo [8.8.8.8]: " DNS_BK
        DNS_BK="${DNS_BK:-8.8.8.8}"

        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        [[ -z "$CON" ]] && CON=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)

        if [[ -n "$CON" ]]; then
            nmcli connection modify "$CON" ipv4.dns "${IP_SERVIDOR_DNS} ${DNS_BK}"
            nmcli connection modify "$CON" ipv4.ignore-auto-dns yes
            nmcli connection down "$CON" 2>/dev/null && nmcli connection up "$CON" 2>/dev/null
            sleep 3
            msg_ok "DNS: primario=$IP_SERVIDOR_DNS | respaldo=$DNS_BK"
        else
            msg_warn "Sin conexion NM, editando resolv.conf..."
            echo "nameserver ${IP_SERVIDOR_DNS}" > /etc/resolv.conf
            echo "nameserver ${DNS_BK}" >> /etc/resolv.conf
            msg_ok "resolv.conf actualizado."
        fi

        echo ""
        echo "  resolv.conf actual:"
        cat /etc/resolv.conf 2>/dev/null | sed 's/^/    /'

        pausar
        ;;

# =========================================================
# 4) PRUEBAS DE RESOLUCION
# =========================================================
    4)
        clear
        echo ""
        echo "  -- PRUEBAS DE RESOLUCION --"
        echo ""

        if [[ -z "$IP_SERVIDOR_DNS" ]]; then
            while true; do
                read -rp "  IP del servidor DNS: " IP_SERVIDOR_DNS
                validar_ip "$IP_SERVIDOR_DNS" && break
                msg_err "IP invalida."
            done
        fi

        read -rp "  Dominio a probar [$DOMINIO_BASE]: " DOM
        DOM="${DOM:-$DOMINIO_BASE}"
        read -rp "  IP esperada (ENTER para omitir): " IP_ESP

        echo ""
        EVID="${EVIDENCIA_DIR}/pruebas_$(date +%Y%m%d_%H%M%S).txt"

        echo "=== REPORTE PRUEBAS DNS - $(date) ===" > "$EVID"
        echo "Servidor DNS: $IP_SERVIDOR_DNS | Dominio: $DOM" >> "$EVID"
        echo "IP esperada: ${IP_ESP:-N/A} | Cliente: ${IP_CLIENTE}" >> "$EVID"
        echo "" >> "$EVID"

        TOTAL=0; OK=0; FAIL=0

        # TEST 1: ping al servidor
        TOTAL=$((TOTAL+1))
        msg_info "Test 1: ping al servidor DNS ($IP_SERVIDOR_DNS)"
        echo "--- ping $IP_SERVIDOR_DNS ---" >> "$EVID"
        P1=$(ping -c 3 "$IP_SERVIDOR_DNS" 2>&1)
        echo "$P1" >> "$EVID"
        if echo "$P1" | grep -q " 0% packet loss\| 0.0% packet loss"; then
            msg_ok "servidor accesible"; OK=$((OK+1))
        else
            msg_err "no se alcanza el servidor"; FAIL=$((FAIL+1))
        fi

        # TEST 2: nslookup dominio
        TOTAL=$((TOTAL+1))
        msg_info "Test 2: nslookup $DOM @$IP_SERVIDOR_DNS"
        echo "--- nslookup $DOM ---" >> "$EVID"
        N1=$(nslookup "$DOM" "$IP_SERVIDOR_DNS" 2>&1)
        echo "$N1" >> "$EVID"
        if [[ -n "$IP_ESP" ]]; then
            echo "$N1" | grep -q "$IP_ESP" && { msg_ok "$DOM -> $IP_ESP"; OK=$((OK+1)); } || { msg_err "no coincide con $IP_ESP"; FAIL=$((FAIL+1)); }
        else
            echo "$N1" | grep -qE "Address:.*[0-9]+\.[0-9]+" && { msg_ok "resuelve"; OK=$((OK+1)); } || { msg_err "sin respuesta"; FAIL=$((FAIL+1)); }
        fi

        # TEST 3: nslookup www
        TOTAL=$((TOTAL+1))
        msg_info "Test 3: nslookup www.$DOM @$IP_SERVIDOR_DNS"
        echo "--- nslookup www.$DOM ---" >> "$EVID"
        N2=$(nslookup "www.${DOM}" "$IP_SERVIDOR_DNS" 2>&1)
        echo "$N2" >> "$EVID"
        echo "$N2" | grep -qE "canonical name|Address.*[0-9]+\.[0-9]+" && { msg_ok "resuelve"; OK=$((OK+1)); } || { msg_err "sin respuesta"; FAIL=$((FAIL+1)); }

        # TEST 4: dig dominio
        TOTAL=$((TOTAL+1))
        msg_info "Test 4: dig $DOM @$IP_SERVIDOR_DNS"
        echo "--- dig $DOM ---" >> "$EVID"
        D1=$(dig @"$IP_SERVIDOR_DNS" "$DOM" A 2>&1)
        echo "$D1" >> "$EVID"
        D1S=$(dig @"$IP_SERVIDOR_DNS" "$DOM" A +short 2>&1)
        [[ -n "$D1S" ]] && { msg_ok "$DOM -> $D1S"; OK=$((OK+1)); } || { msg_err "sin resultado"; FAIL=$((FAIL+1)); }

        # TEST 5: dig www
        TOTAL=$((TOTAL+1))
        msg_info "Test 5: dig www.$DOM @$IP_SERVIDOR_DNS"
        echo "--- dig www.$DOM ---" >> "$EVID"
        D2=$(dig @"$IP_SERVIDOR_DNS" "www.${DOM}" 2>&1)
        echo "$D2" >> "$EVID"
        echo "$D2" | grep -qE "ANSWER SECTION" && { msg_ok "resuelve"; OK=$((OK+1)); } || { msg_err "sin respuesta"; FAIL=$((FAIL+1)); }

        # TEST 6: ping dominio
        TOTAL=$((TOTAL+1))
        msg_info "Test 6: ping $DOM"
        echo "--- ping $DOM ---" >> "$EVID"
        P2=$(ping -c 2 "$DOM" 2>&1)
        echo "$P2" >> "$EVID"
        echo "$P2" | grep -q "bytes from" && { msg_ok "responde"; OK=$((OK+1)); } || { msg_warn "sin respuesta ICMP"; FAIL=$((FAIL+1)); }

        # TEST 7: ping www
        TOTAL=$((TOTAL+1))
        msg_info "Test 7: ping www.$DOM"
        echo "--- ping www.$DOM ---" >> "$EVID"
        P3=$(ping -c 2 "www.${DOM}" 2>&1)
        echo "$P3" >> "$EVID"
        echo "$P3" | grep -q "bytes from" && { msg_ok "responde"; OK=$((OK+1)); } || { msg_warn "sin respuesta ICMP"; FAIL=$((FAIL+1)); }

        # resumen
        PCT=0
        [[ $TOTAL -gt 0 ]] && PCT=$(( (OK * 100) / TOTAL ))

        echo "" >> "$EVID"
        echo "Resumen: $OK/$TOTAL ($PCT%)" >> "$EVID"

        echo ""
        echo "  ================================================"
        echo "  RESUMEN"
        echo "  Servidor:  $IP_SERVIDOR_DNS"
        echo "  Dominio:   $DOM"
        echo "  Exitosas:  $OK / $TOTAL ($PCT%)"
        echo "  Fallidas:  $FAIL"
        echo "  Evidencia: $(basename $EVID)"
        echo "  ================================================"

        pausar
        ;;

# =========================================================
# 5) RELEASE / RENEW
# =========================================================
    5)
        clear
        echo ""
        echo "  -- RELEASE / RENEW --"
        echo ""

        actualizar_ip
        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        MET=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)

        msg_info "Interfaz: $INTERFAZ | IP: $IP_CLIENTE | Metodo: $MET"
        echo ""

        if [[ "$MET" == "auto" ]]; then
            echo "  1) Release (liberar IP)"
            echo "  2) Renew (renovar IP)"
            echo "  3) Release + Renew"
            echo "  0) Volver"
            echo ""
            read -rp "  Opcion: " sub5

            case $sub5 in
                1)
                    msg_info "Liberando IP..."
                    dhclient -r "$INTERFAZ" 2>/dev/null || nmcli device disconnect "$INTERFAZ" 2>/dev/null
                    sleep 2
                    msg_ok "IP liberada."
                    ip -4 addr show "$INTERFAZ" | grep inet | sed 's/^/    /'
                    ;;
                2)
                    msg_info "Renovando IP..."
                    dhclient "$INTERFAZ" 2>/dev/null || nmcli connection up "$CON" 2>/dev/null
                    sleep 3
                    NIP=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
                    msg_ok "IP renovada: $NIP"
                    ;;
                3)
                    msg_info "Release..."
                    dhclient -r "$INTERFAZ" 2>/dev/null || nmcli device disconnect "$INTERFAZ" 2>/dev/null
                    sleep 2
                    msg_ok "Liberada."
                    msg_info "Renew..."
                    dhclient "$INTERFAZ" 2>/dev/null || nmcli connection up "$CON" 2>/dev/null
                    sleep 3
                    NIP=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
                    msg_ok "IP renovada: $NIP"
                    ;;
            esac
        else
            msg_warn "IP estatica, release/renew solo aplica con DHCP."
            echo ""
            read -rp "  Reiniciar la conexion? (s/n): " resp
            if [[ "$resp" =~ ^[sS]$ ]]; then
                nmcli connection down "$CON" 2>/dev/null && nmcli connection up "$CON" 2>/dev/null
                sleep 3
                NIP=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
                msg_ok "Reconectado: $NIP"
            fi
        fi

        pausar
        ;;

# =========================================================
# 6) INSTALAR HERRAMIENTAS
# =========================================================
    6)
        clear
        echo ""
        echo "  -- HERRAMIENTAS DNS --"
        echo ""

        FALTA=()
        for cmd in nslookup dig host; do
            command -v "$cmd" &>/dev/null && msg_ok "$cmd instalado" || { msg_err "$cmd no instalado"; FALTA+=("dnsutils"); }
        done
        command -v ping &>/dev/null && msg_ok "ping instalado" || { msg_err "ping no instalado"; FALTA+=("iputils-ping"); }
        command -v dhclient &>/dev/null && msg_ok "dhclient instalado" || { msg_warn "dhclient no instalado (opcional)"; FALTA+=("isc-dhcp-client"); }

        # quitar duplicados
        FALTA=($(echo "${FALTA[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

        if [[ ${#FALTA[@]} -gt 0 ]]; then
            echo ""
            msg_info "Paquetes faltantes: ${FALTA[*]}"
            read -rp "  Instalar? (s/n) [s]: " resp
            resp="${resp:-s}"
            if [[ "$resp" =~ ^[sS]$ ]]; then
                apt-get update -qq
                apt-get install -y "${FALTA[@]}" 2>&1 | tee -a "$LOG"
                echo ""
                msg_ok "Instalacion completa."
            fi
        else
            echo ""
            msg_ok "Todo instalado."
        fi

        pausar
        ;;

    0)
        echo ""
        echo "  Saliendo..."
        exit 0
        ;;

    *)
        msg_err "Opcion invalida."
        sleep 1
        ;;
    esac
done