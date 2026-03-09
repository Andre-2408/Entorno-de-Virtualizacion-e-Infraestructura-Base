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
        tomcat*)        systemctl list-units --type=service --all 2>/dev/null \
                            | grep -oP 'tomcat[0-9]*(?=\.service)' | head -1 ;;
    esac
}

# Devuelve el webroot del servicio
_http_webroot() {
    local svc="$1"
    case "$svc" in
        apache2|apache|httpd) echo "/var/www/html" ;;
        nginx)                echo "/usr/share/nginx/html" ;;
        tomcat*)
            local tc_home
            tc_home=$(find /var/lib -maxdepth 1 -name "tomcat*" -type d 2>/dev/null | sort -V | tail -1)
            echo "${tc_home}/webapps/ROOT"
            ;;
    esac
}

# Guarda estado: servicio activo + puerto activo
_http_guardar_estado() {
    local svc="$1" puerto="$2" version="$3"
    mkdir -p "$(dirname "$HTTP_STATE_FILE")"
    # Comillas en los valores para que bash pueda hacer source sin errores
    # aunque la version tenga caracteres especiales (guiones, puntos, etc.)
    printf 'HTTP_SVC="%s"\nHTTP_PUERTO="%s"\nHTTP_VERSION="%s"\n' \
        "$svc" "$puerto" "$version" > "$HTTP_STATE_FILE"
}

# Lee estado guardado
_http_leer_estado() {
    [[ -f "$HTTP_STATE_FILE" ]] && source "$HTTP_STATE_FILE"
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
    # Notar: \$ escapa variables nginx para que bash no las expanda
    cat > "/etc/nginx/conf.d/http-manager.conf" <<NGINXEOF
server {
    listen $puerto default_server;
    listen [::]:$puerto default_server;
    server_name _;
    root $webroot;
    index index.html index.jsp;

    # Security headers (Referrer-Policy incluida)
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        if (\$request_method !~ ^(GET|POST|HEAD)$) {
            return 405;
        }
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF
}

_http_seguridad_nginx() {
    local puerto="$1"

    # server_tokens off en bloque http de nginx.conf (afecta a todos los server blocks)
    local nginx_conf="/etc/nginx/nginx.conf"
    if [[ -f "$nginx_conf" ]]; then
        if grep -q "server_tokens" "$nginx_conf"; then
            sed -i 's/.*server_tokens.*/    server_tokens off;/' "$nginx_conf"
        else
            sed -i '/http {/a\    server_tokens off;' "$nginx_conf"
        fi
        msg_ok "Nginx: server_tokens off en nginx.conf"
    fi

    # Generar/regenerar server block completo con todos los headers y restriccion de metodos
    # Los add_header e if ($request_method) DEBEN estar dentro de un bloque server/location,
    # no como directivas sueltas en conf.d (causaria error de sintaxis)
    local webroot
    webroot=$(_http_webroot "nginx")
    _http_nginx_generar_conf "$puerto" "$webroot"
    msg_ok "Nginx: server block completo generado en conf.d/http-manager.conf"
    msg_ok "Nginx: 4 security headers + restriccion de metodos configurados"
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
    [[ -d "$webroot" ]] && _http_crear_index "tomcat" "" "$puerto" "$webroot"
    msg_ok "Tomcat: index.jsp con todos los security headers generado"

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
# 1. INSTALAR + CONFIGURAR SERVICIO HTTP (flujo completo)
# ─────────────────────────────────────────────────────────────────────────────
http_instalar() {
    echo ""
    echo "=== Instalar servidor HTTP ==="
    echo ""

    # ── Paso 1: Seleccionar servicio ─────────────────────────────────────────
    echo "  Servicios disponibles:"
    echo "    1) Apache2"
    echo "    2) Nginx"
    echo "    3) Tomcat"
    echo ""

    local svc
    while true; do
        read -rp "  Seleccione servicio [1-3]: " opc
        case "$opc" in
            1) svc="apache2" ; break ;;
            2) svc="nginx"   ; break ;;
            3) svc="tomcat"  ; break ;;
            *) msg_warn "Opcion invalida." ;;
        esac
    done

    # Si ya hay un servicio activo diferente, advertir
    _http_leer_estado
    if [[ -n "${HTTP_SVC:-}" && "$HTTP_SVC" != "$svc" ]]; then
        echo ""
        msg_warn "Ya hay un servicio activo: $HTTP_SVC (puerto $HTTP_PUERTO)"
        read -rp "  Desea reemplazarlo con $svc? [s/N]: " confirm
        if [[ "${confirm,,}" != "s" ]]; then
            msg_info "Instalacion cancelada."
            pausar
            return
        fi
        msg_info "Desinstalando $HTTP_SVC antes de continuar..."
        http_desinstalar_svc "$HTTP_SVC"
    fi

    # ── Paso 2: Seleccionar version ──────────────────────────────────────────
    local version
    version=$(_http_seleccionar_version "$svc") || { pausar; return; }

    # ── Paso 3: Seleccionar puerto ───────────────────────────────────────────
    echo ""
    local puerto
    puerto=$(_http_pedir_puerto 80 "$svc")

    # ── Paso 4: Instalar ─────────────────────────────────────────────────────
    echo ""
    local pm
    pm=$(_http_pkg_manager)
    local pkg
    pkg=$(_http_pkg_nombre "$svc")
    msg_info "Instalando $pkg $version (gestor: $pm)..."

    if [[ "$pm" == "apt" ]]; then
        # apt: version con formato paquete=version
        apt-get install -y "${pkg}=${version}" 2>/dev/null || apt-get install -y "$pkg"
    elif [[ "$svc" == "tomcat" ]]; then
        # Tomcat en RHEL/AlmaLinux: NO esta en repos base
        # 1) Intentar EPEL (disponible en AlmaLinux 8, limitado en 9)
        msg_info "Habilitando EPEL para Tomcat..."
        $pm install -y epel-release &>/dev/null && \
            $pm install -y "$pkg" &>/dev/null && \
            msg_ok "Tomcat instalado via dnf (EPEL)" || {
            # 2) Fallback: instalar desde tarball oficial de Apache
            msg_info "Tomcat no disponible en repos. Instalando desde tarball oficial..."
            _http_instalar_tomcat_tarball "$version" || { pausar; return; }
        }
    else
        # Apache/Nginx en dnf: instalar normalmente
        if [[ -n "$version" ]]; then
            $pm install -y "${pkg}-${version}" 2>/dev/null || $pm install -y "$pkg"
        else
            $pm install -y "$pkg"
        fi
    fi

    # ── Paso 4.5: Deshabilitar pagina de bienvenida por defecto ─────────────
    # AlmaLinux/RHEL: welcome.conf intercepta "/" y muestra su propia pagina
    # aunque exista un index.html en el webroot. Hay que desactivarla.
    case "$svc" in
        apache2|apache|httpd)
            for wc in /etc/httpd/conf.d/welcome.conf \
                      /etc/apache2/conf-enabled/welcome.conf \
                      /etc/apache2/conf-available/localized-error-pages.conf; do
                if [[ -f "$wc" && ! -f "${wc}.bak" ]]; then
                    mv "$wc" "${wc}.bak"
                    msg_ok "Deshabilitado: $wc (backup: ${wc}.bak)"
                fi
            done
            ;;
        nginx)
            # Eliminar bloque default que muestra pagina nginx en /etc/nginx/conf.d/default.conf
            local nginx_default="/etc/nginx/conf.d/default.conf"
            if [[ -f "$nginx_default" && ! -f "${nginx_default}.bak" ]]; then
                mv "$nginx_default" "${nginx_default}.bak"
                msg_ok "Deshabilitado: $nginx_default (backup guardado)"
            fi
            ;;
    esac

    # ── Paso 5: Configurar puerto ────────────────────────────────────────────
    msg_info "Configurando puerto $puerto ..."
    _http_aplicar_puerto "$svc" "$puerto"

    # ── Paso 6: Crear usuario dedicado + permisos ────────────────────────────
    local webroot
    webroot=$(_http_webroot "$svc")
    _http_usuario_dedicado "$svc" "$webroot"

    # ── Paso 7: Seguridad ────────────────────────────────────────────────────
    http_aplicar_seguridad "$svc" "$puerto"

    # ── Paso 8: index.html personalizado ────────────────────────────────────
    _http_crear_index "$svc" "$version" "$puerto" "$webroot"

    # ── Paso 9: Firewall ─────────────────────────────────────────────────────
    _http_fw_abrir "$puerto"
    _http_fw_cerrar_defaults "$puerto"

    # ── Paso 10: Iniciar servicio ─────────────────────────────────────────────
    local sd
    sd=$(_http_servicio_systemd "$svc")
    if [[ -n "$sd" ]]; then
        systemctl enable  "$sd" --quiet
        systemctl restart "$sd"
        msg_ok "$svc iniciado (systemd: $sd)"
    fi

    # ── Guardar estado ────────────────────────────────────────────────────────
    _http_guardar_estado "$svc" "$puerto" "$version"

    echo ""
    msg_ok "============================================="
    msg_ok " $svc $version instalado en puerto $puerto"
    msg_ok "============================================="
    echo ""
    msg_info "Verificacion con curl:"
    echo "    curl -I http://localhost:$puerto"
    echo ""
    curl -sI "http://localhost:$puerto" 2>/dev/null | head -5 | sed 's/^/    /' || \
        msg_warn "No se pudo verificar (el servicio puede tardar unos segundos)"
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. DESINSTALAR UN SERVICIO
# ─────────────────────────────────────────────────────────────────────────────
http_desinstalar_svc() {
    local svc="${1:-}"

    if [[ -z "$svc" ]]; then
        _http_leer_estado
        svc="${HTTP_SVC:-}"
    fi

    if [[ -z "$svc" ]]; then
        msg_warn "No hay servicio activo registrado."
        pausar
        return
    fi

    echo ""
    msg_info "Desinstalando $svc..."

    local sd
    sd=$(_http_servicio_systemd "$svc")
    [[ -n "$sd" ]] && systemctl stop "$sd" 2>/dev/null && systemctl disable "$sd" --quiet 2>/dev/null

    if command -v apt-get &>/dev/null; then
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

    # Cerrar su puerto en el firewall
    _http_leer_estado
    [[ -n "${HTTP_PUERTO:-}" ]] && _http_fw_cerrar "$HTTP_PUERTO"

    # Limpiar estado guardado
    rm -f "$HTTP_STATE_FILE"
    msg_ok "$svc desinstalado."
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CAMBIAR PUERTO (edge case)
# Verifica disponibilidad, confirma, cierra el puerto viejo, abre el nuevo.
# ─────────────────────────────────────────────────────────────────────────────
http_cambiar_puerto() {
    echo ""
    echo "=== Cambiar puerto del servicio HTTP ==="
    echo ""

    _http_leer_estado
    if [[ -z "${HTTP_SVC:-}" ]]; then
        msg_warn "No hay ningun servicio HTTP activo."
        pausar
        return
    fi

    msg_info "Servicio activo: $HTTP_SVC  |  Puerto actual: $HTTP_PUERTO"
    echo ""

    # Pedir nuevo puerto (con validacion)
    local nuevo_puerto
    nuevo_puerto=$(_http_pedir_puerto "${HTTP_PUERTO}" "$HTTP_SVC")

    if [[ "$nuevo_puerto" == "$HTTP_PUERTO" ]]; then
        msg_warn "El nuevo puerto es igual al actual. Sin cambios."
        pausar
        return
    fi

    # Confirmacion
    echo ""
    msg_warn "Esto cerrara el puerto $HTTP_PUERTO y abrira el $nuevo_puerto."
    read -rp "  Confirmar cambio? [s/N]: " confirm
    [[ "${confirm,,}" != "s" ]] && msg_info "Operacion cancelada." && pausar && return

    # Aplicar en config del servicio
    _http_aplicar_puerto "$HTTP_SVC" "$nuevo_puerto"

    # Actualizar index.html
    local webroot
    webroot=$(_http_webroot "$HTTP_SVC")
    _http_crear_index "$HTTP_SVC" "$HTTP_VERSION" "$nuevo_puerto" "$webroot"

    # Firewall: cerrar viejo, abrir nuevo
    _http_fw_cerrar "$HTTP_PUERTO"
    _http_fw_abrir  "$nuevo_puerto"

    # Reiniciar servicio
    local sd
    sd=$(_http_servicio_systemd "$HTTP_SVC")
    [[ -n "$sd" ]] && systemctl restart "$sd" && msg_ok "$HTTP_SVC reiniciado"

    # Guardar nuevo estado
    _http_guardar_estado "$HTTP_SVC" "$nuevo_puerto" "$HTTP_VERSION"

    msg_ok "Puerto cambiado: $HTTP_PUERTO -> $nuevo_puerto"
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
    echo "=== Cambiar servicio web ==="
    echo ""

    _http_leer_estado
    if [[ -z "${HTTP_SVC:-}" ]]; then
        msg_info "No hay servicio activo. Redirigiendo a instalacion..."
        sleep 1
        http_instalar
        return
    fi

    msg_warn "Servicio actual: $HTTP_SVC (puerto $HTTP_PUERTO)"
    msg_warn "Este proceso desinstalara $HTTP_SVC completamente y lo reemplazara."
    read -rp "  Continuar? [s/N]: " confirm
    [[ "${confirm,,}" != "s" ]] && msg_info "Operacion cancelada." && pausar && return

    http_desinstalar_svc "$HTTP_SVC"
    sleep 1
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
    _http_leer_estado

    if [[ -z "${HTTP_SVC:-}" ]]; then
        msg_warn "No hay servicio HTTP gestionado."
        pausar
        return
    fi

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
    _http_leer_estado
    local svc="${HTTP_SVC:-apache2}"

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
    _http_leer_estado

    if [[ -z "${HTTP_SVC:-}" ]]; then
        msg_warn "No hay servicio HTTP gestionado."
        pausar
        return
    fi

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
    _http_leer_estado
    if [[ -z "${HTTP_SVC:-}" ]]; then
        msg_warn "No hay servicio HTTP activo registrado."
        pausar
        return
    fi
    local sd
    sd=$(_http_servicio_systemd "$HTTP_SVC")
    msg_info "Reiniciando $HTTP_SVC ($sd)..."
    systemctl restart "$sd"
    systemctl status  "$sd" --no-pager -l | head -6 | sed 's/^/  /'
    msg_ok "$HTTP_SVC reiniciado."
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. VERIFICAR ESTADO (resumen rapido)
# ─────────────────────────────────────────────────────────────────────────────
http_verificar() {
    echo ""
    echo "=== Estado del servidor HTTP ==="
    echo ""
    _http_leer_estado

    if [[ -z "${HTTP_SVC:-}" ]]; then
        msg_warn "No hay ningun servicio HTTP gestionado aun."
        pausar
        return
    fi

    local sd
    sd=$(_http_servicio_systemd "$HTTP_SVC")

    msg_info "Servicio : $HTTP_SVC  |  Version: ${HTTP_VERSION:-?}  |  Puerto: $HTTP_PUERTO"
    echo ""

    if systemctl is-active --quiet "$sd" 2>/dev/null; then
        msg_ok "$sd esta ACTIVO"
    else
        msg_warn "$sd esta INACTIVO"
    fi

    echo ""
    echo "  curl -I http://localhost:$HTTP_PUERTO"
    curl -sI "http://localhost:$HTTP_PUERTO" 2>/dev/null | sed 's/^/    /' || \
        msg_warn "    No se pudo conectar"
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
        [[ -n "${HTTP_SVC:-}" ]] && info_activo="$HTTP_SVC v${HTTP_VERSION:-?} :$HTTP_PUERTO"
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
                _http_leer_estado
                if [[ -n "${HTTP_SVC:-}" ]]; then
                    http_aplicar_seguridad "$HTTP_SVC" "$HTTP_PUERTO"
                    local sd; sd=$(_http_servicio_systemd "$HTTP_SVC")
                    [[ -n "$sd" ]] && systemctl restart "$sd"
                    msg_ok "Seguridad aplicada y servicio reiniciado."
                else
                    msg_warn "No hay servicio activo."
                fi
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
