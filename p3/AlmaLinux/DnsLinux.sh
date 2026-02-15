#!/bin/bash
#==============================================================================
#  SCRIPT DE INSTALACIÓN Y CONFIGURACIÓN DE SERVIDOR DNS (BIND)
#  Sistema Operativo: AlmaLinux
#  Dominio: reprobados.com
#  Autor: Proyecto DNS Automatizado
#  Fecha: $(date +%Y-%m-%d)
#==============================================================================

# ── Colores para salida ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Variables globales ───────────────────────────────────────────────────────
DOMINIO="reprobados.com"
ZONA_FILE="/var/named/db.${DOMINIO}"
NAMED_CONF_LOCAL="/etc/named.conf"
LOG_FILE="/var/log/dns_instalacion_$(date +%Y%m%d_%H%M%S).log"
EVIDENCIA_DIR="/root/evidencias_dns"

# ── Funciones de utilidad ────────────────────────────────────────────────────
log() {
    local mensaje="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$mensaje" | tee -a "$LOG_FILE"
}

exito() { echo -e "${GREEN}[✔] $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[✘] $1${NC}" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYAN}[ℹ] $1${NC}" | tee -a "$LOG_FILE"; }
aviso() { echo -e "${YELLOW}[⚠] $1${NC}" | tee -a "$LOG_FILE"; }

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     CONFIGURACIÓN AUTOMATIZADA DE SERVIDOR DNS (BIND)      ║"
    echo "║                    AlmaLinux Server                        ║"
    echo "║              Dominio: reprobados.com                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Verificación de root ─────────────────────────────────────────────────────
verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Este script debe ejecutarse como root (sudo)."
        exit 1
    fi
    exito "Ejecutando como root."
}

# ── Crear directorio de evidencias ───────────────────────────────────────────
crear_directorio_evidencias() {
    mkdir -p "$EVIDENCIA_DIR"
    exito "Directorio de evidencias creado: $EVIDENCIA_DIR"
}

# ── Validación de parámetros ─────────────────────────────────────────────────
validar_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octetos <<< "$ip"
        for octeto in "${octetos[@]}"; do
            if (( octeto < 0 || octeto > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validar_mascara() {
    local mask="$1"
    if [[ "$mask" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# ── Verificación y configuración de IP estática ──────────────────────────────
verificar_ip_estatica() {
    echo ""
    info "═══ VERIFICACIÓN DE IP ESTÁTICA ═══"

    # Interfaz de red interna definida para la práctica
    INTERFAZ="ens224"

    # Verificar que la interfaz existe
    if ! ip link show "$INTERFAZ" &>/dev/null; then
        error "La interfaz $INTERFAZ no existe en este sistema."
        info "Interfaces disponibles:"
        ip -br link show | grep -v "lo" | tee -a "$LOG_FILE"
        exit 1
    fi
    info "Interfaz de red interna: $INTERFAZ"

    # Verificar que la interfaz esté activa, si no, levantarla
    ESTADO_LINK=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
    if [[ "$ESTADO_LINK" != "UP" ]]; then
        aviso "La interfaz $INTERFAZ no está activa (estado: $ESTADO_LINK). Activando..."
        nmcli device connect "$INTERFAZ" 2>/dev/null || ip link set "$INTERFAZ" up
        sleep 2
    fi

    # Obtener el nombre de la conexión asociada a la interfaz
    CONEXION=$(nmcli -t -f NAME,DEVICE connection show | grep ":${INTERFAZ}$" | cut -d: -f1)

    if [[ -z "$CONEXION" ]]; then
        aviso "No hay conexión activa para $INTERFAZ. Creando conexión..."
        nmcli connection add type ethernet ifname "$INTERFAZ" con-name "red-interna-${INTERFAZ}"
        CONEXION="red-interna-${INTERFAZ}"
    fi
    info "Conexión de NetworkManager: $CONEXION"

    # Verificar si ya tiene IP estática (método manual)
    METODO=$(nmcli -g ipv4.method connection show "$CONEXION" 2>/dev/null)

    if [[ "$METODO" == "manual" ]]; then
        IP_ACTUAL=$(nmcli -g ipv4.addresses connection show "$CONEXION" | head -1 | cut -d/ -f1)
        exito "IP estática ya configurada: $IP_ACTUAL en $INTERFAZ"
        IP_SERVIDOR="$IP_ACTUAL"
    else
        aviso "La interfaz $INTERFAZ está configurada con DHCP."
        IP_ACTUAL=$(ip -4 addr show "$INTERFAZ" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
        info "IP actual (DHCP): $IP_ACTUAL"

        echo ""
        echo -e "${YELLOW}Se requiere configurar una IP estática para el servidor DNS.${NC}"
        echo -e "${YELLOW}Ingrese los datos de red o presione ENTER para usar los valores actuales.${NC}"
        echo ""

        # Solicitar IP
        while true; do
            read -rp "$(echo -e ${CYAN})Dirección IP [$IP_ACTUAL]: $(echo -e ${NC})" INPUT_IP
            INPUT_IP="${INPUT_IP:-$IP_ACTUAL}"
            if validar_ip "$INPUT_IP"; then
                break
            else
                error "IP inválida. Formato: X.X.X.X (0-255)"
            fi
        done

        # Obtener máscara actual
        PREFIJO_ACTUAL=$(ip -4 addr show "$INTERFAZ" | grep inet | awk '{print $2}' | head -1 | cut -d/ -f2)
        PREFIJO_ACTUAL="${PREFIJO_ACTUAL:-24}"

        read -rp "$(echo -e ${CYAN})Prefijo de red (CIDR) [$PREFIJO_ACTUAL]: $(echo -e ${NC})" INPUT_PREFIJO
        INPUT_PREFIJO="${INPUT_PREFIJO:-$PREFIJO_ACTUAL}"

        # Obtener gateway actual
        GW_ACTUAL=$(ip route | grep default | awk '{print $3}' | head -1)
        while true; do
            read -rp "$(echo -e ${CYAN})Gateway [$GW_ACTUAL]: $(echo -e ${NC})" INPUT_GW
            INPUT_GW="${INPUT_GW:-$GW_ACTUAL}"
            if validar_ip "$INPUT_GW"; then
                break
            else
                error "Gateway inválido."
            fi
        done

        # DNS externo de respaldo
        read -rp "$(echo -e ${CYAN})DNS externo de respaldo [8.8.8.8]: $(echo -e ${NC})" INPUT_DNS
        INPUT_DNS="${INPUT_DNS:-8.8.8.8}"

        info "Configurando IP estática..."
        nmcli connection modify "$CONEXION" ipv4.addresses "${INPUT_IP}/${INPUT_PREFIJO}"
        nmcli connection modify "$CONEXION" ipv4.gateway "$INPUT_GW"
        nmcli connection modify "$CONEXION" ipv4.dns "127.0.0.1 ${INPUT_DNS}"
        nmcli connection modify "$CONEXION" ipv4.method manual

        info "Reiniciando conexión de red..."
        nmcli connection down "$CONEXION" && nmcli connection up "$CONEXION"
        sleep 3

        IP_SERVIDOR="$INPUT_IP"
        exito "IP estática configurada: $IP_SERVIDOR/$INPUT_PREFIJO"
    fi

    echo ""
}

# ── Solicitar IP del cliente ─────────────────────────────────────────────────
solicitar_ip_cliente() {
    info "═══ CONFIGURACIÓN DE REGISTROS DNS ═══"
    echo ""
    echo -e "${YELLOW}Los registros A del dominio apuntarán a la IP de la máquina cliente.${NC}"
    echo ""

    while true; do
        read -rp "$(echo -e ${CYAN})IP de la máquina cliente (VM referenciada): $(echo -e ${NC})" IP_CLIENTE
        if validar_ip "$IP_CLIENTE"; then
            exito "IP del cliente validada: $IP_CLIENTE"
            break
        else
            error "IP inválida. Intente de nuevo."
        fi
    done
    echo ""
}

# ── Instalación de BIND (idempotente) ────────────────────────────────────────
instalar_bind() {
    info "═══ INSTALACIÓN DE BIND ═══"

    if rpm -q bind bind-utils &>/dev/null; then
        exito "BIND ya está instalado. Omitiendo instalación."
    else
        info "Instalando paquetes: bind, bind-utils, bind-chroot..."
        dnf install -y bind bind-utils bind-chroot 2>&1 | tee -a "$LOG_FILE"

        if [[ $? -eq 0 ]]; then
            exito "BIND instalado correctamente."
        else
            error "Error en la instalación de BIND."
            exit 1
        fi
    fi

    # Verificar si el servicio ya está activo
    if systemctl is-active --quiet named; then
        aviso "El servicio named ya está activo."
    else
        info "El servicio named se iniciará después de la configuración."
    fi
    echo ""
}

# ── Configuración de named.conf ──────────────────────────────────────────────
configurar_named_conf() {
    info "═══ CONFIGURACIÓN DE named.conf ═══"

    # Respaldar configuración original
    if [[ -f "$NAMED_CONF" && ! -f "${NAMED_CONF}.bak.original" ]]; then
        cp "$NAMED_CONF" "${NAMED_CONF}.bak.original"
        info "Respaldo creado: ${NAMED_CONF}.bak.original"
    fi

    # Verificar si la zona ya existe en la configuración
    if grep -q "zone \"${DOMINIO}\"" "$NAMED_CONF_LOCAL" 2>/dev/null; then
        aviso "La zona ${DOMINIO} ya existe en la configuración. Se actualizará."
        # Eliminar zona existente para recrear
        sed -i "/zone \"${DOMINIO}\"/,/^};/d" "$NAMED_CONF_LOCAL"
    fi

    # Respaldar named.conf actual
    cp "$NAMED_CONF_LOCAL" "${NAMED_CONF_LOCAL}.bak.$(date +%Y%m%d_%H%M%S)"

    # Modificar named.conf para escuchar en todas las interfaces
    # Cambiar listen-on a any
    sed -i 's/listen-on port 53 {.*};/listen-on port 53 { any; };/' "$NAMED_CONF_LOCAL"
    sed -i 's/listen-on-v6 port 53 {.*};/listen-on-v6 port 53 { none; };/' "$NAMED_CONF_LOCAL"

    # Permitir consultas desde cualquier red
    sed -i 's/allow-query {.*};/allow-query { any; };/' "$NAMED_CONF_LOCAL"

    # Agregar zona de búsqueda directa al final del archivo
    cat >> "$NAMED_CONF_LOCAL" <<EOF

// ── Zona de búsqueda directa: ${DOMINIO} ──
zone "${DOMINIO}" IN {
    type master;
    file "${ZONA_FILE}";
    allow-update { none; };
};
EOF

    exito "Configuración de named.conf actualizada."
    echo ""
}

# ── Crear archivo de zona ────────────────────────────────────────────────────
crear_archivo_zona() {
    info "═══ CREACIÓN DEL ARCHIVO DE ZONA ═══"

    # Generar serial basado en fecha
    SERIAL=$(date +%Y%m%d01)

    cat > "$ZONA_FILE" <<EOF
;==============================================================================
; Archivo de zona para ${DOMINIO}
; Generado automáticamente: $(date '+%Y-%m-%d %H:%M:%S')
;==============================================================================
\$TTL    86400
@       IN      SOA     ns1.${DOMINIO}. admin.${DOMINIO}. (
                        ${SERIAL}   ; Serial (YYYYMMDDNN)
                        3600        ; Refresh (1 hora)
                        1800        ; Retry (30 minutos)
                        604800      ; Expire (1 semana)
                        86400       ; Minimum TTL (1 día)
                        )

; ── Registros NS (Name Server) ──
@       IN      NS      ns1.${DOMINIO}.

; ── Registro A del servidor de nombres ──
ns1     IN      A       ${IP_SERVIDOR}

; ── Registro A para el dominio raíz ──
@       IN      A       ${IP_CLIENTE}

; ── Registro CNAME para www ──
www     IN      CNAME   ${DOMINIO}.
EOF

    # Asignar permisos correctos
    chown named:named "$ZONA_FILE"
    chmod 640 "$ZONA_FILE"

    exito "Archivo de zona creado: $ZONA_FILE"
    info "Registros configurados:"
    info "  ${DOMINIO}      →  A      ${IP_CLIENTE}"
    info "  www.${DOMINIO}  →  CNAME  ${DOMINIO}"
    info "  ns1.${DOMINIO}  →  A      ${IP_SERVIDOR}"
    echo ""
}

# ── Validación de sintaxis ───────────────────────────────────────────────────
validar_configuracion() {
    info "═══ VALIDACIÓN DE CONFIGURACIÓN ═══"

    # Verificar sintaxis de named.conf
    info "Verificando sintaxis de named.conf..."
    RESULTADO_CONF=$(named-checkconf "$NAMED_CONF_LOCAL" 2>&1)
    if [[ $? -eq 0 ]]; then
        exito "named-checkconf: Sintaxis correcta."
    else
        error "named-checkconf: Errores encontrados:"
        echo "$RESULTADO_CONF" | tee -a "$LOG_FILE"
        exit 1
    fi

    # Verificar archivo de zona
    info "Verificando archivo de zona..."
    RESULTADO_ZONA=$(named-checkzone "$DOMINIO" "$ZONA_FILE" 2>&1)
    if [[ $? -eq 0 ]]; then
        exito "named-checkzone: Zona válida."
    else
        error "named-checkzone: Errores en la zona:"
        echo "$RESULTADO_ZONA" | tee -a "$LOG_FILE"
        exit 1
    fi

    # Guardar evidencia
    echo "=== VALIDACIÓN DE CONFIGURACIÓN DNS ===" > "${EVIDENCIA_DIR}/validacion_sintaxis.txt"
    echo "Fecha: $(date)" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt"
    echo "" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt"
    echo "--- named-checkconf ---" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt"
    named-checkconf "$NAMED_CONF_LOCAL" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt" 2>&1
    echo "Resultado: OK" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt"
    echo "" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt"
    echo "--- named-checkzone ---" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt"
    named-checkzone "$DOMINIO" "$ZONA_FILE" >> "${EVIDENCIA_DIR}/validacion_sintaxis.txt" 2>&1

    echo ""
}

# ── Configurar Firewall ──────────────────────────────────────────────────────
configurar_firewall() {
    info "═══ CONFIGURACIÓN DE FIREWALL ═══"

    if systemctl is-active --quiet firewalld; then
        # Verificar si el servicio DNS ya está permitido
        if firewall-cmd --list-services --permanent | grep -q "dns"; then
            aviso "El servicio DNS ya está permitido en el firewall."
        else
            firewall-cmd --permanent --add-service=dns
            firewall-cmd --permanent --add-port=53/tcp
            firewall-cmd --permanent --add-port=53/udp
            firewall-cmd --reload
            exito "Reglas de firewall configuradas (puerto 53 TCP/UDP)."
        fi
    else
        aviso "firewalld no está activo. Omitiendo configuración de firewall."
    fi
    echo ""
}

# ── Configurar SELinux ───────────────────────────────────────────────────────
configurar_selinux() {
    info "═══ CONFIGURACIÓN DE SELinux ═══"

    if command -v getenforce &>/dev/null; then
        SELINUX_STATUS=$(getenforce)
        if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
            info "SELinux está en modo Enforcing. Configurando contextos..."
            restorecon -Rv /var/named/ 2>&1 | tee -a "$LOG_FILE"
            setsebool -P named_write_master_zones 1 2>/dev/null
            exito "Contextos de SELinux configurados."
        else
            info "SELinux en modo: $SELINUX_STATUS"
        fi
    fi
    echo ""
}

# ── Iniciar y habilitar servicio ─────────────────────────────────────────────
iniciar_servicio() {
    info "═══ INICIO DEL SERVICIO DNS ═══"

    systemctl enable named 2>&1 | tee -a "$LOG_FILE"
    systemctl restart named 2>&1

    sleep 2

    if systemctl is-active --quiet named; then
        exito "Servicio named activo y habilitado."
        systemctl status named --no-pager | head -10 | tee -a "$LOG_FILE"
    else
        error "El servicio named no pudo iniciar."
        journalctl -u named --no-pager -n 20 | tee -a "$LOG_FILE"
        exit 1
    fi
    echo ""
}

# ── Pruebas de resolución ────────────────────────────────────────────────────
pruebas_resolucion() {
    info "═══ PRUEBAS DE RESOLUCIÓN DNS ═══"

    EVIDENCIA_FILE="${EVIDENCIA_DIR}/pruebas_resolucion.txt"
    echo "=== PRUEBAS DE RESOLUCIÓN DNS ===" > "$EVIDENCIA_FILE"
    echo "Fecha: $(date)" >> "$EVIDENCIA_FILE"
    echo "Servidor: $(hostname) - ${IP_SERVIDOR}" >> "$EVIDENCIA_FILE"
    echo "" >> "$EVIDENCIA_FILE"

    # Test 1: nslookup dominio raíz
    info "Test 1: nslookup ${DOMINIO}"
    echo "--- Test 1: nslookup ${DOMINIO} ---" >> "$EVIDENCIA_FILE"
    RESULTADO1=$(nslookup "$DOMINIO" 127.0.0.1 2>&1)
    echo "$RESULTADO1" | tee -a "$EVIDENCIA_FILE"
    if echo "$RESULTADO1" | grep -q "$IP_CLIENTE"; then
        exito "  → Resolución de ${DOMINIO}: ${IP_CLIENTE} ✔"
    else
        aviso "  → Resolución de ${DOMINIO}: verificar manualmente."
    fi
    echo "" >> "$EVIDENCIA_FILE"

    # Test 2: nslookup www
    info "Test 2: nslookup www.${DOMINIO}"
    echo "--- Test 2: nslookup www.${DOMINIO} ---" >> "$EVIDENCIA_FILE"
    RESULTADO2=$(nslookup "www.${DOMINIO}" 127.0.0.1 2>&1)
    echo "$RESULTADO2" | tee -a "$EVIDENCIA_FILE"
    if echo "$RESULTADO2" | grep -q "$IP_CLIENTE"; then
        exito "  → Resolución de www.${DOMINIO}: ${IP_CLIENTE} ✔"
    else
        aviso "  → Resolución de www.${DOMINIO}: verificar manualmente."
    fi
    echo "" >> "$EVIDENCIA_FILE"

    # Test 3: dig
    info "Test 3: dig ${DOMINIO}"
    echo "--- Test 3: dig ${DOMINIO} ---" >> "$EVIDENCIA_FILE"
    dig @127.0.0.1 "$DOMINIO" A +short 2>&1 | tee -a "$EVIDENCIA_FILE"
    echo "" >> "$EVIDENCIA_FILE"

    info "Test 4: dig www.${DOMINIO}"
    echo "--- Test 4: dig www.${DOMINIO} ---" >> "$EVIDENCIA_FILE"
    dig @127.0.0.1 "www.${DOMINIO}" +short 2>&1 | tee -a "$EVIDENCIA_FILE"
    echo "" >> "$EVIDENCIA_FILE"

    exito "Evidencias guardadas en: $EVIDENCIA_FILE"
    echo ""
}

# ── Resumen final ────────────────────────────────────────────────────────────
resumen_final() {
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              INSTALACIÓN COMPLETADA CON ÉXITO              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Dominio:        ${DOMINIO}                          ║"
    echo "║  IP Servidor:    ${IP_SERVIDOR}$(printf '%*s' $((27 - ${#IP_SERVIDOR})) '')║"
    echo "║  IP Cliente:     ${IP_CLIENTE}$(printf '%*s' $((27 - ${#IP_CLIENTE})) '')║"
    echo "║  Zona archivo:   ${ZONA_FILE}$(printf '%*s' $((27 - ${#ZONA_FILE})) '')║"
    echo "║  Evidencias:     ${EVIDENCIA_DIR}$(printf '%*s' $((27 - ${#EVIDENCIA_DIR})) '')║"
    echo "║  Log:            ${LOG_FILE}                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Registros DNS configurados:                               ║"
    echo "║    ${DOMINIO}      → A     ${IP_CLIENTE}$(printf '%*s' $((20 - ${#IP_CLIENTE})) '')║"
    echo "║    www.${DOMINIO}  → CNAME ${DOMINIO}             ║"
    echo "║    ns1.${DOMINIO}  → A     ${IP_SERVIDOR}$(printf '%*s' $((20 - ${#IP_SERVIDOR})) '')║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  EJECUCIÓN PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════
main() {
    banner
    verificar_root
    crear_directorio_evidencias
    verificar_ip_estatica
    solicitar_ip_cliente
    instalar_bind
    configurar_named_conf
    crear_archivo_zona
    configurar_selinux
    configurar_firewall
    validar_configuracion
    iniciar_servicio
    pruebas_resolucion
    resumen_final
}

# Ejecutar
main "$@"