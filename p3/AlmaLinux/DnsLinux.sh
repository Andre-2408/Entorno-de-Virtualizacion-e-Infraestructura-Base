#!/bin/bash

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ── Variables globales ───────────────────────────────────────────────────────
DOMINIO_BASE="reprobados.com"
INTERFAZ="ens224"
NAMED_CONF="/etc/named.conf"
ZONA_DIR="/var/named"
EVIDENCIA_DIR="/root/evidencias_dns"
LOG_FILE="/var/log/dns_script_$(date +%Y%m%d).log"
IP_SERVIDOR=""
IP_CLIENTE=""

# ── Funciones de utilidad ────────────────────────────────────────────────────
log()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
exito() { echo -e "${GREEN}  [✔] $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}  [✘] $1${NC}" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYAN}  [ℹ] $1${NC}" | tee -a "$LOG_FILE"; }
aviso() { echo -e "${YELLOW}  [⚠] $1${NC}" | tee -a "$LOG_FILE"; }

separador() {
    echo -e "${CYAN}  ──────────────────────────────────────────────────────────${NC}"
}

pausar() {
    echo ""
    read -rp "  Presione ENTER para continuar..." _
}

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Este script debe ejecutarse como root (sudo)."
        exit 1
    fi
}

validar_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octetos <<< "$ip"
        for octeto in "${octetos[@]}"; do
            if (( octeto < 0 || octeto > 255 )); then return 1; fi
        done
        return 0
    fi
    return 1
}

obtener_ip_servidor() {
    IP_SERVIDOR=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
}

# ══════════════════════════════════════════════════════════════════════════════
#  BANNER Y MENÚ PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║         SERVIDOR DNS (BIND) - AlmaLinux                    ║"
    echo "  ║         Dominio base: reprobados.com                       ║"
    echo "  ║         Interfaz: ens224                                   ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

menu_principal() {
    while true; do
        banner
        obtener_ip_servidor

        # Estado rápido
        if rpm -q bind &>/dev/null; then
            ESTADO_PKG="${GREEN}Instalado${NC}"
        else
            ESTADO_PKG="${RED}No instalado${NC}"
        fi

        if systemctl is-active --quiet named 2>/dev/null; then
            ESTADO_SVC="${GREEN}Activo${NC}"
        else
            ESTADO_SVC="${RED}Inactivo${NC}"
        fi

        echo -e "  ${BOLD}Estado:${NC} BIND: $ESTADO_PKG | Servicio: $ESTADO_SVC | IP: ${IP_SERVIDOR:-Sin configurar}"
        separador
        echo ""
        echo -e "  ${BOLD}Menú Principal${NC}"
        echo ""
        echo -e "    ${CYAN}1)${NC} Verificar instalación"
        echo -e "    ${CYAN}2)${NC} Instalar DNS"
        echo -e "    ${CYAN}3)${NC} Configurar (zona ${DOMINIO_BASE})"
        echo -e "    ${CYAN}4)${NC} Reconfigurar (IP estática / zona)"
        echo -e "    ${CYAN}5)${NC} Administrar dominios (ABC)"
        echo -e "    ${CYAN}6)${NC} Validar y probar resolución"
        echo -e "    ${CYAN}0)${NC} Salir"
        echo ""
        read -rp "  Seleccione una opción: " opcion

        case $opcion in
            1) opcion_verificar ;;
            2) opcion_instalar ;;
            3) opcion_configurar ;;
            4) opcion_reconfigurar ;;
            5) menu_dominios ;;
            6) opcion_validar ;;
            0) echo -e "\n  ${GREEN}Saliendo...${NC}\n"; exit 0 ;;
            *) error "Opción inválida." ; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  1) VERIFICAR INSTALACIÓN
# ══════════════════════════════════════════════════════════════════════════════
opcion_verificar() {
    banner
    echo -e "  ${BOLD}═══ VERIFICACIÓN DE INSTALACIÓN ═══${NC}\n"

    # Paquetes
    info "Paquetes:"
    for paquete in bind bind-utils; do
        if rpm -q "$paquete" &>/dev/null; then
            exito "$paquete: $(rpm -q $paquete)"
        else
            error "$paquete: No instalado"
        fi
    done

    # Servicio
    echo ""
    info "Servicio named:"
    if systemctl is-active --quiet named; then
        exito "Estado: ACTIVO"
        systemctl status named --no-pager -l 2>/dev/null | head -8 | while read -r line; do echo "    $line"; done
    else
        aviso "Estado: INACTIVO"
    fi

    # Interfaz
    echo ""
    info "Interfaz $INTERFAZ:"
    if ip link show "$INTERFAZ" &>/dev/null; then
        ESTADO_LINK=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
        IP_ACTUAL=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
        exito "$INTERFAZ: $ESTADO_LINK | IP: ${IP_ACTUAL:-Sin IP}"

        CONEXION=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -n "$CONEXION" ]]; then
            METODO=$(nmcli -g ipv4.method connection show "$CONEXION" 2>/dev/null)
            if [[ "$METODO" == "manual" ]]; then
                exito "Tipo: IP Estática"
            else
                aviso "Tipo: DHCP (se requiere IP fija)"
            fi
        fi
    else
        error "$INTERFAZ: NO ENCONTRADA"
    fi

    # Zonas
    echo ""
    info "Zonas configuradas:"
    if [[ -f "$NAMED_CONF" ]]; then
        ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')
        if [[ -n "$ZONAS" ]]; then
            while IFS= read -r zona; do exito "  $zona"; done <<< "$ZONAS"
        else
            aviso "  No hay zonas personalizadas."
        fi
    fi

    # Firewall
    echo ""
    info "Firewall:"
    if systemctl is-active --quiet firewalld; then
        if firewall-cmd --list-services --permanent 2>/dev/null | grep -q "dns"; then
            exito "Puerto 53 (DNS): Permitido"
        else
            aviso "Puerto 53 (DNS): NO permitido"
        fi
    else
        aviso "firewalld no activo."
    fi

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  2) INSTALAR DNS (IDEMPOTENTE)
# ══════════════════════════════════════════════════════════════════════════════
opcion_instalar() {
    banner
    echo -e "  ${BOLD}═══ INSTALACIÓN DE DNS (BIND) ═══${NC}\n"

    if rpm -q bind bind-utils &>/dev/null; then
        exito "BIND ya está instalado. No se requiere reinstalación."
        echo ""
        info "Paquetes:"
        rpm -q bind bind-utils | while read -r line; do echo "    $line"; done

        if systemctl is-active --quiet named; then
            exito "Servicio named ya activo."
        fi
        pausar
        return
    fi

    info "Instalando paquetes: bind, bind-utils..."
    echo ""
    dnf install -y bind bind-utils 2>&1 | tee -a "$LOG_FILE"

    if [[ $? -eq 0 ]]; then
        echo ""
        exito "Paquetes instalados correctamente."
        systemctl enable named 2>&1 | tee -a "$LOG_FILE"
        exito "Servicio named habilitado."
        echo ""
        info "Use la opción 3 (Configurar) para establecer la zona DNS."
    else
        echo ""
        error "Error durante la instalación."
    fi

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  FUNCIONES AUXILIARES
# ══════════════════════════════════════════════════════════════════════════════

# ── Configurar IP estática ───────────────────────────────────────────────────
configurar_ip_estatica() {
    info "Verificando IP estática en $INTERFAZ..."

    if ! ip link show "$INTERFAZ" &>/dev/null; then
        error "La interfaz $INTERFAZ no existe."
        ip -br link show | grep -v "lo"
        return 1
    fi

    # Activar si está caída
    ESTADO_LINK=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
    if [[ "$ESTADO_LINK" != "UP" ]]; then
        aviso "Interfaz $INTERFAZ inactiva. Activando..."
        nmcli device connect "$INTERFAZ" 2>/dev/null || ip link set "$INTERFAZ" up
        sleep 2
    fi

    # Conexión de NetworkManager
    CONEXION=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    if [[ -z "$CONEXION" ]]; then
        aviso "Creando conexión para $INTERFAZ..."
        nmcli connection add type ethernet ifname "$INTERFAZ" con-name "red-interna-${INTERFAZ}" 2>/dev/null
        CONEXION="red-interna-${INTERFAZ}"
    fi

    METODO=$(nmcli -g ipv4.method connection show "$CONEXION" 2>/dev/null)

    if [[ "$METODO" == "manual" ]]; then
        IP_SERVIDOR=$(nmcli -g ipv4.addresses connection show "$CONEXION" | head -1 | cut -d/ -f1)
        exito "IP estática ya configurada: $IP_SERVIDOR"
        return 0
    fi

    aviso "La interfaz $INTERFAZ está en DHCP."
    IP_ACTUAL=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    echo -e "\n  ${YELLOW}Se requiere IP estática para el servidor DNS.${NC}\n"

    while true; do
        read -rp "  Dirección IP [${IP_ACTUAL}]: " INPUT_IP
        INPUT_IP="${INPUT_IP:-$IP_ACTUAL}"
        if validar_ip "$INPUT_IP"; then break; fi
        error "IP inválida."
    done

    PREFIJO_ACTUAL=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | head -1 | cut -d/ -f2)
    PREFIJO_ACTUAL="${PREFIJO_ACTUAL:-24}"
    read -rp "  Prefijo CIDR [${PREFIJO_ACTUAL}]: " INPUT_PREFIJO
    INPUT_PREFIJO="${INPUT_PREFIJO:-$PREFIJO_ACTUAL}"

    GW_ACTUAL=$(ip route | grep default | awk '{print $3}' | head -1)
    while true; do
        read -rp "  Gateway [${GW_ACTUAL}]: " INPUT_GW
        INPUT_GW="${INPUT_GW:-$GW_ACTUAL}"
        if validar_ip "$INPUT_GW"; then break; fi
        error "Gateway inválido."
    done

    read -rp "  DNS de respaldo [8.8.8.8]: " INPUT_DNS
    INPUT_DNS="${INPUT_DNS:-8.8.8.8}"

    info "Aplicando configuración..."
    nmcli connection modify "$CONEXION" ipv4.addresses "${INPUT_IP}/${INPUT_PREFIJO}"
    nmcli connection modify "$CONEXION" ipv4.gateway "$INPUT_GW"
    nmcli connection modify "$CONEXION" ipv4.dns "127.0.0.1 ${INPUT_DNS}"
    nmcli connection modify "$CONEXION" ipv4.method manual
    nmcli connection down "$CONEXION" 2>/dev/null && nmcli connection up "$CONEXION" 2>/dev/null
    sleep 3

    IP_SERVIDOR="$INPUT_IP"
    exito "IP estática configurada: $IP_SERVIDOR/$INPUT_PREFIJO"
}

# ── Crear archivo de zona ────────────────────────────────────────────────────
crear_zona_archivo() {
    local dominio="$1"
    local ip_destino="$2"
    local zona_file="${ZONA_DIR}/db.${dominio}"
    local serial=$(date +%Y%m%d%H)

    obtener_ip_servidor

    cat > "$zona_file" <<EOF
; Archivo de zona: ${dominio}
; Generado: $(date '+%Y-%m-%d %H:%M:%S')
\$TTL    86400
@       IN      SOA     ns1.${dominio}. admin.${dominio}. (
                        ${serial}   ; Serial
                        3600        ; Refresh
                        1800        ; Retry
                        604800      ; Expire
                        86400       ; Minimum TTL
                        )

; Registros NS
@       IN      NS      ns1.${dominio}.

; Servidor de nombres
ns1     IN      A       ${IP_SERVIDOR}

; Dominio raíz
@       IN      A       ${ip_destino}

; Subdominio www
www     IN      CNAME   ${dominio}.
EOF

    chown named:named "$zona_file"
    chmod 640 "$zona_file"
    exito "Archivo de zona creado: $zona_file"
}

# ── Incrementar serial ───────────────────────────────────────────────────────
incrementar_serial() {
    local archivo="$1"
    local serial_actual=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$archivo" 2>/dev/null)
    if [[ -n "$serial_actual" ]]; then
        local nuevo_serial=$((serial_actual + 1))
        sed -i "s/${serial_actual}\(\s*;\s*Serial\)/${nuevo_serial}\1/" "$archivo"
    fi
}

# ── Recargar zona ───────────────────────────────────────────────────────────
recargar_zona() {
    local dominio="$1"
    local archivo="$2"

    named-checkzone "$dominio" "$archivo" 2>&1 | tee -a "$LOG_FILE"
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        exito "Zona válida."
        systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
        sleep 1
        if systemctl is-active --quiet named; then
            exito "Servicio recargado."
        fi
    else
        error "Error en la zona. Servicio no recargado."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  3) CONFIGURAR (IP ESTÁTICA + ZONA BASE)
# ══════════════════════════════════════════════════════════════════════════════
opcion_configurar() {
    banner
    echo -e "  ${BOLD}═══ CONFIGURACIÓN INICIAL DEL SERVIDOR DNS ═══${NC}\n"

    if ! rpm -q bind &>/dev/null; then
        error "BIND no está instalado. Ejecute primero la opción 2."
        pausar
        return
    fi

    # Paso 1: IP estática
    configurar_ip_estatica

    # Paso 2: IP del cliente
    echo ""
    info "Configuración de registros DNS"
    echo -e "  ${YELLOW}Los registros A apuntarán a la IP de la máquina cliente.${NC}\n"

    while true; do
        read -rp "  IP de la máquina cliente: " IP_CLIENTE
        if validar_ip "$IP_CLIENTE"; then
            exito "IP del cliente: $IP_CLIENTE"
            break
        fi
        error "IP inválida."
    done

    # Paso 3: named.conf
    echo ""
    info "Configurando named.conf..."
    cp "$NAMED_CONF" "${NAMED_CONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

    sed -i 's/listen-on port 53 {.*};/listen-on port 53 { any; };/' "$NAMED_CONF"
    sed -i 's/listen-on-v6 port 53 {.*};/listen-on-v6 port 53 { none; };/' "$NAMED_CONF"
    sed -i 's/allow-query {.*};/allow-query { any; };/' "$NAMED_CONF"

    if grep -q "zone \"${DOMINIO_BASE}\"" "$NAMED_CONF" 2>/dev/null; then
        aviso "La zona ${DOMINIO_BASE} ya existe. Se actualizará."
        sed -i "/\/\/ ── Zona.*${DOMINIO_BASE}/d" "$NAMED_CONF"
        sed -i "/zone \"${DOMINIO_BASE}\"/,/^};/d" "$NAMED_CONF"
    fi

    cat >> "$NAMED_CONF" <<EOF

// ── Zona: ${DOMINIO_BASE} ──
zone "${DOMINIO_BASE}" IN {
    type master;
    file "${ZONA_DIR}/db.${DOMINIO_BASE}";
    allow-update { none; };
};
EOF
    exito "Zona ${DOMINIO_BASE} agregada a named.conf"

    # Paso 4: Archivo de zona
    crear_zona_archivo "$DOMINIO_BASE" "$IP_CLIENTE"

    # Paso 5: SELinux
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        info "Configurando SELinux..."
        restorecon -Rv /var/named/ 2>&1 | tee -a "$LOG_FILE"
        setsebool -P named_write_master_zones 1 2>/dev/null
        exito "SELinux configurado."
    fi

    # Paso 6: Firewall
    info "Configurando firewall..."
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=dns 2>/dev/null
        firewall-cmd --permanent --add-port=53/tcp 2>/dev/null
        firewall-cmd --permanent --add-port=53/udp 2>/dev/null
        firewall-cmd --reload 2>/dev/null
        exito "Firewall configurado (puerto 53 TCP/UDP)."
    else
        aviso "firewalld no activo."
    fi

    # Paso 7: Validar
    echo ""
    info "Validando configuración..."
    named-checkconf "$NAMED_CONF" 2>&1
    if [[ $? -eq 0 ]]; then
        exito "named-checkconf: OK"
    else
        error "named-checkconf: Error de sintaxis"
        pausar
        return
    fi

    named-checkzone "$DOMINIO_BASE" "${ZONA_DIR}/db.${DOMINIO_BASE}" 2>&1
    if [[ $? -eq 0 ]]; then
        exito "named-checkzone: OK"
    else
        error "named-checkzone: Error"
        pausar
        return
    fi

    # Paso 8: Iniciar
    echo ""
    info "Iniciando servicio named..."
    systemctl restart named 2>&1
    sleep 2

    if systemctl is-active --quiet named; then
        exito "Servicio named: ACTIVO"
    else
        error "El servicio no pudo iniciar."
    fi

    # Resumen
    echo ""
    separador
    echo -e "  ${GREEN}${BOLD}Configuración completada${NC}"
    echo -e "    Dominio:      ${DOMINIO_BASE}"
    echo -e "    IP Servidor:  ${IP_SERVIDOR}"
    echo -e "    IP Cliente:   ${IP_CLIENTE}"
    echo -e "    ${DOMINIO_BASE}      → A     ${IP_CLIENTE}"
    echo -e "    www.${DOMINIO_BASE}  → CNAME ${DOMINIO_BASE}"
    echo -e "    ns1.${DOMINIO_BASE}  → A     ${IP_SERVIDOR}"
    separador
    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  4) RECONFIGURAR
# ══════════════════════════════════════════════════════════════════════════════
opcion_reconfigurar() {
    banner
    echo -e "  ${BOLD}═══ RECONFIGURAR ═══${NC}\n"
    echo -e "    ${CYAN}1)${NC} Reconfigurar IP estática ($INTERFAZ)"
    echo -e "    ${CYAN}2)${NC} Reconfigurar zona ${DOMINIO_BASE} (nueva IP cliente)"
    echo -e "    ${CYAN}3)${NC} Reiniciar servicio named"
    echo -e "    ${CYAN}0)${NC} Volver"
    echo ""
    read -rp "  Seleccione: " sub

    case $sub in
        1)
            banner
            echo -e "  ${BOLD}═══ RECONFIGURAR IP ESTÁTICA ═══${NC}\n"

            # Forzar reconfiguración: poner en auto temporalmente para que pida datos
            CONEXION=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
            if [[ -n "$CONEXION" ]]; then
                echo -e "  ${YELLOW}Ingrese los nuevos datos de red:${NC}\n"

                while true; do
                    read -rp "  Nueva dirección IP: " INPUT_IP
                    if validar_ip "$INPUT_IP"; then break; fi
                    error "IP inválida."
                done

                read -rp "  Prefijo CIDR [24]: " INPUT_PREFIJO
                INPUT_PREFIJO="${INPUT_PREFIJO:-24}"

                while true; do
                    read -rp "  Gateway: " INPUT_GW
                    if validar_ip "$INPUT_GW"; then break; fi
                    error "Gateway inválido."
                done

                read -rp "  DNS de respaldo [8.8.8.8]: " INPUT_DNS
                INPUT_DNS="${INPUT_DNS:-8.8.8.8}"

                nmcli connection modify "$CONEXION" ipv4.addresses "${INPUT_IP}/${INPUT_PREFIJO}"
                nmcli connection modify "$CONEXION" ipv4.gateway "$INPUT_GW"
                nmcli connection modify "$CONEXION" ipv4.dns "127.0.0.1 ${INPUT_DNS}"
                nmcli connection modify "$CONEXION" ipv4.method manual
                nmcli connection down "$CONEXION" 2>/dev/null && nmcli connection up "$CONEXION" 2>/dev/null
                sleep 3

                IP_SERVIDOR="$INPUT_IP"
                exito "IP reconfigurada: $IP_SERVIDOR/$INPUT_PREFIJO"

                if systemctl is-active --quiet named; then
                    info "Reiniciando named..."
                    systemctl restart named
                    exito "Servicio reiniciado."
                fi
            else
                error "No se encontró conexión para $INTERFAZ."
            fi
            pausar
            ;;
        2)
            banner
            echo -e "  ${BOLD}═══ RECONFIGURAR ZONA ${DOMINIO_BASE} ═══${NC}\n"
            obtener_ip_servidor
            if [[ -z "$IP_SERVIDOR" ]]; then
                error "No se detectó IP en $INTERFAZ."
                pausar
                return
            fi

            while true; do
                read -rp "  Nueva IP del cliente para ${DOMINIO_BASE}: " IP_CLIENTE
                if validar_ip "$IP_CLIENTE"; then break; fi
                error "IP inválida."
            done

            crear_zona_archivo "$DOMINIO_BASE" "$IP_CLIENTE"
            recargar_zona "$DOMINIO_BASE" "${ZONA_DIR}/db.${DOMINIO_BASE}"
            pausar
            ;;
        3)
            info "Reiniciando servicio named..."
            systemctl restart named 2>&1
            sleep 2
            if systemctl is-active --quiet named; then
                exito "Servicio named: ACTIVO"
            else
                error "No pudo iniciar."
                journalctl -u named --no-pager -n 10
            fi
            pausar
            ;;
        0) return ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  5) ADMINISTRAR DOMINIOS - ABC (Alta, Baja, Consulta/Configurar)
# ══════════════════════════════════════════════════════════════════════════════
menu_dominios() {
    while true; do
        banner
        echo -e "  ${BOLD}═══ ADMINISTRACIÓN DE DOMINIOS (ABC) ═══${NC}"
        echo -e "  ${MAGENTA}  Convertir dominio → IP → Comunicaciones entre IP${NC}\n"
        echo -e "    ${CYAN}1)${NC} Consultar  - Listar dominios y sus registros"
        echo -e "    ${CYAN}2)${NC} Agregar    - Crear nueva zona de dominio"
        echo -e "    ${CYAN}3)${NC} Configurar - Editar registros de un dominio"
        echo -e "    ${CYAN}4)${NC} Eliminar   - Quitar zona de dominio"
        echo -e "    ${CYAN}0)${NC} Volver al menú principal"
        echo ""
        read -rp "  Seleccione: " sub

        case $sub in
            1) dominio_consultar ;;
            2) dominio_agregar ;;
            3) dominio_configurar ;;
            4) dominio_eliminar ;;
            0) return ;;
            *) error "Opción inválida." ; sleep 1 ;;
        esac
    done
}

# ── CONSULTAR ────────────────────────────────────────────────────────────────
dominio_consultar() {
    banner
    echo -e "  ${BOLD}═══ CONSULTAR DOMINIOS ═══${NC}\n"

    ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')

    if [[ -z "$ZONAS" ]]; then
        aviso "No hay zonas personalizadas configuradas."
        pausar
        return
    fi

    NUM=1
    while IFS= read -r zona; do
        ZONA_FILE="${ZONA_DIR}/db.${zona}"
        echo -e "  ${GREEN}${BOLD}[$NUM] ${zona}${NC}"

        if [[ -f "$ZONA_FILE" ]]; then
            echo -e "      Archivo: $ZONA_FILE"

            # Registros A
            REGISTROS_A=$(grep -E "IN\s+A\s+" "$ZONA_FILE" | grep -v "^\s*;")
            if [[ -n "$REGISTROS_A" ]]; then
                echo -e "      ${CYAN}Registros A:${NC}"
                while IFS= read -r reg; do
                    NOMBRE=$(echo "$reg" | awk '{print $1}')
                    IP_REG=$(echo "$reg" | awk '{print $NF}')
                    if [[ "$NOMBRE" == "@" ]]; then
                        echo -e "        ${zona} → ${IP_REG}"
                    else
                        echo -e "        ${NOMBRE}.${zona} → ${IP_REG}"
                    fi
                done <<< "$REGISTROS_A"
            fi

            # Registros CNAME
            REGISTROS_CNAME=$(grep -E "IN\s+CNAME\s+" "$ZONA_FILE" | grep -v "^\s*;")
            if [[ -n "$REGISTROS_CNAME" ]]; then
                echo -e "      ${CYAN}Registros CNAME:${NC}"
                while IFS= read -r reg; do
                    NOMBRE=$(echo "$reg" | awk '{print $1}')
                    ALIAS=$(echo "$reg" | awk '{print $NF}')
                    echo -e "        ${NOMBRE}.${zona} → ${ALIAS}"
                done <<< "$REGISTROS_CNAME"
            fi
        else
            aviso "      Archivo de zona no encontrado."
        fi
        echo ""
        NUM=$((NUM + 1))
    done <<< "$ZONAS"

    pausar
}

# ── AGREGAR ──────────────────────────────────────────────────────────────────
dominio_agregar() {
    banner
    echo -e "  ${BOLD}═══ AGREGAR NUEVO DOMINIO ═══${NC}\n"

    obtener_ip_servidor
    if [[ -z "$IP_SERVIDOR" ]]; then
        error "No se detectó IP en $INTERFAZ. Configure primero."
        pausar
        return
    fi

    read -rp "  Nombre del dominio (ej: midominio.com): " NUEVO_DOMINIO

    if [[ -z "$NUEVO_DOMINIO" || ! "$NUEVO_DOMINIO" =~ \. ]]; then
        error "Dominio inválido. Debe contener al menos un punto."
        pausar
        return
    fi

    if grep -q "zone \"${NUEVO_DOMINIO}\"" "$NAMED_CONF" 2>/dev/null; then
        error "La zona '${NUEVO_DOMINIO}' ya existe. Use 'Configurar' para editarla."
        pausar
        return
    fi

    while true; do
        read -rp "  IP a la que resolverá ${NUEVO_DOMINIO}: " IP_DESTINO
        if validar_ip "$IP_DESTINO"; then break; fi
        error "IP inválida."
    done

    echo ""
    info "Creando zona para ${NUEVO_DOMINIO}..."

    cat >> "$NAMED_CONF" <<EOF

// ── Zona: ${NUEVO_DOMINIO} ──
zone "${NUEVO_DOMINIO}" IN {
    type master;
    file "${ZONA_DIR}/db.${NUEVO_DOMINIO}";
    allow-update { none; };
};
EOF

    crear_zona_archivo "$NUEVO_DOMINIO" "$IP_DESTINO"

    # Validar
    named-checkconf "$NAMED_CONF" 2>&1
    if [[ $? -ne 0 ]]; then
        error "Error de sintaxis en named.conf."
        pausar
        return
    fi
    exito "named-checkconf: OK"

    named-checkzone "$NUEVO_DOMINIO" "${ZONA_DIR}/db.${NUEVO_DOMINIO}" 2>&1
    if [[ $? -ne 0 ]]; then
        error "Error en archivo de zona."
        pausar
        return
    fi
    exito "named-checkzone: OK"

    systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
    sleep 1

    if systemctl is-active --quiet named; then
        exito "Dominio ${NUEVO_DOMINIO} agregado correctamente."
    else
        error "Error al recargar el servicio."
    fi

    echo ""
    separador
    echo -e "  ${GREEN}Registros creados:${NC}"
    echo -e "    ${NUEVO_DOMINIO}      → A     ${IP_DESTINO}"
    echo -e "    www.${NUEVO_DOMINIO}  → CNAME ${NUEVO_DOMINIO}"
    echo -e "    ns1.${NUEVO_DOMINIO}  → A     ${IP_SERVIDOR}"
    separador

    pausar
}

# ── CONFIGURAR REGISTROS ─────────────────────────────────────────────────────
dominio_configurar() {
    banner
    echo -e "  ${BOLD}═══ CONFIGURAR REGISTROS DE DOMINIO ═══${NC}\n"

    ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')

    if [[ -z "$ZONAS" ]]; then
        aviso "No hay zonas configuradas."
        pausar
        return
    fi

    info "Zonas disponibles:"
    NUM=1
    declare -A ZONA_MAP
    while IFS= read -r zona; do
        echo -e "    ${CYAN}${NUM})${NC} ${zona}"
        ZONA_MAP[$NUM]="$zona"
        NUM=$((NUM + 1))
    done <<< "$ZONAS"

    echo ""
    read -rp "  Seleccione zona (número): " SEL
    ZONA_SEL="${ZONA_MAP[$SEL]}"

    if [[ -z "$ZONA_SEL" ]]; then
        error "Selección inválida."
        pausar
        return
    fi

    ZONA_FILE="${ZONA_DIR}/db.${ZONA_SEL}"
    if [[ ! -f "$ZONA_FILE" ]]; then
        error "Archivo de zona no encontrado: $ZONA_FILE"
        pausar
        return
    fi

    while true; do
        banner
        echo -e "  ${BOLD}═══ Editando: ${ZONA_SEL} ═══${NC}\n"

        info "Registros actuales:"
        grep -E "IN\s+(A|CNAME)\s+" "$ZONA_FILE" | grep -v "^\s*;" | while IFS= read -r reg; do
            echo -e "    $reg"
        done

        echo ""
        echo -e "    ${CYAN}1)${NC} Agregar registro A"
        echo -e "    ${CYAN}2)${NC} Agregar registro CNAME"
        echo -e "    ${CYAN}3)${NC} Eliminar un registro"
        echo -e "    ${CYAN}4)${NC} Cambiar IP del dominio raíz (@)"
        echo -e "    ${CYAN}0)${NC} Volver"
        echo ""
        read -rp "  Seleccione: " accion

        case $accion in
            1)
                read -rp "  Nombre del subdominio (ej: ftp, mail): " SUBDOM
                [[ -z "$SUBDOM" ]] && { error "Nombre vacío."; sleep 1; continue; }

                if grep -qE "^${SUBDOM}\s+IN\s+A\s+" "$ZONA_FILE"; then
                    aviso "Registro '${SUBDOM}' ya existe. Se actualizará."
                    sed -i "/^${SUBDOM}\s\+IN\s\+A\s/d" "$ZONA_FILE"
                fi

                while true; do
                    read -rp "  IP para ${SUBDOM}.${ZONA_SEL}: " IP_SUB
                    if validar_ip "$IP_SUB"; then break; fi
                    error "IP inválida."
                done

                echo "${SUBDOM}     IN      A       ${IP_SUB}" >> "$ZONA_FILE"
                incrementar_serial "$ZONA_FILE"
                exito "Registro A: ${SUBDOM}.${ZONA_SEL} → ${IP_SUB}"
                recargar_zona "$ZONA_SEL" "$ZONA_FILE"
                sleep 2
                ;;
            2)
                read -rp "  Nombre del alias (ej: correo): " ALIAS_NAME
                [[ -z "$ALIAS_NAME" ]] && { error "Nombre vacío."; sleep 1; continue; }

                read -rp "  Apunta a (ej: mail.${ZONA_SEL}): " ALIAS_TARGET
                [[ -z "$ALIAS_TARGET" ]] && { error "Destino vacío."; sleep 1; continue; }

                [[ ! "$ALIAS_TARGET" =~ \.$ ]] && ALIAS_TARGET="${ALIAS_TARGET}."

                if grep -qE "^${ALIAS_NAME}\s+IN\s+CNAME\s+" "$ZONA_FILE"; then
                    aviso "CNAME '${ALIAS_NAME}' ya existe. Se actualizará."
                    sed -i "/^${ALIAS_NAME}\s\+IN\s\+CNAME\s/d" "$ZONA_FILE"
                fi

                echo "${ALIAS_NAME}     IN      CNAME   ${ALIAS_TARGET}" >> "$ZONA_FILE"
                incrementar_serial "$ZONA_FILE"
                exito "CNAME: ${ALIAS_NAME}.${ZONA_SEL} → ${ALIAS_TARGET}"
                recargar_zona "$ZONA_SEL" "$ZONA_FILE"
                sleep 2
                ;;
            3)
                echo ""
                info "Registros eliminables:"
                grep -E "IN\s+(A|CNAME)\s+" "$ZONA_FILE" | grep -v "^\s*;" | grep -v "SOA" | while IFS= read -r reg; do
                    NOMBRE=$(echo "$reg" | awk '{print $1}')
                    echo -e "    → $NOMBRE"
                done
                echo ""
                read -rp "  Nombre del registro a eliminar: " REG_DEL
                [[ -z "$REG_DEL" ]] && { error "Nombre vacío."; sleep 1; continue; }

                if grep -qE "^${REG_DEL}\s+IN\s+" "$ZONA_FILE"; then
                    sed -i "/^${REG_DEL}\s\+IN\s/d" "$ZONA_FILE"
                    incrementar_serial "$ZONA_FILE"
                    exito "Registro '${REG_DEL}' eliminado."
                    recargar_zona "$ZONA_SEL" "$ZONA_FILE"
                else
                    error "No se encontró '${REG_DEL}'."
                fi
                sleep 2
                ;;
            4)
                while true; do
                    read -rp "  Nueva IP para ${ZONA_SEL} (@): " NUEVA_IP
                    if validar_ip "$NUEVA_IP"; then break; fi
                    error "IP inválida."
                done

                # Reemplazar registro A del @
                sed -i "/^@\s\+IN\s\+A\s/c\\@       IN      A       ${NUEVA_IP}" "$ZONA_FILE"
                incrementar_serial "$ZONA_FILE"
                exito "IP raíz actualizada a ${NUEVA_IP}"
                recargar_zona "$ZONA_SEL" "$ZONA_FILE"
                sleep 2
                ;;
            0) break ;;
            *) error "Opción inválida." ; sleep 1 ;;
        esac
    done
}

# ── ELIMINAR ZONA ────────────────────────────────────────────────────────────
dominio_eliminar() {
    banner
    echo -e "  ${BOLD}═══ ELIMINAR DOMINIO ═══${NC}\n"

    ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')

    if [[ -z "$ZONAS" ]]; then
        aviso "No hay zonas para eliminar."
        pausar
        return
    fi

    info "Zonas disponibles:"
    NUM=1
    declare -A ZONA_MAP
    while IFS= read -r zona; do
        echo -e "    ${CYAN}${NUM})${NC} ${zona}"
        ZONA_MAP[$NUM]="$zona"
        NUM=$((NUM + 1))
    done <<< "$ZONAS"

    echo ""
    read -rp "  Seleccione zona a eliminar (número): " SEL
    ZONA_DEL="${ZONA_MAP[$SEL]}"

    if [[ -z "$ZONA_DEL" ]]; then
        error "Selección inválida."
        pausar
        return
    fi

    echo -e "\n  ${RED}${BOLD}¿Eliminar la zona '${ZONA_DEL}'?${NC}"
    read -rp "  Escriba 'SI' para confirmar: " CONFIRMA

    if [[ "$CONFIRMA" != "SI" ]]; then
        info "Cancelado."
        pausar
        return
    fi

    sed -i "/\/\/ ── Zona.*${ZONA_DEL}/d" "$NAMED_CONF"
    sed -i "/zone \"${ZONA_DEL}\"/,/^};/d" "$NAMED_CONF"

    ZONA_FILE="${ZONA_DIR}/db.${ZONA_DEL}"
    [[ -f "$ZONA_FILE" ]] && rm -f "$ZONA_FILE" && exito "Archivo eliminado: $ZONA_FILE"

    named-checkconf "$NAMED_CONF" 2>&1
    if [[ $? -eq 0 ]]; then
        systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
        sleep 1
        exito "Zona '${ZONA_DEL}' eliminada. Servicio recargado."
    else
        error "Error de sintaxis tras eliminar."
    fi

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  6) VALIDAR Y PROBAR RESOLUCIÓN
# ══════════════════════════════════════════════════════════════════════════════
opcion_validar() {
    banner
    echo -e "  ${BOLD}═══ VALIDACIÓN Y PRUEBAS DE RESOLUCIÓN ═══${NC}\n"

    mkdir -p "$EVIDENCIA_DIR"
    EVIDENCIA_FILE="${EVIDENCIA_DIR}/validacion_$(date +%Y%m%d_%H%M%S).txt"

    cat > "$EVIDENCIA_FILE" <<EOF
==============================================================================
  REPORTE DE VALIDACIÓN DNS - AlmaLinux
  Fecha:        $(date '+%Y-%m-%d %H:%M:%S')
  Hostname:     $(hostname)
  IP Servidor:  ${IP_SERVIDOR}
==============================================================================

EOF

    # Validar sintaxis
    info "Verificación de sintaxis"
    separador

    echo "--- named-checkconf ---" >> "$EVIDENCIA_FILE"
    named-checkconf "$NAMED_CONF" 2>&1 | tee -a "$EVIDENCIA_FILE"
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        exito "named-checkconf: OK"
    else
        error "named-checkconf: Error"
    fi
    echo "" >> "$EVIDENCIA_FILE"

    # Verificar cada zona
    ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')

    while IFS= read -r zona; do
        [[ -z "$zona" ]] && continue
        ZONA_FILE="${ZONA_DIR}/db.${zona}"
        if [[ -f "$ZONA_FILE" ]]; then
            echo "--- named-checkzone ${zona} ---" >> "$EVIDENCIA_FILE"
            RESULTADO=$(named-checkzone "$zona" "$ZONA_FILE" 2>&1)
            echo "$RESULTADO" >> "$EVIDENCIA_FILE"
            if echo "$RESULTADO" | grep -q "OK"; then
                exito "named-checkzone ${zona}: OK"
            else
                error "named-checkzone ${zona}: Error"
            fi
        fi
    done <<< "$ZONAS"

    # Estado del servicio
    echo ""
    info "Estado del servicio"
    separador
    echo "--- systemctl status named ---" >> "$EVIDENCIA_FILE"
    systemctl status named --no-pager 2>&1 | tee -a "$EVIDENCIA_FILE" | head -8

    # Pruebas de resolución
    echo ""
    info "Pruebas de resolución"
    separador

    while IFS= read -r zona; do
        [[ -z "$zona" ]] && continue
        echo -e "\n  ${BOLD}── ${zona} ──${NC}"
        echo "" >> "$EVIDENCIA_FILE"
        echo "=== Pruebas: ${zona} ===" >> "$EVIDENCIA_FILE"

        # nslookup
        echo "--- nslookup ${zona} ---" >> "$EVIDENCIA_FILE"
        RESULTADO=$(nslookup "$zona" 127.0.0.1 2>&1)
        echo "$RESULTADO" >> "$EVIDENCIA_FILE"
        IP_RES=$(echo "$RESULTADO" | grep -A2 "Name:" | grep "Address" | awk '{print $2}' | head -1)
        [[ -z "$IP_RES" ]] && IP_RES=$(echo "$RESULTADO" | tail -2 | grep "Address" | awk '{print $2}')
        if [[ -n "$IP_RES" ]]; then
            exito "nslookup ${zona} → ${IP_RES}"
        else
            aviso "nslookup ${zona}: Sin respuesta"
        fi

        # nslookup www
        echo "--- nslookup www.${zona} ---" >> "$EVIDENCIA_FILE"
        RESULTADO_WWW=$(nslookup "www.${zona}" 127.0.0.1 2>&1)
        echo "$RESULTADO_WWW" >> "$EVIDENCIA_FILE"
        if echo "$RESULTADO_WWW" | grep -q "canonical name\|Address"; then
            exito "nslookup www.${zona} → OK"
        else
            aviso "nslookup www.${zona}: Sin respuesta"
        fi

        # dig
        echo "--- dig ${zona} ---" >> "$EVIDENCIA_FILE"
        DIG_R=$(dig @127.0.0.1 "$zona" A +short 2>&1)
        echo "$DIG_R" >> "$EVIDENCIA_FILE"
        [[ -n "$DIG_R" ]] && exito "dig ${zona} → ${DIG_R}" || aviso "dig ${zona}: Sin resultado"

        # ping
        echo "--- ping ${zona} ---" >> "$EVIDENCIA_FILE"
        ping -c 2 "$zona" >> "$EVIDENCIA_FILE" 2>&1
        echo "--- ping www.${zona} ---" >> "$EVIDENCIA_FILE"
        ping -c 2 "www.${zona}" >> "$EVIDENCIA_FILE" 2>&1

    done <<< "$ZONAS"

    echo ""
    separador
    exito "Evidencias guardadas en: $EVIDENCIA_FILE"
    separador
    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  INICIO
# ══════════════════════════════════════════════════════════════════════════════
verificar_root
mkdir -p "$EVIDENCIA_DIR"
menu_principal