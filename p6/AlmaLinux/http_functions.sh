#!/bin/bash
# http_functions.sh
# Gestion de servidores HTTP: Apache2, Nginx, Tomcat
# Sistema: AlmaLinux / RHEL / Debian-based
# Depende de: common-functions.sh (si se usa desde main.sh)
#             O se ejecuta de forma independiente.

# ─────────────────────────────────────────────────────────────────────────────
# FUNCIONES DE SALIDA (se definen solo si no existen, por compatibilidad)
# ─────────────────────────────────────────────────────────────────────────────
if ! declare -f msg_ok &>/dev/null; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
    msg_ok()   { echo -e "  ${G}[OK]${N} $1"; }
    msg_err()  { echo -e "  ${R}[ERROR]${N} $1" >&2; }
    msg_info() { echo -e "  ${C}[INFO]${N} $1"; }
    msg_warn() { echo -e "  ${Y}[AVISO]${N} $1"; }
    pausar()   { echo ""; read -rp "  Presiona ENTER para continuar... " _; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES GLOBALES
# ─────────────────────────────────────────────────────────────────────────────
HTTP_STATE_FILE="/etc/http-manager/state"   # servicio activo, puerto activo
HTTP_WEBROOT_APACHE="/var/www/html"
HTTP_WEBROOT_NGINX="/var/www/html"
HTTP_WEBROOT_TOMCAT="/var/lib/tomcat*/webapps/ROOT"

# Puertos reservados para otros servicios (no se puede usar ninguno de estos)
HTTP_PUERTOS_RESERVADOS=(22 21 25 53 110 143 443 993 995 3306 5432 8443)

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS INTERNOS
# ─────────────────────────────────────────────────────────────────────────────

# Devuelve el nombre del servicio systemd segun el servicio HTTP
_http_servicio_systemd() {
    local svc="$1"
    case "$svc" in
        apache2|apache) command -v apache2 &>/dev/null && echo "apache2" || echo "httpd" ;;
        nginx)          echo "nginx" ;;
        tomcat*)
            # 1. Intentar via list-units (cubre tomcat, tomcat9, tomcat10...)
            local _tc_unit
            _tc_unit=$(systemctl list-units --type=service --all 2>/dev/null \
                           | grep -oP 'tomcat[0-9]*(?=\.service)' | head -1)
            if [[ -n "$_tc_unit" ]]; then
                echo "$_tc_unit"
            else
                # 2. Fallback: preguntar directamente a systemd si el unit existe
                #    (cubre unidades instaladas pero nunca iniciadas, o tarball)
                for _tc_try in tomcat tomcat10 tomcat9; do
                    if systemctl cat "$_tc_try" &>/dev/null 2>&1; then
                        echo "$_tc_try"; break
                    fi
                done
            fi
            ;;
    esac
}

# Devuelve el webroot del servicio
_http_webroot() {
    local svc="$1"
    case "$svc" in
        apache2|apache|httpd) echo "/var/www/html" ;;
        nginx)                echo "/usr/share/nginx/html" ;;
        tomcat*)
            # Prioridad:
            # 1. /var/lib/tomcat  — paquete EPEL estandar (sin sufijo numerico)
            # 2. /opt/tomcat      — instalacion tarball
            # 3. Cualquier tomcat[0-9]* en /var/lib con webapps real
            # Evitamos sort -V tail -1: tomcat5 tiene sufijo>0 pero NO es el directorio
            # activo del paquete EPEL moderno (tomcat10/tomcat)
            if [[ -d "/var/lib/tomcat/webapps" ]]; then
                echo "/var/lib/tomcat/webapps/ROOT"
            elif [[ -d "/opt/tomcat/webapps" ]]; then
                echo "/opt/tomcat/webapps/ROOT"
            else
                local tc_home=""
                while IFS= read -r candidate; do
                    [[ -d "${candidate}/webapps" ]] && tc_home="$candidate" && break
                done < <(find /var/lib -maxdepth 1 -name "tomcat[0-9]*" -type d 2>/dev/null | sort -V -r)
                echo "${tc_home:-/var/lib/tomcat}/webapps/ROOT"
            fi
            ;;
    esac
}

# Guarda / actualiza la entrada de UN servicio en el archivo de estado
# Formato: svc|puerto|version  (una linea por servicio)
_http_guardar_estado() {
    local svc="$1" puerto="$2" version="$3"
    mkdir -p "$(dirname "$HTTP_STATE_FILE")"
    local tmp="${HTTP_STATE_FILE}.tmp"
    grep -v "^${svc}|" "$HTTP_STATE_FILE" 2>/dev/null > "$tmp" || true
    echo "${svc}|${puerto}|${version}" >> "$tmp"
    mv "$tmp" "$HTTP_STATE_FILE"
}

# Elimina la entrada de un servicio del archivo de estado
_http_eliminar_estado() {
    local svc="$1"
    [[ -f "$HTTP_STATE_FILE" ]] || return
    local tmp="${HTTP_STATE_FILE}.tmp"
    grep -v "^${svc}|" "$HTTP_STATE_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$HTTP_STATE_FILE"
}

# Lee el estado de todos los servicios activos.
# Popula: HTTP_ACTIVE_SVCS (array)
#         HTTP_SVC_<svc>_PUERTO  /  HTTP_SVC_<svc>_VERSION  (variables dinamicas)
# Compat: HTTP_SVC / HTTP_PUERTO / HTTP_VERSION apuntan al primer servicio activo
_http_leer_estado() {
    HTTP_SVC="" HTTP_PUERTO="" HTTP_VERSION=""
    HTTP_ACTIVE_SVCS=()
    [[ -f "$HTTP_STATE_FILE" ]] || return

    # Detectar formato antiguo (sin '|') y convertirlo al nuevo formato pipe-separado
    if ! grep -q '|' "$HTTP_STATE_FILE" 2>/dev/null; then
        local _osvc="" _opto="" _over=""
        while IFS= read -r _line; do
            [[ "$_line" =~ ^HTTP_SVC=\"(.*)\"$     ]] && _osvc="${BASH_REMATCH[1]}"
            [[ "$_line" =~ ^HTTP_PUERTO=\"(.*)\"$  ]] && _opto="${BASH_REMATCH[1]}"
            [[ "$_line" =~ ^HTTP_VERSION=\"(.*)\"$ ]] && _over="${BASH_REMATCH[1]}"
        done < "$HTTP_STATE_FILE"
        if [[ -n "$_osvc" ]]; then
            echo "${_osvc}|${_opto}|${_over}" > "$HTTP_STATE_FILE"
        else
            rm -f "$HTTP_STATE_FILE"; return
        fi
    fi

    while IFS='|' read -r _s _p _v; do
        [[ -z "$_s" || "$_s" == \#* ]] && continue
        # Sanear: solo letras, numeros y guiones (nombre de servicio valido)
        [[ "$_s" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        local _key="${_s//-/_}"
        HTTP_ACTIVE_SVCS+=("$_s")
        printf -v "HTTP_SVC_${_key}_PUERTO"  "%s" "$_p"
        printf -v "HTTP_SVC_${_key}_VERSION" "%s" "$_v"
        if [[ -z "$HTTP_SVC" ]]; then
            HTTP_SVC="$_s"; HTTP_PUERTO="$_p"; HTTP_VERSION="$_v"
        fi
    done < "$HTTP_STATE_FILE"
}

# Devuelve el puerto de un servicio especifico desde el estado
_http_puerto_de_svc() {
    local svc="$1"
    [[ -f "$HTTP_STATE_FILE" ]] || { echo ""; return; }
    grep "^${svc}|" "$HTTP_STATE_FILE" 2>/dev/null | cut -d'|' -f2 | head -1
}

# Si hay un solo servicio activo lo devuelve en stdout; si hay varios, pide al usuario elegir.
# Retorna 1 si no hay servicios activos.
_http_seleccionar_activo() {
    _http_leer_estado
    if [[ ${#HTTP_ACTIVE_SVCS[@]} -eq 0 ]]; then
        msg_warn "No hay servicios HTTP gestionados." >&2
        return 1
    fi
    if [[ ${#HTTP_ACTIVE_SVCS[@]} -eq 1 ]]; then
        echo "${HTTP_ACTIVE_SVCS[0]}"; return 0
    fi
    echo "" >&2
    echo "  Servicios activos:" >&2
    local i
    for i in "${!HTTP_ACTIVE_SVCS[@]}"; do
        local _s="${HTTP_ACTIVE_SVCS[$i]}"
        local _vp="HTTP_SVC_${_s//-/_}_PUERTO"
        echo "    $((i+1))) $_s (puerto: ${!_vp:-?})" >&2
    done
    while true; do
        read -rp "  Seleccione servicio [1-${#HTTP_ACTIVE_SVCS[@]}]: " _sel </dev/tty
        if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= ${#HTTP_ACTIVE_SVCS[@]} )); then
            echo "${HTTP_ACTIVE_SVCS[$((_sel-1))]}"; return 0
        fi
        msg_warn "Seleccion invalida." >&2
    done
}

# Verifica si un puerto esta en uso (por cualquier proceso)
_http_puerto_en_uso() {
    local puerto="$1"
    ss -tlnp 2>/dev/null | grep -q ":${puerto}\b" || \
    netstat -tlnp 2>/dev/null | grep -q ":${puerto} "
}

# Verifica si el puerto esta en la lista negra de reservados
_http_puerto_reservado() {
    local puerto="$1"
    for p in "${HTTP_PUERTOS_RESERVADOS[@]}"; do
        [[ "$p" == "$puerto" ]] && return 0
    done
    return 1
}

# Validacion completa de puerto: rango, reservado, en uso
# $2: nombre del servicio que lo usaria (para comparar si es el mismo)
_http_validar_puerto() {
    local puerto="$1"
    local svc_actual="${2:-}"

    if ! [[ "$puerto" =~ ^[0-9]+$ ]] || (( puerto < 1 || puerto > 65535 )); then
        msg_warn "Puerto invalido: debe ser un numero entre 1 y 65535."
        return 1
    fi

    if _http_puerto_reservado "$puerto"; then
        msg_warn "Puerto $puerto esta reservado para otro servicio del sistema."
        return 1
    fi

    # Si el puerto esta en uso pero es el propio servicio activo, no es problema
    if _http_puerto_en_uso "$puerto"; then
        if [[ -n "$svc_actual" ]]; then
            local sd
            sd=$(_http_servicio_systemd "$svc_actual")
            if ss -tlnp 2>/dev/null | grep ":${puerto}\b" | grep -q "$sd"; then
                return 0   # Es el mismo servicio, no hay conflicto
            fi
        fi
        msg_warn "Puerto $puerto ya esta en uso por otro proceso."
        return 1
    fi

    return 0
}

# Solicita un puerto al usuario con validacion
# Usa /dev/tty porque se llama dentro de puerto=$(...) (command substitution)
_http_pedir_puerto() {
    local default="${1:-80}"
    local svc="${2:-}"
    local puerto
    while true; do
        read -rp "  Puerto de escucha [$default]: " puerto </dev/tty
        puerto="${puerto:-$default}"
        _http_validar_puerto "$puerto" "$svc" >&2 && echo "$puerto" && return 0
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# CONSULTA DINAMICA DE VERSIONES
# No hay versiones quemadas en el codigo.
# ─────────────────────────────────────────────────────────────────────────────

# Detecta el gestor de paquetes disponible
_http_pkg_manager() {
    command -v dnf     &>/dev/null && echo "dnf"     && return
    command -v yum     &>/dev/null && echo "yum"     && return
    command -v apt-get &>/dev/null && echo "apt"     && return
    echo "unknown"
}

# Nombre real del paquete segun el gestor de paquetes
# $1 = servicio logico (apache2, nginx, tomcat)
_http_pkg_nombre() {
    local svc="$1"
    local pm
    pm=$(_http_pkg_manager)
    case "$svc" in
        apache2|apache|httpd)
            [[ "$pm" == "apt" ]] && echo "apache2" || echo "httpd" ;;
        nginx)
            echo "nginx" ;;
        tomcat)
            [[ "$pm" == "apt" ]] && echo "tomcat10" || echo "tomcat" ;;
    esac
}

# Versiones disponibles via apt-cache madison
_http_versiones_apt() {
    local paquete="$1"
    apt-cache madison "$paquete" 2>/dev/null | awk '{print $3}' | sort -uV
}

# Versiones disponibles via dnf/yum list --showduplicates
_http_versiones_dnf() {
    local paquete="$1"
    local pm
    pm=$(_http_pkg_manager)
    $pm list --showduplicates "$paquete" 2>/dev/null \
        | awk -v pkg="$paquete" '$0 ~ "^"pkg {print $2}' \
        | sed 's/\.[^.]*$//' \
        | sort -uV
}

# Versiones disponibles de Tomcat (repo + GitHub API como fallback)
_http_versiones_tomcat() {
    local pm
    pm=$(_http_pkg_manager)
    local pkg
    pkg=$(_http_pkg_nombre "tomcat")

    # Primero intentar desde el repo local
    local repo_vers
    if [[ "$pm" == "apt" ]]; then
        repo_vers=$(apt-cache madison "$pkg" 2>/dev/null | awk '{print $3}' | sort -uV)
    else
        repo_vers=$($pm list --showduplicates "$pkg" 2>/dev/null \
            | awk -v p="$pkg" '$0 ~ "^"p {print $2}' | sed 's/\.[^.]*$//' | sort -uV)
    fi

    if [[ -n "$repo_vers" ]]; then
        echo "$repo_vers"
        return
    fi

    # Fallback: GitHub API (versiones binarias oficiales)
    msg_info "Tomcat no encontrado en repo. Consultando GitHub..." >&2
    local tags
    tags=$(curl -sf --max-time 8 \
        "https://api.github.com/repos/apache/tomcat/tags?per_page=30" 2>/dev/null \
        | grep -oP '(?<="name": ")[^"]+' | grep -E '^[0-9]+\.' | sort -uV)

    if [[ -n "$tags" ]]; then
        echo "$tags"
    else
        # Sin internet y sin repo: informar al usuario
        msg_warn "No se encontraron versiones de Tomcat. Habilita EPEL: dnf install epel-release" >&2
    fi
}

# Muestra menu de versiones para un servicio y devuelve la elegida en stdout
# Retorna 1 si no hay versiones disponibles
_http_seleccionar_version() {
    local svc="$1"
    local -a versiones
    local pm
    pm=$(_http_pkg_manager)
    local pkg
    pkg=$(_http_pkg_nombre "$svc")

    # Todos los mensajes de display van a stderr para no contaminar
    # la captura: version=$(_http_seleccionar_version "$svc")
    msg_info "Consultando versiones disponibles de '$svc' (paquete: $pkg, gestor: $pm)..." >&2

    case "$svc" in
        apache2|apache|httpd)
            if [[ "$pm" == "apt" ]]; then
                mapfile -t versiones < <(_http_versiones_apt "$pkg")
            else
                mapfile -t versiones < <(_http_versiones_dnf "$pkg")
            fi
            ;;
        nginx)
            if [[ "$pm" == "apt" ]]; then
                mapfile -t versiones < <(_http_versiones_apt "$pkg")
            else
                mapfile -t versiones < <(_http_versiones_dnf "$pkg")
            fi
            ;;
        tomcat)
            mapfile -t versiones < <(_http_versiones_tomcat)
            ;;
    esac

    if [[ ${#versiones[@]} -eq 0 ]]; then
        msg_warn "No se encontraron versiones disponibles para '$svc'." >&2
        msg_info "Verifica la conexion a internet o los repositorios configurados." >&2
        return 1
    fi

    echo "" >&2
    echo "  Versiones disponibles para $svc:" >&2
    local i
    for i in "${!versiones[@]}"; do
        local etiqueta=""
        [[ $i -eq $(( ${#versiones[@]} - 1 )) ]] && etiqueta="  <- Latest (desarrollo)"
        [[ $i -eq 0 ]] && etiqueta="  <- LTS (estable)"
        printf "    %2d) %s%s\n" "$((i+1))" "${versiones[$i]}" "$etiqueta" >&2
    done
    echo "" >&2

    local sel
    while true; do
        read -rp "  Seleccione version [1-${#versiones[@]}]: " sel </dev/tty
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#versiones[@]} )); then
            # Solo esto va a stdout: la version elegida (lo que captura la variable)
            echo "${versiones[$((sel-1))]}"
            return 0
        fi
        msg_warn "Seleccion invalida." >&2
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────

# Abre un puerto en el firewall
_http_fw_abrir() {
    local puerto="$1"

    # SELinux (AlmaLinux/RHEL): los servicios web no pueden bind a puertos no estandar
    # sin etiquetarlos como http_port_t.  Puertos ya incluidos: 80,443,8008,8009,8080,8443.
    if sestatus 2>/dev/null | grep -q "enabled"; then
        if ! command -v semanage &>/dev/null; then
            msg_info "SELinux activo — instalando policycoreutils-python-utils..."
            dnf install -y policycoreutils-python-utils &>/dev/null
        fi
        if command -v semanage &>/dev/null; then
            semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null \
                || semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
            msg_ok "SELinux: puerto $puerto etiquetado como http_port_t"
        else
            msg_warn "SELinux activo pero semanage no disponible. Si el servicio falla:"
            msg_warn "  dnf install policycoreutils-python-utils"
            msg_warn "  semanage port -a -t http_port_t -p tcp $puerto"
        fi
    fi

    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${puerto}/tcp" --quiet 2>/dev/null
        firewall-cmd --reload --quiet
        msg_ok "Firewall: puerto $puerto abierto (firewalld)"
    elif command -v ufw &>/dev/null; then
        ufw allow "${puerto}/tcp" > /dev/null 2>&1
        msg_ok "Firewall: puerto $puerto abierto (ufw)"
    else
        msg_warn "Firewall no detectado. Abre el puerto $puerto manualmente."
    fi
}

# Cierra un puerto en el firewall
_http_fw_cerrar() {
    local puerto="$1"
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --remove-port="${puerto}/tcp" --quiet 2>/dev/null
        firewall-cmd --reload --quiet
        msg_info "Firewall: puerto $puerto cerrado (firewalld)"
    elif command -v ufw &>/dev/null; then
        ufw delete allow "${puerto}/tcp" > /dev/null 2>&1
        msg_info "Firewall: puerto $puerto cerrado (ufw)"
    fi
}

# Cierra el puerto 80 si no lo esta usando el servicio activo
_http_fw_cerrar_defaults() {
    local puerto_activo="$1"
    for p in 80 8080; do
        [[ "$p" == "$puerto_activo" ]] && continue
        if ! _http_puerto_en_uso "$p"; then
            _http_fw_cerrar "$p"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# SEGURIDAD
# ─────────────────────────────────────────────────────────────────────────────

_http_seguridad_apache() {
    local puerto="$1"

    # 1. ServerTokens Prod + ServerSignature Off
    local sec_conf="/etc/httpd/conf.d/security.conf"
    for f in /etc/apache2/conf-available/security.conf \
              /etc/httpd/conf.d/security.conf \
              /etc/apache2/conf-enabled/security.conf; do
        [[ -f "$f" ]] && sec_conf="$f" && break
    done
    if [[ -f "$sec_conf" ]]; then
        grep -q "^ServerTokens"    "$sec_conf" \
            && sed -i 's/^ServerTokens.*/ServerTokens Prod/'     "$sec_conf" \
            || echo "ServerTokens Prod"    >> "$sec_conf"
        grep -q "^ServerSignature" "$sec_conf" \
            && sed -i 's/^ServerSignature.*/ServerSignature Off/' "$sec_conf" \
            || echo "ServerSignature Off"  >> "$sec_conf"
    else
        local conf_dir
        conf_dir=$(command -v apache2 &>/dev/null && echo "/etc/apache2/conf-available" || echo "/etc/httpd/conf.d")
        mkdir -p "$conf_dir"
        printf 'ServerTokens Prod\nServerSignature Off\n' > "$conf_dir/security.conf"
        sec_conf="$conf_dir/security.conf"
        command -v a2enconf &>/dev/null && a2enconf security &>/dev/null
    fi
    msg_ok "Apache: ServerTokens Prod + ServerSignature Off"

    # 2. TraceEnable Off en httpd.conf/apache2.conf
    local main_conf
    for f in /etc/apache2/apache2.conf /etc/httpd/conf/httpd.conf; do
        [[ -f "$f" ]] && main_conf="$f" && break
    done
    if [[ -n "$main_conf" ]]; then
        if grep -q "TraceEnable" "$main_conf"; then
            sed -i 's/^TraceEnable.*/TraceEnable Off/' "$main_conf"
        else
            echo "TraceEnable Off" >> "$main_conf"
        fi
        msg_ok "Apache: TraceEnable Off aplicado"
    fi

    # 3. Security headers + LimitExcept en conf.d (NO requiere AllowOverride)
    #    Aqui se incluye Referrer-Policy que el PDF requiere como 5o header
    local hdr_conf
    if command -v apache2 &>/dev/null; then
        hdr_conf="/etc/apache2/conf-available/http-manager-security.conf"
    else
        hdr_conf="/etc/httpd/conf.d/http-manager-security.conf"
    fi
    mkdir -p "$(dirname "$hdr_conf")"
    cat > "$hdr_conf" <<'HTEOF'
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>

<Directory "/var/www/html">
    AllowOverride All
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Directory>
HTEOF
    command -v a2enconf &>/dev/null && a2enconf http-manager-security &>/dev/null
    msg_ok "Apache: 4 security headers + LimitExcept en conf.d (incl. Referrer-Policy)"
}

# Helper: genera el server block completo de nginx con puerto y seguridad
_http_nginx_generar_conf() {
    local puerto="$1"
    local webroot="${2:-/usr/share/nginx/html}"
    mkdir -p /etc/nginx/conf.d
    # Usamos limit_except en vez de "if ($request_method)" porque:
    # - limit_except esta permitido en contexto location universalmente
    # - "if" en nginx tiene restricciones de contexto segun version/distro
    # - limit_except con return 405 cumple el requisito del PDF (metodos no permitidos -> 405)
    cat > "/etc/nginx/conf.d/http-manager.conf" <<NGINXEOF
server {
    listen $puerto default_server;
    listen [::]:$puerto default_server;
    server_name _;
    root $webroot;
    index index.html index.jsp;

    # Security headers (Referrer-Policy incluida — 5 headers requeridos por practica)
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        # Restriccion de metodos: solo GET, POST, HEAD
        # deny all retorna 403 — universalmente valido dentro de limit_except
        # (return no esta permitido dentro de limit_except en todas las versiones nginx)
        limit_except GET POST HEAD {
            deny all;
        }
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF
}

_http_seguridad_nginx() {
    local puerto="$1"

    # server_tokens off en bloque http de nginx.conf (afecta a todos los server blocks)
    # 0. Limpiar configs viejas con sintaxis incorrecta
    #    (versiones anteriores del script creaban security-headers.conf con directivas
    #     sueltas al nivel http — "if" y "add_header" sin server block, causando:
    #     nginx: [emerg] "if" directive is not allowed here in /etc/nginx/nginx.conf)
    for old_conf in /etc/nginx/conf.d/security-headers.conf \
                    /etc/nginx/sites-enabled/default \
                    /etc/nginx/conf.d/http-manager-security.conf; do
        if [[ -f "$old_conf" ]]; then
            mv "$old_conf" "${old_conf}.bak"
            msg_info "Config antigua movida a backup: $old_conf.bak"
        fi
    done

    local nginx_conf="/etc/nginx/nginx.conf"
    if [[ -f "$nginx_conf" ]]; then
        # 1. server_tokens off — ocultar version de nginx en header Server:
        if grep -q "server_tokens" "$nginx_conf"; then
            sed -i 's/.*server_tokens.*/    server_tokens off;/' "$nginx_conf"
        else
            sed -i '/http {/a\    server_tokens off;' "$nginx_conf"
        fi
        msg_ok "Nginx: server_tokens off en nginx.conf"

        # 2. Eliminar el server block inline de nginx.conf (AlmaLinux 9/10 incluye uno
        #    que siempre escucha en puerto 80 y entra en conflicto cuando otro servicio
        #    (Tomcat, Apache) ya ocupa ese puerto, impidiendo que nginx inicie aunque
        #    nuestro puerto personalizado este libre)
        if grep -qE '^\s*server\s*\{' "$nginx_conf"; then
            cp -n "$nginx_conf" "${nginx_conf}.orig" 2>/dev/null
            # Usar awk para eliminar el bloque server { } del archivo nginx.conf
            awk '
                BEGIN { skip=0; depth=0 }
                /^\s*server\s*\{/ && skip==0 { skip=1; depth=1; next }
                skip==1 {
                    for (i=1; i<=length($0); i++) {
                        c = substr($0, i, 1)
                        if (c == "{") depth++
                        else if (c == "}") { depth--; if (depth<=0) { skip=0; next } }
                    }
                    next
                }
                { print }
            ' "$nginx_conf" > /tmp/_nginx_clean.conf \
                && mv /tmp/_nginx_clean.conf "$nginx_conf" \
                && msg_ok "Nginx: server block inline eliminado de nginx.conf (evita conflicto en puerto 80)" \
                || msg_warn "Nginx: no se pudo limpiar nginx.conf — puede haber conflicto de puertos"
        fi
    fi

    # Generar/regenerar server block completo con todos los headers y restriccion de metodos
    # Usa limit_except (universalmente valido) en vez de "if ($request_method)"
    local webroot
    webroot=$(_http_webroot "nginx")
    _http_nginx_generar_conf "$puerto" "$webroot"
    msg_ok "Nginx: server block completo generado en conf.d/http-manager.conf"
    msg_ok "Nginx: 4 security headers + limit_except (GET|POST|HEAD -> resto 403)"
}

_http_seguridad_tomcat() {
    local puerto="$1"

    # 1. server.xml: ocultar version + deshabilitar TRACE
    local server_xml
    for f in /etc/tomcat*/server.xml /opt/tomcat/conf/server.xml; do
        [[ -f "$f" ]] && server_xml="$f" && break
    done
    if [[ -n "$server_xml" ]]; then
        # Ocultar version en header Server: (atributo 'server' del Connector)
        if grep -q 'server=' "$server_xml"; then
            sed -i 's/server="[^"]*"/server="Apache"/' "$server_xml"
        else
            sed -i 's/protocol="HTTP\/1\.1"/protocol="HTTP\/1.1" server="Apache"/' "$server_xml"
        fi
        # Deshabilitar TRACE mediante allowTrace="false"
        if grep -q 'allowTrace' "$server_xml"; then
            sed -i 's/allowTrace="[^"]*"/allowTrace="false"/' "$server_xml"
        else
            sed -i 's/protocol="HTTP\/1\.1"/protocol="HTTP\/1.1" allowTrace="false"/' "$server_xml"
        fi
        msg_ok "Tomcat: server.xml - Server=Apache + allowTrace=false"
    fi

    # 2. conf/web.xml global: HttpHeaderSecurityFilter con todos los parametros disponibles
    local web_xml
    for f in /etc/tomcat*/web.xml /opt/tomcat/conf/web.xml; do
        [[ -f "$f" ]] && web_xml="$f" && break
    done
    if [[ -n "$web_xml" ]]; then
        if ! grep -q "httpHeaderSecurity" "$web_xml"; then
            sed -i 's|</web-app>|    <filter>\
        <filter-name>httpHeaderSecurity</filter-name>\
        <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>\
        <init-param><param-name>antiClickJackingEnabled</param-name><param-value>true</param-value></init-param>\
        <init-param><param-name>antiClickJackingOption</param-name><param-value>SAMEORIGIN</param-value></init-param>\
        <init-param><param-name>blockContentTypeSniffingEnabled</param-name><param-value>true</param-value></init-param>\
        <init-param><param-name>xssProtectionEnabled</param-name><param-value>true</param-value></init-param>\
        <init-param><param-name>hstsEnabled</param-name><param-value>false</param-value></init-param>\
    </filter>\
    <filter-mapping><filter-name>httpHeaderSecurity</filter-name><url-pattern>/*</url-pattern></filter-mapping>\
</web-app>|' "$web_xml" 2>/dev/null
            msg_ok "Tomcat: HttpHeaderSecurityFilter con X-Frame, X-Content-Type, X-XSS"
        fi
    fi

    # 3. Crear/actualizar index.jsp en ROOT webapp para inyectar headers completos
    #    incluyendo Referrer-Policy (no soportado por HttpHeaderSecurityFilter en todas las versiones)
    #    JSP permite setHeader() sin compilar Java manualmente - Jasper lo compila al vuelo
    local webroot
    webroot=$(_http_webroot "tomcat")
    mkdir -p "$webroot"
    _http_crear_index "tomcat" "" "$puerto" "$webroot"
    msg_ok "Tomcat: index.jsp creado en: $webroot"

    # 4. Restringir metodos HTTP via security-constraint en ROOT/WEB-INF/web.xml
    local root_webinf="$webroot/WEB-INF"
    mkdir -p "$root_webinf"
    cat > "$root_webinf/web.xml" <<'WCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="http://xmlns.jcp.org/xml/ns/javaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://xmlns.jcp.org/xml/ns/javaee
         http://xmlns.jcp.org/xml/ns/javaee/web-app_4_0.xsd"
         version="4.0">
  <!-- Restriccion de metodos HTTP: solo GET, POST, HEAD -->
  <security-constraint>
    <web-resource-collection>
      <web-resource-name>Restricted Methods</web-resource-name>
      <url-pattern>/*</url-pattern>
      <http-method-omission>GET</http-method-omission>
      <http-method-omission>POST</http-method-omission>
      <http-method-omission>HEAD</http-method-omission>
    </web-resource-collection>
    <auth-constraint/>
  </security-constraint>
</web-app>
WCEOF
    msg_ok "Tomcat: WEB-INF/web.xml - metodos TRACE/DELETE/PUT bloqueados via security-constraint"
}

# Aplica configuracion de seguridad segun el servicio
http_aplicar_seguridad() {
    local svc="$1"
    local puerto="$2"

    msg_info "Aplicando configuracion de seguridad para $svc..."
    case "$svc" in
        apache2|apache|httpd) _http_seguridad_apache "$puerto" ;;
        nginx)                _http_seguridad_nginx  "$puerto" ;;
        tomcat*)              _http_seguridad_tomcat "$puerto" ;;
        *) msg_warn "Seguridad no implementada para: $svc" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# USUARIO DEDICADO POR SERVICIO
# ─────────────────────────────────────────────────────────────────────────────
_http_usuario_dedicado() {
    local svc="$1"
    local webroot="$2"
    local usuario

    case "$svc" in
        apache2|apache|httpd)
            # AlmaLinux/RHEL: corre como 'apache'
            # Debian/Ubuntu: corre como 'www-data'
            # Leer directamente del config de httpd para no asumir
            local cfg_user
            cfg_user=$(grep -rE '^User ' /etc/httpd/conf/httpd.conf \
                                         /etc/apache2/envvars 2>/dev/null \
                       | grep -oP '(?<=User )\S+' | head -1)
            if [[ -n "$cfg_user" ]]; then
                usuario="$cfg_user"
            elif id "apache" &>/dev/null; then
                usuario="apache"
            else
                usuario="www-data"
            fi
            ;;
        nginx)   usuario="nginx"  ;;
        tomcat*) usuario="tomcat" ;;
    esac

    msg_info "Usuario del servicio detectado: '$usuario'"

    # Crear usuario del sistema si no existe
    if ! id "$usuario" &>/dev/null; then
        useradd -r -s /sbin/nologin -d "$webroot" -M "$usuario" 2>/dev/null
        msg_ok "Usuario dedicado '$usuario' creado"
    fi

    # Permisos correctos: dirs 755, archivos 644
    # chmod 750 bloquearia a Apache si corre como 'other' respecto al owner
    if [[ -d "$webroot" ]]; then
        chown -R "$usuario:$usuario" "$webroot"
        find "$webroot" -type d -exec chmod 755 {} +
        find "$webroot" -type f -exec chmod 644 {} +
        msg_ok "Permisos asignados: $webroot -> $usuario (dirs:755, files:644)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CREAR INDEX.HTML PERSONALIZADO
# ─────────────────────────────────────────────────────────────────────────────
_http_crear_index() {
    local svc="$1"
    local version="$2"
    local puerto="$3"
    local webroot="$4"

    # Detectar usuario del servicio (mismo criterio que _http_usuario_dedicado)
    local usuario
    case "$svc" in
        apache2|apache|httpd)
            local cfg_user
            cfg_user=$(grep -rE '^User ' /etc/httpd/conf/httpd.conf \
                                         /etc/apache2/envvars 2>/dev/null \
                       | grep -oP '(?<=User )\S+' | head -1)
            if   [[ -n "$cfg_user" ]];          then usuario="$cfg_user"
            elif id "apache"   &>/dev/null;     then usuario="apache"
            else                                     usuario="www-data"
            fi ;;
        nginx)   usuario="nginx"  ;;
        tomcat*) usuario="tomcat" ;;
        *)       usuario="root"   ;;
    esac

    mkdir -p "$webroot"

    # Tomcat: crear index.jsp para inyectar headers via response.setHeader()
    # Jasper (motor JSP de Tomcat) compila el JSP al vuelo, sin necesitar javac manual
    if [[ "$svc" == "tomcat"* ]]; then
        cat > "$webroot/index.jsp" <<EOF
<%@ page contentType="text/html; charset=UTF-8" %>
<%
// Security headers — incluye Referrer-Policy que HttpHeaderSecurityFilter no soporta universalmente
response.setHeader("X-Frame-Options", "SAMEORIGIN");
response.setHeader("X-Content-Type-Options", "nosniff");
response.setHeader("X-XSS-Protection", "1; mode=block");
response.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
%>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>$svc</title>
    <style>
        body { font-family: monospace; background: #1a1a2e; color: #eee;
               display: flex; justify-content: center; align-items: center;
               height: 100vh; margin: 0; }
        .box { border: 2px solid #00d4ff; padding: 2rem 3rem; text-align: center; }
        h1   { color: #00d4ff; margin: 0 0 1rem; }
        p    { margin: 0.3rem 0; }
    </style>
</head>
<body>
    <div class="box">
        <h1>Servidor HTTP - AlmaLinux</h1>
        <p>Servidor desplegado exitosamente</p>
        <p>Servidor : <strong>$svc</strong></p>
        <p>Version  : <strong>$version</strong></p>
        <p>Puerto   : <strong>$puerto</strong></p>
        <p>Webroot  : <strong>$webroot</strong></p>
        <p>Usuario  : <strong>$usuario</strong></p>
    </div>
</body>
</html>
EOF
        msg_ok "index.jsp generado en: $webroot (con security headers via JSP)"
        return
    fi

    cat > "$webroot/index.html" <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>$svc</title>
    <style>
        body { font-family: monospace; background: #1a1a2e; color: #eee;
               display: flex; justify-content: center; align-items: center;
               height: 100vh; margin: 0; }
        .box { border: 2px solid #00d4ff; padding: 2rem 3rem; text-align: center; }
        h1   { color: #00d4ff; margin: 0 0 1rem; }
        p    { margin: 0.3rem 0; }
    </style>
</head>
<body>
    <div class="box">
        <h1>Servidor HTTP - AlmaLinux</h1>
        <p>Servidor desplegado exitosamente</p>
        <p>Servidor : <strong>$svc</strong></p>
        <p>Version  : <strong>$version</strong></p>
        <p>Puerto   : <strong>$puerto</strong></p>
        <p>Webroot  : <strong>$webroot</strong></p>
        <p>Usuario  : <strong>$usuario</strong></p>
    </div>
</body>
</html>
EOF
    msg_ok "index.html generado en: $webroot"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALACION DE TOMCAT DESDE TARBALL (fallback cuando no esta en repos)
# ─────────────────────────────────────────────────────────────────────────────
_http_instalar_tomcat_tarball() {
    local version="$1"
    local major="${version%%.*}"

    # Asegurar Java instalado
    if ! command -v java &>/dev/null; then
        msg_info "Instalando Java (requisito de Tomcat)..."
        dnf install -y java-17-openjdk-headless 2>/dev/null \
            || dnf install -y java-11-openjdk-headless 2>/dev/null \
            || { msg_err "No se pudo instalar Java"; return 1; }
    fi
    msg_ok "Java disponible: $(java -version 2>&1 | head -1)"

    # Crear usuario tomcat si no existe
    if ! id tomcat &>/dev/null; then
        useradd -r -s /sbin/nologin -d /opt/tomcat -M tomcat
        msg_ok "Usuario 'tomcat' creado"
    fi

    # Descargar tarball desde Apache CDN (con fallback a archive)
    local tmp="/tmp/apache-tomcat-${version}.tar.gz"
    local url1="https://dlcdn.apache.org/tomcat/tomcat-${major}/v${version}/bin/apache-tomcat-${version}.tar.gz"
    local url2="https://archive.apache.org/dist/tomcat/tomcat-${major}/v${version}/bin/apache-tomcat-${version}.tar.gz"

    msg_info "Descargando Apache Tomcat ${version}..."
    curl -fSL --max-time 120 "$url1" -o "$tmp" 2>/dev/null \
        || curl -fSL --max-time 120 "$url2" -o "$tmp" \
        || { msg_err "No se pudo descargar Tomcat ${version}"; return 1; }

    # Instalar en /opt/tomcat
    rm -rf /opt/tomcat
    mkdir -p /opt/tomcat
    tar -xzf "$tmp" -C /opt/tomcat --strip-components=1
    chown -R tomcat:tomcat /opt/tomcat
    chmod +x /opt/tomcat/bin/*.sh
    rm -f "$tmp"
    msg_ok "Tomcat ${version} extraido en /opt/tomcat"

    # Detectar JAVA_HOME
    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
    [[ ! -d "$java_home/bin" ]] && java_home="/usr/lib/jvm/jre"

    # Crear servicio systemd
    cat > "/etc/systemd/system/tomcat.service" <<SVCEOF
[Unit]
Description=Apache Tomcat ${version}
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=${java_home}"
Environment="CATALINA_PID=/opt/tomcat/temp/tomcat.pid"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="CATALINA_BASE=/opt/tomcat"
Environment="CATALINA_OPTS=-Xms512M -Xmx1024M"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    msg_ok "Servicio systemd 'tomcat' creado"
}

# ─────────────────────────────────────────────────────────────────────────────
# CAMBIAR PUERTO DE UN SERVICIO YA INSTALADO
# ─────────────────────────────────────────────────────────────────────────────
_http_aplicar_puerto_apache() {
    local puerto="$1"
    local ports_conf
    for f in /etc/apache2/ports.conf /etc/httpd/conf/httpd.conf; do
        [[ -f "$f" ]] && ports_conf="$f" && break
    done
    [[ -z "$ports_conf" ]] && msg_warn "No se encontro archivo de puertos de Apache" && return 1
    sed -i "s/Listen [0-9]*/Listen $puerto/g" "$ports_conf"
    # Actualizar VirtualHost si existe
    find /etc/apache2/sites-enabled /etc/httpd/conf.d -name "*.conf" 2>/dev/null \
        | xargs -I{} sed -i "s/<VirtualHost \*:[0-9]*>/<VirtualHost *:$puerto>/" {} 2>/dev/null
    msg_ok "Apache: puerto actualizado a $puerto en $ports_conf"
}

_http_aplicar_puerto_nginx() {
    local puerto="$1"
    local mgr_conf="/etc/nginx/conf.d/http-manager.conf"
    if [[ -f "$mgr_conf" ]]; then
        # Actualizar puerto en el server block ya generado
        sed -i "s/listen [0-9]* default_server/listen $puerto default_server/g" "$mgr_conf"
        sed -i "s/listen \[::\]:[0-9]* default_server/listen [::]:$puerto default_server/g" "$mgr_conf"
        msg_ok "Nginx: puerto actualizado a $puerto en http-manager.conf"
    else
        # Primera vez: generar server block completo
        local webroot
        webroot=$(_http_webroot "nginx")
        _http_nginx_generar_conf "$puerto" "$webroot"
        msg_ok "Nginx: configuracion creada en http-manager.conf (puerto $puerto)"
    fi
}

_http_aplicar_puerto_tomcat() {
    local puerto="$1"
    local server_xml
    for f in /etc/tomcat*/server.xml /opt/tomcat*/conf/server.xml; do
        [[ -f "$f" ]] && server_xml="$f" && break
    done
    [[ -z "$server_xml" ]] && msg_warn "No se encontro server.xml de Tomcat" && return 1
    sed -i "s/port=\"[0-9]*\" protocol=\"HTTP/port=\"$puerto\" protocol=\"HTTP/g" "$server_xml"
    msg_ok "Tomcat: puerto actualizado a $puerto en $server_xml"

    # ── Capability para puertos privilegiados (<1024) ───────────────────────
    # Tomcat corre como usuario 'tomcat' (no root). En Linux, puertos < 1024
    # requieren CAP_NET_BIND_SERVICE. Sin esto, el JVM arranca pero falla
    # silenciosamente al hacer bind → "ACTIVO" pero sin escuchar en el puerto.
    local sd
    sd=$(_http_servicio_systemd "tomcat")
    local sd_name="${sd:-tomcat}"
    local dropin_dir="/etc/systemd/system/${sd_name}.service.d"
    local dropin_file="${dropin_dir}/cap-net-bind.conf"

    if (( puerto < 1024 )); then
        mkdir -p "$dropin_dir"
        cat > "$dropin_file" <<'DROPIN'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
DROPIN
        systemctl daemon-reload
        msg_ok "Tomcat: CAP_NET_BIND_SERVICE activado — permite bind en puerto $puerto (< 1024)"
    else
        # Puerto alto: no necesita capability — limpiar drop-in si existia
        if [[ -f "$dropin_file" ]]; then
            rm -f "$dropin_file"
            systemctl daemon-reload
            msg_info "Tomcat: CAP_NET_BIND_SERVICE eliminado (no necesario para puerto $puerto)"
        fi
    fi
}

_http_aplicar_puerto() {
    local svc="$1" puerto="$2"
    case "$svc" in
        apache2|apache|httpd) _http_aplicar_puerto_apache "$puerto" ;;
        nginx)                _http_aplicar_puerto_nginx  "$puerto" ;;
        tomcat*)              _http_aplicar_puerto_tomcat "$puerto" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER INTERNO: instala y configura UN servicio con version y puerto ya decididos
# ─────────────────────────────────────────────────────────────────────────────
_http_instalar_uno() {
    local svc="$1" version="$2" puerto="$3"
    local pm; pm=$(_http_pkg_manager)
    local pkg; pkg=$(_http_pkg_nombre "$svc")
    msg_info "Instalando $pkg $version (gestor: $pm)..."

    if [[ "$pm" == "apt" ]]; then
        apt-get install -y "${pkg}=${version}" 2>/dev/null || apt-get install -y "$pkg"
    elif [[ "$svc" == "tomcat" ]]; then
        msg_info "Habilitando EPEL para Tomcat..."
        $pm install -y epel-release &>/dev/null && \
            $pm install -y "$pkg" &>/dev/null && \
            msg_ok "Tomcat instalado via dnf (EPEL)" || {
            msg_info "Tomcat no disponible en repos. Instalando desde tarball oficial..."
            _http_instalar_tomcat_tarball "$version" || return 1
        }
    else
        if [[ -n "$version" ]]; then
            $pm install -y "${pkg}-${version}" 2>/dev/null || $pm install -y "$pkg"
        else
            $pm install -y "$pkg"
        fi
    fi

    # Deshabilitar pagina de bienvenida por defecto
    case "$svc" in
        apache2|apache|httpd)
            for wc in /etc/httpd/conf.d/welcome.conf \
                      /etc/apache2/conf-enabled/welcome.conf \
                      /etc/apache2/conf-available/localized-error-pages.conf; do
                if [[ -f "$wc" && ! -f "${wc}.bak" ]]; then
                    mv "$wc" "${wc}.bak"
                    msg_ok "Deshabilitado: $wc (backup: ${wc}.bak)"
                fi
            done ;;
        nginx)
            local nginx_default="/etc/nginx/conf.d/default.conf"
            if [[ -f "$nginx_default" && ! -f "${nginx_default}.bak" ]]; then
                mv "$nginx_default" "${nginx_default}.bak"
                msg_ok "Deshabilitado: $nginx_default (backup guardado)"
            fi ;;
    esac

    msg_info "Configurando puerto $puerto ..."
    _http_aplicar_puerto "$svc" "$puerto"

    local webroot; webroot=$(_http_webroot "$svc")
    _http_usuario_dedicado "$svc" "$webroot"
    http_aplicar_seguridad "$svc" "$puerto"
    _http_crear_index "$svc" "$version" "$puerto" "$webroot"
    _http_fw_abrir "$puerto"

    local sd; sd=$(_http_servicio_systemd "$svc")
    if [[ -n "$sd" ]]; then
        systemctl enable "$sd" --quiet
        if systemctl restart "$sd" 2>/dev/null; then
            msg_ok "$svc iniciado (systemd: $sd)"
        else
            msg_err "$svc NO pudo iniciarse — revisa la configuracion:"
            systemctl status "$sd" --no-pager -l 2>/dev/null | tail -12 | sed 's/^/    /'
            msg_info "Detalle: journalctl -xeu $sd --no-pager | tail -30"
        fi
    fi

    _http_guardar_estado "$svc" "$puerto" "$version"
    msg_ok "$svc $version instalado en puerto $puerto"
    sleep 1
    local curl_body
    curl_body=$(curl -s --max-time 5 "http://localhost:$puerto" 2>/dev/null)
    if [[ -n "$curl_body" ]]; then
        local srv_line
        srv_line=$(echo "$curl_body" | grep -oP '(?<=Servidor : <strong>)[^<]+' | head -1)
        if [[ -n "$srv_line" ]]; then
            msg_ok "Pagina servida correctamente: $srv_line"
        else
            msg_ok "Servicio respondiendo en http://localhost:$puerto"
        fi
    else
        msg_warn "No se pudo verificar aun — el servicio puede tardar unos segundos"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. INSTALAR + CONFIGURAR SERVICIOS HTTP (multi-servicio)
# ─────────────────────────────────────────────────────────────────────────────
http_instalar() {
    echo ""
    echo "=== Instalar servidor(es) HTTP ==="
    echo ""
    echo "  Servicios disponibles:"
    echo "    1) Apache2"
    echo "    2) Nginx"
    echo "    3) Tomcat"
    echo ""
    echo "  Puede instalar uno o varios (ejemplos: 1 / 1 2 / 1 2 3):"
    echo ""

    local seleccion
    local -a svcs_instalar=()
    while true; do
        read -rp "  Seleccion: " seleccion
        svcs_instalar=()
        local ok=true
        for n in $seleccion; do
            case "$n" in
                1) svcs_instalar+=("apache2") ;;
                2) svcs_instalar+=("nginx")   ;;
                3) svcs_instalar+=("tomcat")  ;;
                *) msg_warn "Opcion invalida: $n"; ok=false; break ;;
            esac
        done
        $ok && [[ ${#svcs_instalar[@]} -gt 0 ]] && break
    done

    _http_leer_estado

    # Detener servicios huerfanos (no gestionados y no en la lista de instalacion)
    local -a _target_sds=()
    for svc in "${svcs_instalar[@]}"; do
        local _sd; _sd=$(_http_servicio_systemd "$svc")
        [[ -n "$_sd" ]] && _target_sds+=("$_sd")
    done
    for existing in "${HTTP_ACTIVE_SVCS[@]}"; do
        local _esd; _esd=$(_http_servicio_systemd "$existing")
        [[ -n "$_esd" ]] && _target_sds+=("$_esd")
    done
    for orphan in httpd apache2 nginx tomcat tomcat9 tomcat10; do
        local _is_t=false
        for t in "${_target_sds[@]}"; do [[ "$t" == "$orphan" ]] && _is_t=true && break; done
        if ! $_is_t && systemctl is-active --quiet "$orphan" 2>/dev/null; then
            msg_info "Servicio huerfano: $orphan — deteniendolo..."
            systemctl stop "$orphan" 2>/dev/null
            systemctl disable "$orphan" --quiet 2>/dev/null
            msg_ok "$orphan detenido."
        fi
    done

    # Recopilar version y puerto para cada servicio seleccionado
    declare -A _ver=()
    declare -A _pto=()
    declare -A _defaults=(["apache2"]="80" ["nginx"]="8080" ["tomcat"]="8082")

    for svc in "${svcs_instalar[@]}"; do
        echo ""
        echo "  ── Configurando $svc ──────────────────────────"
        local _varpto="HTTP_SVC_${svc//-/_}_PUERTO"
        if [[ -n "${!_varpto:-}" ]]; then
            msg_warn "$svc ya esta activo en puerto ${!_varpto}."
            read -rp "  Reinstalar? [s/N]: " _rein
            [[ "${_rein,,}" != "s" ]] && continue
        fi
        local _v
        _v=$(_http_seleccionar_version "$svc") || { msg_warn "Sin versiones para $svc — omitiendo"; continue; }
        _ver[$svc]="$_v"
        echo ""
        local _p
        _p=$(_http_pedir_puerto "${_defaults[$svc]:-80}" "$svc")
        _pto[$svc]="$_p"
    done

    # Instalar cada servicio configurado
    for svc in "${svcs_instalar[@]}"; do
        [[ -z "${_ver[$svc]:-}" ]] && continue
        echo ""
        echo "  ══════════════════════════════════════════════"
        echo "  Instalando $svc ${_ver[$svc]} en puerto ${_pto[$svc]}"
        echo "  ══════════════════════════════════════════════"
        _http_instalar_uno "$svc" "${_ver[$svc]}" "${_pto[$svc]}"
    done

    echo ""
    msg_ok "============================================="
    for svc in "${svcs_instalar[@]}"; do
        [[ -n "${_ver[$svc]:-}" ]] && msg_ok " $svc ${_ver[$svc]} en puerto ${_pto[$svc]}"
    done
    msg_ok "============================================="
    echo ""
    local _ip; _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    for svc in "${svcs_instalar[@]}"; do
        [[ -n "${_pto[$svc]:-}" ]] && msg_info "  http://${_ip:-localhost}:${_pto[$svc]}"
    done
    msg_info "Si ves contenido antiguo: Ctrl+Shift+R (hard refresh) en el navegador"
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. DESINSTALAR UN SERVICIO
# ─────────────────────────────────────────────────────────────────────────────
http_desinstalar_svc() {
    local svc="${1:-}"

    if [[ -z "$svc" ]]; then
        svc=$(_http_seleccionar_activo) || { pausar; return; }
    fi

    echo ""
    msg_info "Desinstalando $svc..."

    local sd; sd=$(_http_servicio_systemd "$svc")
    [[ -n "$sd" ]] && systemctl stop "$sd" 2>/dev/null && systemctl disable "$sd" --quiet 2>/dev/null

    local pm; pm=$(_http_pkg_manager)
    if [[ "$pm" == "apt" ]]; then
        case "$svc" in
            apache2) apt-get purge -y apache2 apache2-utils 2>/dev/null ;;
            nginx)   apt-get purge -y nginx nginx-common 2>/dev/null ;;
            tomcat*) apt-get purge -y tomcat* 2>/dev/null ;;
        esac
        apt-get autoremove -y --purge 2>/dev/null
    else
        case "$svc" in
            apache2|apache|httpd) dnf remove -y httpd 2>/dev/null ;;
            nginx)                dnf remove -y nginx 2>/dev/null ;;
            tomcat*)              dnf remove -y tomcat 2>/dev/null ;;
        esac
    fi

    local _puerto; _puerto=$(_http_puerto_de_svc "$svc")
    [[ -n "$_puerto" ]] && _http_fw_cerrar "$_puerto"

    _http_eliminar_estado "$svc"
    msg_ok "$svc desinstalado."
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CAMBIAR PUERTO (edge case)
# Verifica disponibilidad, confirma, cierra el puerto viejo, abre el nuevo.
# ─────────────────────────────────────────────────────────────────────────────
http_cambiar_puerto() {
    echo ""
    echo "=== Cambiar puerto del servicio HTTP ==="
    echo ""

    local svc
    svc=$(_http_seleccionar_activo) || { pausar; return; }

    _http_leer_estado
    local _varpto="HTTP_SVC_${svc//-/_}_PUERTO"
    local _varver="HTTP_SVC_${svc//-/_}_VERSION"
    local puerto_actual="${!_varpto:-?}"
    local version="${!_varver:-?}"

    msg_info "Servicio: $svc  |  Puerto actual: $puerto_actual"
    echo ""

    local nuevo_puerto
    nuevo_puerto=$(_http_pedir_puerto "$puerto_actual" "$svc")

    if [[ "$nuevo_puerto" == "$puerto_actual" ]]; then
        msg_warn "El nuevo puerto es igual al actual. Sin cambios."
        pausar; return
    fi

    echo ""
    msg_warn "Esto cerrara el puerto $puerto_actual y abrira el $nuevo_puerto."
    read -rp "  Confirmar cambio? [s/N]: " confirm
    [[ "${confirm,,}" != "s" ]] && msg_info "Operacion cancelada." && pausar && return

    _http_aplicar_puerto "$svc" "$nuevo_puerto"

    local webroot; webroot=$(_http_webroot "$svc")
    _http_crear_index "$svc" "$version" "$nuevo_puerto" "$webroot"

    _http_fw_cerrar "$puerto_actual"
    _http_fw_abrir  "$nuevo_puerto"

    local sd; sd=$(_http_servicio_systemd "$svc")
    if [[ -n "$sd" ]]; then
        if systemctl restart "$sd" 2>/dev/null; then
            msg_ok "$svc reiniciado"
        else
            msg_err "$svc NO pudo reiniciarse:"
            systemctl status "$sd" --no-pager -l 2>/dev/null | tail -8 | sed 's/^/    /'
        fi
    fi

    _http_guardar_estado "$svc" "$nuevo_puerto" "$version"
    msg_ok "Puerto cambiado: $puerto_actual -> $nuevo_puerto"
    echo ""
    msg_info "Verificacion: curl -I http://localhost:$nuevo_puerto"
    curl -sI "http://localhost:$nuevo_puerto" 2>/dev/null | head -5 | sed 's/^/    /' || true
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CAMBIAR DE SERVICIO WEB
# Desinstala el actual e instala uno nuevo desde cero.
# ─────────────────────────────────────────────────────────────────────────────
http_cambiar_servicio() {
    echo ""
    echo "=== Agregar o reemplazar servicio web ==="
    echo ""

    _http_leer_estado
    if [[ ${#HTTP_ACTIVE_SVCS[@]} -eq 0 ]]; then
        msg_info "No hay servicio activo. Redirigiendo a instalacion..."
        sleep 1; http_instalar; return
    fi

    echo "  Servicios activos: ${HTTP_ACTIVE_SVCS[*]}"
    echo "  1) Agregar nuevo servicio (mantener los existentes)"
    echo "  2) Reemplazar un servicio existente"
    echo ""
    read -rp "  Opcion [1/2]: " _opc

    if [[ "$_opc" == "2" ]]; then
        local svc; svc=$(_http_seleccionar_activo) || { pausar; return; }
        msg_warn "Esto desinstalara $svc completamente."
        read -rp "  Continuar? [s/N]: " confirm
        [[ "${confirm,,}" != "s" ]] && msg_info "Cancelado." && pausar && return
        http_desinstalar_svc "$svc"
        sleep 1
    fi
    http_instalar
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. MONITOREO
# ─────────────────────────────────────────────────────────────────────────────
http_monitoreo() {
    while true; do
        clear
        echo ""
        echo "----------------------------------------------"
        echo "            MONITOREO HTTP                    "
        echo "----------------------------------------------"
        echo "  1. Estado de servicios HTTP"
        echo "  2. Puertos en uso"
        echo "  3. Puertos NO accesibles (cerrados)"
        echo "  4. Logs / ultimos errores"
        echo "  5. Configuracion y estatus actual"
        echo "  6. Auditoria de seguridad (curl + headers)"
        echo "  0. Volver"
        echo "----------------------------------------------"
        read -rp "  Opcion: " opc
        case "$opc" in
            1) _http_mon_estado     ;;
            2) _http_mon_puertos    ;;
            3) _http_mon_cerrados   ;;
            4) _http_mon_logs       ;;
            5) _http_mon_config     ;;
            6) _http_mon_auditoria  ;;
            0) return ;;
            *) msg_warn "Opcion invalida." ; sleep 1 ;;
        esac
    done
}

# Auditoria automatica de seguridad: verifica cada header y restriccion de metodos
_http_mon_auditoria() {
    echo ""
    echo "=== Auditoria de Seguridad HTTP ==="
    echo ""
    local svc
    svc=$(_http_seleccionar_activo) || { pausar; return; }
    _http_leer_estado
    local _vp="HTTP_SVC_${svc//-/_}_PUERTO"
    local HTTP_SVC="$svc"
    local HTTP_PUERTO="${!_vp:-?}"

    local url="http://localhost:${HTTP_PUERTO}"
    msg_info "Servicio: $HTTP_SVC  |  Puerto: $HTTP_PUERTO"
    msg_info "Ejecutando: curl -sI $url"
    echo ""

    # Capturar headers una sola vez
    local headers
    headers=$(curl -sI --max-time 5 "$url" 2>/dev/null)

    if [[ -z "$headers" ]]; then
        msg_err "No se pudo conectar a $url — servicio inactivo?"
        pausar
        return
    fi

    # Helper local para verificar header
    _check_header() {
        local nombre="$1"
        local patron="$2"
        if echo "$headers" | grep -qi "$patron"; then
            local valor
            valor=$(echo "$headers" | grep -i "$patron" | head -1 | sed 's/\r//')
            msg_ok  "$nombre PRESENTE    -> $valor"
        else
            msg_warn "$nombre AUSENTE"
        fi
    }

    echo "  ── Headers de respuesta ──────────────────────"
    _check_header "Server (sin version)" "^Server:"
    _check_header "X-Frame-Options      " "X-Frame-Options"
    _check_header "X-Content-Type-Options" "X-Content-Type-Options"
    _check_header "X-XSS-Protection     " "X-XSS-Protection"
    _check_header "Referrer-Policy      " "Referrer-Policy"
    echo ""

    # Verificar que Server no exponga version exacta
    local server_hdr
    server_hdr=$(echo "$headers" | grep -i "^Server:" | head -1)
    if echo "$server_hdr" | grep -qiE "Apache/[0-9]|nginx/[0-9]|Tomcat/[0-9]"; then
        msg_warn "Server expone version: $server_hdr  <- MALO"
    else
        msg_ok  "Server no expone version exacta  -> $server_hdr"
    fi
    echo ""

    echo "  ── Metodos HTTP ──────────────────────────────"
    local _trace_out _delete_out _put_out _get_out
    _trace_out=$(curl -s -o /dev/null -w "%{http_code}" -X TRACE  --max-time 5 "$url" 2>/dev/null)
    _delete_out=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE --max-time 5 "$url" 2>/dev/null)
    _put_out=$(curl -s -o /dev/null   -w "%{http_code}" -X PUT    --max-time 5 "$url" 2>/dev/null)
    _get_out=$(curl -s -o /dev/null   -w "%{http_code}" -X GET    --max-time 5 "$url" 2>/dev/null)

    [[ "$_trace_out"  =~ ^(405|403|501)$ ]] && msg_ok "TRACE  bloqueado ($HTTP_SVC devuelve $_trace_out)"   || msg_warn "TRACE  NO bloqueado: $_trace_out  <- MALO"
    [[ "$_delete_out" =~ ^(405|403|501)$ ]] && msg_ok "DELETE bloqueado ($HTTP_SVC devuelve $_delete_out)"  || msg_warn "DELETE NO bloqueado: $_delete_out  <- MALO"
    [[ "$_put_out"    =~ ^(405|403|501)$ ]] && msg_ok "PUT    bloqueado ($HTTP_SVC devuelve $_put_out)"     || msg_warn "PUT    NO bloqueado: $_put_out    <- MALO"
    [[ "$_get_out"    =~ ^(200|301|302)$ ]] && msg_ok "GET    funciona  ($HTTP_SVC devuelve $_get_out)"     || msg_warn "GET    NO funciona:  $_get_out"
    echo ""

    echo "  ── Usuario dedicado ──────────────────────────"
    local svc_usr
    case "$HTTP_SVC" in
        apache2|apache|httpd) svc_usr="apache"  ;;
        nginx)                svc_usr="nginx"   ;;
        tomcat*)              svc_usr="tomcat"  ;;
    esac
    if getent passwd "$svc_usr" | grep -q "/sbin/nologin"; then
        msg_ok  "Usuario '$svc_usr' tiene shell=/sbin/nologin"
    else
        msg_warn "Usuario '$svc_usr' no encontrado o no tiene /sbin/nologin"
    fi
    echo ""

    echo "  ── Firewall ──────────────────────────────────"
    if firewall-cmd --list-ports 2>/dev/null | grep -q "${HTTP_PUERTO}/tcp"; then
        msg_ok  "Puerto ${HTTP_PUERTO}/tcp abierto en firewalld"
    else
        msg_warn "Puerto ${HTTP_PUERTO}/tcp no aparece en firewalld"
    fi
    if ! curl -s --connect-timeout 2 "http://localhost:80" &>/dev/null && [[ "$HTTP_PUERTO" != "80" ]]; then
        msg_ok  "Puerto 80 (default) inaccesible — correctamente cerrado"
    fi
    echo ""

    pausar
}

_http_mon_estado() {
    echo ""
    echo "=== Estado de servicios HTTP ==="
    echo ""
    for svc in apache2 httpd nginx tomcat tomcat9 tomcat10; do
        if systemctl list-units --type=service --all 2>/dev/null | grep -q "${svc}.service"; then
            local estado
            estado=$(systemctl is-active "$svc" 2>/dev/null)
            if [[ "$estado" == "active" ]]; then
                msg_ok  "$svc: ACTIVO"
            else
                msg_warn "$svc: $estado"
            fi
            systemctl status "$svc" --no-pager -l 2>/dev/null | grep -E "Active:|Main PID:" | sed 's/^/    /'
        fi
    done
    echo ""
    _http_leer_estado
    [[ -n "${HTTP_SVC:-}" ]] && msg_info "Servicio gestionado: $HTTP_SVC  |  Puerto: $HTTP_PUERTO  |  Version: ${HTTP_VERSION:-?}"
    pausar
}

_http_mon_puertos() {
    echo ""
    echo "=== Puertos HTTP en uso ==="
    echo ""
    ss -tlnp 2>/dev/null | grep -E ":(80|8080|8888|443|[0-9]{4,5})\b" | \
        awk '{printf "    %-30s %s\n", $4, $6}' | head -20
    echo ""
    echo "  Todos los puertos TCP en escucha:"
    ss -tlnp 2>/dev/null | awk 'NR>1{printf "    %-25s %s\n", $4, $6}' | head -20
    pausar
}

_http_mon_cerrados() {
    echo ""
    echo "=== Puertos HTTP comunes NO accesibles ==="
    echo ""
    local -a puertos_check=(80 8080 8888 443 3000 5000)
    for p in "${puertos_check[@]}"; do
        if _http_puerto_en_uso "$p"; then
            msg_ok  "Puerto $p: ABIERTO (en uso)"
        else
            msg_warn "Puerto $p: CERRADO / no en uso"
        fi
    done
    pausar
}

_http_mon_logs() {
    echo ""
    echo "=== Ultimos errores de servicios HTTP ==="
    echo ""
    local svc
    svc=$(_http_seleccionar_activo) || { pausar; return; }

    local log_file
    case "$svc" in
        apache2|httpd) log_file="/var/log/apache2/error.log"
                       [[ ! -f "$log_file" ]] && log_file="/var/log/httpd/error_log" ;;
        nginx)         log_file="/var/log/nginx/error.log" ;;
        tomcat*)       log_file="/var/log/tomcat*/catalina.out"
                       log_file=$(ls $log_file 2>/dev/null | head -1) ;;
    esac

    if [[ -n "$log_file" && -f "$log_file" ]]; then
        msg_info "Ultimas 20 lineas de: $log_file"
        echo ""
        tail -20 "$log_file" 2>/dev/null | sed 's/^/    /'
    else
        msg_warn "No se encontro archivo de log para $svc"
        msg_info "Log via journalctl:"
        local sd
        sd=$(_http_servicio_systemd "$svc")
        [[ -n "$sd" ]] && journalctl -u "$sd" --no-pager -n 20 2>/dev/null | sed 's/^/    /'
    fi
    pausar
}

_http_mon_config() {
    echo ""
    echo "=== Configuracion y estatus actual ==="
    echo ""
    local svc
    svc=$(_http_seleccionar_activo) || { pausar; return; }
    _http_leer_estado
    local _vp="HTTP_SVC_${svc//-/_}_PUERTO"
    local _vv="HTTP_SVC_${svc//-/_}_VERSION"
    local HTTP_SVC="$svc"
    local HTTP_PUERTO="${!_vp:-?}"
    local HTTP_VERSION="${!_vv:-desconocida}"

    msg_info "Servicio  : $HTTP_SVC"
    msg_info "Version   : ${HTTP_VERSION:-desconocida}"
    msg_info "Puerto    : $HTTP_PUERTO"

    local webroot
    webroot=$(_http_webroot "$HTTP_SVC")
    msg_info "Webroot   : $webroot"

    echo ""
    echo "  Headers de respuesta (curl -I):"
    curl -sI "http://localhost:$HTTP_PUERTO" 2>/dev/null | sed 's/^/    /' || \
        msg_warn "    No se pudo conectar al servicio"

    echo ""
    echo "  Archivos de config:"
    case "$HTTP_SVC" in
        apache2|httpd)
            for f in /etc/apache2/ports.conf /etc/httpd/conf/httpd.conf \
                     /etc/apache2/conf-available/security.conf; do
                [[ -f "$f" ]] && echo "    $f" && grep -E "Listen|ServerTokens|ServerSignature|TraceEnable" "$f" \
                    2>/dev/null | sed 's/^/      /'
            done ;;
        nginx)
            for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/default.conf \
                     /etc/nginx/sites-enabled/default; do
                [[ -f "$f" ]] && echo "    $f" && grep -E "listen|server_tokens" "$f" \
                    2>/dev/null | head -5 | sed 's/^/      /'
            done ;;
        tomcat*)
            local server_xml
            for f in /etc/tomcat*/server.xml /opt/tomcat*/conf/server.xml; do
                [[ -f "$f" ]] && server_xml="$f" && break
            done
            [[ -n "$server_xml" ]] && echo "    $server_xml" && \
                grep -E "port=|protocol=" "$server_xml" 2>/dev/null | head -5 | sed 's/^/      /' ;;
    esac
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. REINICIAR SERVICIO ACTIVO
# ─────────────────────────────────────────────────────────────────────────────
http_reiniciar() {
    local svc
    svc=$(_http_seleccionar_activo) || { pausar; return; }

    local sd; sd=$(_http_servicio_systemd "$svc")
    if [[ -z "$sd" ]]; then
        msg_err "No se pudo determinar el servicio systemd para '$svc'."
        msg_info "Ejecuta: systemctl list-units --type=service --all | grep $svc"
        pausar; return
    fi
    msg_info "Reiniciando $svc ($sd)..."
    if systemctl restart "$sd" 2>/dev/null; then
        systemctl status "$sd" --no-pager -l 2>/dev/null | head -6 | sed 's/^/  /'
        msg_ok "$svc reiniciado."
    else
        msg_err "$svc NO pudo reiniciarse — revisa la configuracion:"
        systemctl status "$sd" --no-pager -l 2>/dev/null | tail -10 | sed 's/^/    /'
        msg_info "Detalle: journalctl -xeu $sd --no-pager | tail -30"
    fi
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. VERIFICAR ESTADO (resumen rapido)
# ─────────────────────────────────────────────────────────────────────────────
http_verificar() {
    echo ""
    echo "=== Estado de servicios HTTP ==="
    echo ""
    _http_leer_estado

    if [[ ${#HTTP_ACTIVE_SVCS[@]} -eq 0 ]]; then
        msg_warn "No hay ningun servicio HTTP gestionado aun."
        pausar; return
    fi

    for svc in "${HTTP_ACTIVE_SVCS[@]}"; do
        local _vp="HTTP_SVC_${svc//-/_}_PUERTO"
        local _vv="HTTP_SVC_${svc//-/_}_VERSION"
        local _pto="${!_vp:-?}"
        local _ver="${!_vv:-?}"
        local sd; sd=$(_http_servicio_systemd "$svc")
        echo ""
        msg_info "Servicio : $svc  |  Version: $_ver  |  Puerto: $_pto"
        if systemctl is-active --quiet "$sd" 2>/dev/null; then
            msg_ok "$sd esta ACTIVO"
        else
            msg_warn "$sd esta INACTIVO"
        fi
        echo "  curl -I http://localhost:$_pto"
        local curl_hdrs
        curl_hdrs=$(curl -sI --max-time 5 "http://localhost:$_pto" 2>/dev/null)
        if [[ -n "$curl_hdrs" ]]; then
            echo "$curl_hdrs" | head -5 | sed 's/^/    /'
        else
            msg_warn "    No se pudo conectar a http://localhost:$_pto"
            msg_info "    Pista: journalctl -xeu $sd --no-pager | tail -20"
        fi
    done
    echo ""
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU DEL MODULO HTTP
# ─────────────────────────────────────────────────────────────────────────────
menu_http() {
    while true; do
        clear
        echo ""
        _http_leer_estado
        local info_activo="(ninguno)"
        if [[ ${#HTTP_ACTIVE_SVCS[@]} -gt 0 ]]; then
            local _parts=()
            for _ms in "${HTTP_ACTIVE_SVCS[@]}"; do
                local _mp="HTTP_SVC_${_ms//-/_}_PUERTO"
                _parts+=("$_ms:${!_mp:-?}")
            done
            info_activo=$(IFS=', '; echo "${_parts[*]}")
        fi
        echo "----------------------------------------------"
        echo "       ADMINISTRACION SERVIDOR HTTP           "
        echo "            Apache / Nginx / Tomcat           "
        echo "----------------------------------------------"
        echo "  Activo: $info_activo"
        echo "----------------------------------------------"
        echo "  1. Verificar estado"
        echo "  2. Instalar servicio web"
        echo "  3. Cambiar puerto"
        echo "  4. Cambiar a otro servicio"
        echo "  5. Desinstalar servicio"
        echo "  6. Reiniciar servicio"
        echo "  7. Seguridad (aplicar/reforzar)"
        echo "  8. Monitoreo"
        echo "  0. Volver"
        echo "----------------------------------------------"
        read -rp "  Opcion: " opc
        case "$opc" in
            1) http_verificar        ;;
            2) http_instalar         ;;
            3) http_cambiar_puerto   ;;
            4) http_cambiar_servicio ;;
            5) http_desinstalar_svc  ;;
            6) http_reiniciar        ;;
            7)
                local _sec_svc
                _sec_svc=$(_http_seleccionar_activo) || { pausar; continue; }
                _http_leer_estado
                local _sec_vp="HTTP_SVC_${_sec_svc//-/_}_PUERTO"
                http_aplicar_seguridad "$_sec_svc" "${!_sec_vp:-80}"
                local _sec_sd; _sec_sd=$(_http_servicio_systemd "$_sec_svc")
                [[ -n "$_sec_sd" ]] && systemctl restart "$_sec_sd"
                msg_ok "Seguridad aplicada y servicio reiniciado."
                pausar
                ;;
            8) http_monitoreo ;;
            0) return ;;
            *) msg_warn "Opcion invalida." ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA STANDALONE
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ $EUID -ne 0 ]] && msg_err "Ejecuta con sudo o como root." && exit 1
    menu_http
fi
