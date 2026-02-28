#!/bin/bash
# ftp-linux.sh
# Instalacion y configuracion de servidor FTP con vsftpd
# Sistema: AlmaLinux / RHEL / CentOS
# Depende de: common-functions.sh (si se usa desde main.sh)
#             O se ejecuta de forma independiente.

# ─────────────────────────────────────────────────────────────────────────────
# FUNCIONES DE SALIDA (se definen solo si no existen, por compatibilidad)
# ─────────────────────────────────────────────────────────────────────────────
if ! declare -f msg_ok &>/dev/null; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
    msg_ok()   { echo -e "  ${G}[OK]${N} $1"; }
    msg_err()  { echo -e "  ${R}[ERROR]${N} $1" >&2; exit 1; }
    msg_info() { echo -e "  ${C}[INFO]${N} $1"; }
    msg_warn() { echo -e "  ${Y}[AVISO]${N} $1"; }
    pausar()   { echo ""; read -rp "  Presiona ENTER para continuar... " _; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES GLOBALES
# ─────────────────────────────────────────────────────────────────────────────
FTP_BASE="/srv/ftp"
FTP_COMPARTIDO="$FTP_BASE/compartido"   # directorios compartidos reales
FTP_USUARIOS="$FTP_BASE/usuarios"       # raices FTP por usuario (chroot jail)
FTP_ANONIMO="$FTP_BASE/anonimo"         # raiz para acceso anonimo

VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
VSFTPD_CONF_ALT="/etc/vsftpd.conf"     # Debian/Ubuntu
VSFTPD_USERCONF_DIR="/etc/vsftpd/userconf"
VSFTPD_USERLIST="/etc/vsftpd/user_list"

GRP_REPROBADOS="reprobados"
GRP_RECURSADORES="recursadores"
GRP_FTP="ftpusers"

# Shell sin login para usuarios FTP (solo FTP, no SSH)
SHELL_NOLOGIN="/sbin/nologin"
[[ -x /usr/sbin/nologin ]] && SHELL_NOLOGIN="/usr/sbin/nologin"

# ─────────────────────────────────────────────────────────────────────────────
# VERIFICAR ROOT
# ─────────────────────────────────────────────────────────────────────────────
_ftp_verificar_root() {
    [[ $EUID -ne 0 ]] && msg_err "Ejecuta con sudo o como root."
}

# ─────────────────────────────────────────────────────────────────────────────
# OBTENER RUTA DEL ARCHIVO DE CONFIGURACION DE VSFTPD
# ─────────────────────────────────────────────────────────────────────────────
_ftp_ruta_conf() {
    [[ -f "$VSFTPD_CONF" ]] && echo "$VSFTPD_CONF" || echo "$VSFTPD_CONF_ALT"
}

# ─────────────────────────────────────────────────────────────────────────────
# GESTION DE BIND MOUNTS
# Los bind mounts permiten que un directorio compartido aparezca dentro del
# chroot jail de cada usuario sin duplicar los datos.
# ─────────────────────────────────────────────────────────────────────────────
_ftp_agregar_bind_mount() {
    local origen="$1"
    local destino="$2"
    local entrada="$origen $destino none bind 0 0"

    mkdir -p "$destino"

    if grep -qF "$entrada" /etc/fstab 2>/dev/null; then
        msg_warn "Bind mount '$destino' ya existe en /etc/fstab"
    else
        echo "$entrada" >> /etc/fstab
        msg_info "Bind mount registrado: $origen -> $destino"
    fi

    if ! mountpoint -q "$destino" 2>/dev/null; then
        mount --bind "$origen" "$destino"
        msg_ok "Montado: $destino"
    fi
}

_ftp_eliminar_bind_mount() {
    local destino="$1"

    if mountpoint -q "$destino" 2>/dev/null; then
        umount "$destino"
        msg_info "Desmontado: $destino"
    fi

    if grep -qF " $destino " /etc/fstab 2>/dev/null; then
        sed -i "\| $destino |d" /etc/fstab
        msg_info "Entrada eliminada de /etc/fstab: $destino"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. VERIFICAR ESTADO DEL SERVIDOR FTP
# ─────────────────────────────────────────────────────────────────────────────
ftp_verificar() {
    clear
    echo ""
    echo "=== Verificando servidor FTP (vsftpd) ==="
    echo ""

    echo "  Paquete:"
    if command -v vsftpd &>/dev/null; then
        msg_ok "vsftpd instalado: $(vsftpd -v 2>&1 | head -1)"
    else
        msg_warn "vsftpd NO esta instalado"
    fi

    echo ""
    echo "  Servicio:"
    if systemctl is-active --quiet vsftpd 2>/dev/null; then
        msg_ok "vsftpd activo"
        systemctl status vsftpd --no-pager -l 2>/dev/null | head -5 | sed 's/^/    /'
    else
        msg_warn "vsftpd inactivo o no encontrado"
    fi

    echo ""
    echo "  Grupos FTP:"
    for grp in "$GRP_REPROBADOS" "$GRP_RECURSADORES" "$GRP_FTP"; do
        if getent group "$grp" &>/dev/null; then
            local miembros
            miembros=$(getent group "$grp" | cut -d: -f4)
            msg_ok "$grp: ${miembros:-<sin miembros>}"
        else
            msg_warn "$grp: grupo no existe"
        fi
    done

    echo ""
    echo "  Usuarios FTP autorizados:"
    if [[ -f "$VSFTPD_USERLIST" ]] && [[ -s "$VSFTPD_USERLIST" ]]; then
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            local grp_usr="desconocido"
            getent group "$GRP_REPROBADOS"  | grep -qw "$u" && grp_usr="$GRP_REPROBADOS"
            getent group "$GRP_RECURSADORES"| grep -qw "$u" && grp_usr="$GRP_RECURSADORES"
            echo "    - $u  ($grp_usr)"
        done < "$VSFTPD_USERLIST"
    else
        msg_warn "Sin usuarios registrados"
    fi

    echo ""
    echo "  Estructura de directorios FTP:"
    if [[ -d "$FTP_BASE" ]]; then
        find "$FTP_BASE" -maxdepth 3 -printf "    %p\n" 2>/dev/null | head -30
    else
        msg_warn "Directorio FTP no configurado ($FTP_BASE)"
    fi

    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. INSTALAR VSFTPD (IDEMPOTENTE)
# ─────────────────────────────────────────────────────────────────────────────
ftp_instalar() {
    echo ""
    echo "=== Instalacion de vsftpd ==="
    echo ""

    if command -v vsftpd &>/dev/null; then
        msg_ok "vsftpd ya esta instalado: $(vsftpd -v 2>&1 | head -1)"
        return 0
    fi

    msg_info "Instalando vsftpd..."

    if command -v dnf &>/dev/null; then
        dnf install -y vsftpd
    elif command -v yum &>/dev/null; then
        yum install -y vsftpd
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y vsftpd
    else
        msg_err "Gestor de paquetes no reconocido. Instala vsftpd manualmente."
    fi

    msg_ok "vsftpd instalado correctamente"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CONFIGURAR SERVIDOR FTP
# Crea grupos, estructura de directorios y escribe vsftpd.conf
# ─────────────────────────────────────────────────────────────────────────────
ftp_configurar() {
    echo ""
    echo "=== Configuracion del servidor FTP ==="
    echo ""

    # ── 3.1 Crear grupos del sistema ─────────────────────────────────────────
    msg_info "Creando grupos del sistema..."
    for grp in "$GRP_REPROBADOS" "$GRP_RECURSADORES" "$GRP_FTP"; do
        if getent group "$grp" &>/dev/null; then
            msg_warn "Grupo '$grp' ya existe"
        else
            groupadd "$grp"
            msg_ok "Grupo '$grp' creado"
        fi
    done

    # ── 3.2 Crear estructura de directorios ───────────────────────────────────
    msg_info "Creando estructura de directorios..."

    # Directorios compartidos (los datos reales)
    mkdir -p "$FTP_COMPARTIDO/general"
    mkdir -p "$FTP_COMPARTIDO/$GRP_REPROBADOS"
    mkdir -p "$FTP_COMPARTIDO/$GRP_RECURSADORES"
    mkdir -p "$FTP_USUARIOS"
    mkdir -p "$FTP_ANONIMO/general"

    # general: legible por todos, escribible por usuarios FTP autenticados (ftpusers)
    # El bit setgid (g+s) garantiza que los archivos nuevos hereden el grupo
    chown root:"$GRP_FTP"        "$FTP_COMPARTIDO/general"
    chmod 775                    "$FTP_COMPARTIDO/general"
    chmod g+s                    "$FTP_COMPARTIDO/general"

    # reprobados: solo miembros del grupo pueden escribir
    chown root:"$GRP_REPROBADOS" "$FTP_COMPARTIDO/$GRP_REPROBADOS"
    chmod 770                    "$FTP_COMPARTIDO/$GRP_REPROBADOS"
    chmod g+s                    "$FTP_COMPARTIDO/$GRP_REPROBADOS"

    # recursadores: solo miembros del grupo pueden escribir
    chown root:"$GRP_RECURSADORES" "$FTP_COMPARTIDO/$GRP_RECURSADORES"
    chmod 770                      "$FTP_COMPARTIDO/$GRP_RECURSADORES"
    chmod g+s                      "$FTP_COMPARTIDO/$GRP_RECURSADORES"

    # Directorio anonimo: solo lectura para el usuario 'ftp'
    chown root:root "$FTP_ANONIMO"
    chmod 755       "$FTP_ANONIMO"

    # Bind mount: el directorio anonimo apunta a la carpeta general compartida
    # pero vsftpd solo permite lectura al usuario anonimo (anon_upload_enable=NO)
    _ftp_agregar_bind_mount "$FTP_COMPARTIDO/general" "$FTP_ANONIMO/general"

    msg_ok "Estructura de directorios configurada"

    # ── 3.3 Configurar PAM ────────────────────────────────────────────────────
    # Agrega /sbin/nologin a /etc/shells para que PAM acepte usuarios FTP
    # que no tienen acceso a shell interactiva
    msg_info "Configurando PAM (shells validos)..."
    if ! grep -q "^${SHELL_NOLOGIN}$" /etc/shells 2>/dev/null; then
        echo "$SHELL_NOLOGIN" >> /etc/shells
        msg_ok "Shell '$SHELL_NOLOGIN' agregado a /etc/shells"
    else
        msg_warn "'$SHELL_NOLOGIN' ya esta en /etc/shells"
    fi

    # ── 3.4 Escribir vsftpd.conf ──────────────────────────────────────────────
    msg_info "Escribiendo configuracion de vsftpd..."

    mkdir -p /etc/vsftpd
    mkdir -p "$VSFTPD_USERCONF_DIR"
    touch "$VSFTPD_USERLIST"

    local conf
    conf=$(_ftp_ruta_conf)

    # Backup de la configuracion original (solo la primera vez)
    if [[ -f "$conf" && ! -f "${conf}.bak" ]]; then
        cp "$conf" "${conf}.bak"
        msg_info "Backup guardado en ${conf}.bak"
    fi

    cat > "$conf" << 'VSFTPD_EOF'
# =============================================================================
# vsftpd.conf - Servidor FTP con acceso anonimo y autenticado
# =============================================================================

# ── Usuarios locales ──────────────────────────────────────────────────────────
local_enable=YES
write_enable=YES
local_umask=022

# ── Confinamiento de usuarios (chroot jail) ───────────────────────────────────
# Cada usuario queda enjaulado en su local_root definido en user_config_dir.
# El directorio raiz del jail debe ser propiedad de root (no escribible por el
# usuario) para que no sea necesario allow_writeable_chroot=YES.
chroot_local_user=YES
user_config_dir=/etc/vsftpd/userconf

# ── Acceso anonimo (solo lectura en /general) ─────────────────────────────────
anonymous_enable=YES
anon_root=/srv/ftp/anonimo
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO
ftp_username=ftp

# ── Lista blanca de usuarios permitidos ───────────────────────────────────────
# userlist_deny=NO significa que SOLO los usuarios en la lista pueden entrar
userlist_enable=YES
userlist_file=/etc/vsftpd/user_list
userlist_deny=NO

# ── Autenticacion y seguridad ──────────────────────────────────────────────────
pam_service_name=vsftpd
ssl_enable=NO

# ── Registro de actividad ──────────────────────────────────────────────────────
xferlog_enable=YES
xferlog_std_format=YES
vsftpd_log_file=/var/log/vsftpd.log

# ── Modo de escucha ────────────────────────────────────────────────────────────
listen=YES
listen_ipv6=NO

# ── Modo pasivo (necesario con firewalls/NAT) ─────────────────────────────────
pasv_enable=YES
pasv_min_port=10090
pasv_max_port=10100

# ── Mensaje de bienvenida ──────────────────────────────────────────────────────
ftpd_banner=Servidor FTP - Acceso restringido a usuarios autorizados

# ── Uso de hora local ─────────────────────────────────────────────────────────
use_localtime=YES
VSFTPD_EOF

    msg_ok "vsftpd.conf escrito en: $conf"

    # ── 3.5 Configurar firewall (firewalld) ───────────────────────────────────
    if command -v firewall-cmd &>/dev/null; then
        msg_info "Abriendo puertos en firewalld..."
        firewall-cmd --permanent --add-service=ftp          --quiet 2>/dev/null || true
        firewall-cmd --permanent --add-port=10090-10100/tcp --quiet 2>/dev/null || true
        firewall-cmd --reload --quiet
        msg_ok "Firewall configurado (FTP + puertos pasivos 10090-10100)"
    fi

    # ── 3.6 Habilitar e iniciar vsftpd ────────────────────────────────────────
    systemctl enable vsftpd --quiet
    systemctl restart vsftpd
    msg_ok "vsftpd habilitado e iniciado"

    echo ""
    msg_ok "Configuracion del servidor FTP completada."
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# CREAR UN USUARIO FTP (funcion interna)
# Estructura visible al conectarse:
#   /
#   ├── general/         <- bind mount a compartido/general   (escritura)
#   ├── reprobados/      <- bind mount a compartido/reprobados (escritura de grupo)
#   │    O recursadores/
#   └── <username>/      <- directorio personal               (escritura)
# ─────────────────────────────────────────────────────────────────────────────
_ftp_crear_usuario() {
    local usuario="$1"
    local password="$2"
    local grupo="$3"
    local raiz="$FTP_USUARIOS/$usuario"

    # Verificar que el grupo sea valido
    if [[ "$grupo" != "$GRP_REPROBADOS" && "$grupo" != "$GRP_RECURSADORES" ]]; then
        msg_err "Grupo invalido: '$grupo'. Usa '$GRP_REPROBADOS' o '$GRP_RECURSADORES'."
    fi

    # Verificar si el usuario ya existe
    if id "$usuario" &>/dev/null; then
        msg_warn "El usuario '$usuario' ya existe en el sistema, omitiendo creacion."
        return 0
    fi

    msg_info "Creando usuario: $usuario  (grupo: $grupo)"

    # Crear usuario del sistema sin acceso a shell interactiva
    # -M: no crear home dir (lo crearemos con los permisos correctos)
    # -d: directorio home en el registro /etc/passwd
    # -s: shell sin login
    # -g: grupo primario = ftpusers
    # -G: grupo suplementario = reprobados o recursadores
    useradd \
        -M \
        -d "$raiz" \
        -s "$SHELL_NOLOGIN" \
        -g "$GRP_FTP" \
        -G "$grupo" \
        "$usuario"

    # Establecer contrasena
    echo "$usuario:$password" | chpasswd

    # ── Crear estructura de directorios del usuario ───────────────────────────

    # Raiz FTP del usuario: propiedad root para el chroot jail seguro
    # (vsftpd exige que el directorio jail no sea escribible por el usuario)
    mkdir -p "$raiz"
    chown root:root "$raiz"
    chmod 755       "$raiz"

    # Carpeta personal: el usuario tiene control total
    mkdir -p "$raiz/$usuario"
    chown "$usuario":"$GRP_FTP" "$raiz/$usuario"
    chmod 750                   "$raiz/$usuario"

    # Puntos de montaje para directorios compartidos
    mkdir -p "$raiz/general"
    mkdir -p "$raiz/$grupo"

    # Bind mounts: los directorios compartidos aparecen dentro del jail
    _ftp_agregar_bind_mount "$FTP_COMPARTIDO/general" "$raiz/general"
    _ftp_agregar_bind_mount "$FTP_COMPARTIDO/$grupo"  "$raiz/$grupo"

    # ── Configuracion per-usuario para vsftpd ────────────────────────────────
    # Sobrescribe la raiz FTP del usuario (chroot jail)
    mkdir -p "$VSFTPD_USERCONF_DIR"
    echo "local_root=$raiz" > "$VSFTPD_USERCONF_DIR/$usuario"

    # ── Agregar a la lista blanca de usuarios ─────────────────────────────────
    if ! grep -q "^${usuario}$" "$VSFTPD_USERLIST" 2>/dev/null; then
        echo "$usuario" >> "$VSFTPD_USERLIST"
    fi

    msg_ok "Usuario '$usuario' creado"
    echo "    Estructura FTP al conectarse:"
    echo "      /general/         (escritura compartida con todos los usuarios)"
    echo "      /$grupo/    (escritura de grupo: $grupo)"
    echo "      /$usuario/   (carpeta personal)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CREACION MASIVA DE USUARIOS FTP
# ─────────────────────────────────────────────────────────────────────────────
ftp_gestionar_usuarios() {
    echo ""
    echo "=== Creacion de usuarios FTP ==="
    echo ""

    local n_usuarios
    while true; do
        read -rp "  Cuantos usuarios desea crear? " n_usuarios
        [[ "$n_usuarios" =~ ^[1-9][0-9]*$ ]] && break
        msg_warn "Ingresa un numero entero positivo."
    done

    for ((i = 1; i <= n_usuarios; i++)); do
        echo ""
        echo "  ─── Usuario $i de $n_usuarios ──────────────────────"

        # Nombre de usuario
        local usuario
        while true; do
            read -rp "  Nombre de usuario: " usuario
            if [[ -z "$usuario" ]]; then
                msg_warn "El nombre no puede estar vacio."
            elif [[ ! "$usuario" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; then
                msg_warn "Usa solo minusculas, digitos, guion o guion_bajo. Maximo 31 chars."
            else
                break
            fi
        done

        # Contrasena
        local pass1 pass2
        while true; do
            read -rsp "  Contrasena: " pass1; echo ""
            read -rsp "  Confirmar:  " pass2; echo ""
            if [[ "$pass1" != "$pass2" ]]; then
                msg_warn "Las contrasenas no coinciden."
            elif [[ ${#pass1} -lt 6 ]]; then
                msg_warn "La contrasena debe tener al menos 6 caracteres."
            else
                break
            fi
        done

        # Seleccion de grupo
        local grupo
        while true; do
            echo "  Grupos disponibles:"
            echo "    1) reprobados"
            echo "    2) recursadores"
            read -rp "  Seleccione grupo [1/2]: " opc
            case "$opc" in
                1) grupo="$GRP_REPROBADOS";  break ;;
                2) grupo="$GRP_RECURSADORES"; break ;;
                *) msg_warn "Opcion invalida, elige 1 o 2." ;;
            esac
        done

        _ftp_crear_usuario "$usuario" "$pass1" "$grupo"
    done

    # Aplicar cambios reiniciando vsftpd
    systemctl restart vsftpd
    msg_ok "Proceso completado. vsftpd reiniciado."
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. CAMBIAR GRUPO DE UN USUARIO
# Actualiza la membresia de grupo y reemplaza el bind mount del directorio
# de grupo en el jail FTP del usuario.
# ─────────────────────────────────────────────────────────────────────────────
ftp_cambiar_grupo() {
    echo ""
    echo "=== Cambiar grupo de usuario FTP ==="
    echo ""

    local usuario
    read -rp "  Nombre de usuario: " usuario

    if ! id "$usuario" &>/dev/null; then
        msg_err "El usuario '$usuario' no existe en el sistema."
    fi

    local raiz="$FTP_USUARIOS/$usuario"

    # Detectar grupo actual (reprobados o recursadores)
    local grupo_anterior=""
    if id -Gn "$usuario" 2>/dev/null | grep -qw "$GRP_REPROBADOS"; then
        grupo_anterior="$GRP_REPROBADOS"
    elif id -Gn "$usuario" 2>/dev/null | grep -qw "$GRP_RECURSADORES"; then
        grupo_anterior="$GRP_RECURSADORES"
    else
        msg_err "El usuario '$usuario' no pertenece a '$GRP_REPROBADOS' ni '$GRP_RECURSADORES'."
    fi

    msg_info "Grupo actual de '$usuario': $grupo_anterior"

    # Solicitar nuevo grupo
    local nuevo_grupo
    while true; do
        echo "  1) reprobados"
        echo "  2) recursadores"
        read -rp "  Nuevo grupo [1/2]: " opc
        case "$opc" in
            1) nuevo_grupo="$GRP_REPROBADOS";  break ;;
            2) nuevo_grupo="$GRP_RECURSADORES"; break ;;
            *) msg_warn "Opcion invalida." ;;
        esac
    done

    if [[ "$grupo_anterior" == "$nuevo_grupo" ]]; then
        msg_warn "El usuario ya pertenece al grupo '$nuevo_grupo'. Sin cambios."
        pausar
        return 0
    fi

    msg_info "Cambiando '$usuario': $grupo_anterior -> $nuevo_grupo ..."

    # 1. Desmontar y eliminar el directorio del grupo anterior
    _ftp_eliminar_bind_mount "$raiz/$grupo_anterior"
    rm -rf "${raiz:?}/$grupo_anterior"

    # 2. Crear el directorio del nuevo grupo y su bind mount
    mkdir -p "$raiz/$nuevo_grupo"
    _ftp_agregar_bind_mount "$FTP_COMPARTIDO/$nuevo_grupo" "$raiz/$nuevo_grupo"

    # 3. Actualizar membresia de grupos en el sistema
    gpasswd -d "$usuario" "$grupo_anterior" &>/dev/null || true
    gpasswd -a "$usuario" "$nuevo_grupo"

    msg_ok "Usuario '$usuario' movido de '$grupo_anterior' a '$nuevo_grupo'."
    msg_info "Directorio de grupo accesible: /$nuevo_grupo/"
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. LISTAR USUARIOS FTP
# ─────────────────────────────────────────────────────────────────────────────
ftp_listar_usuarios() {
    echo ""
    echo "=== Usuarios FTP registrados ==="
    echo ""

    if [[ ! -f "$VSFTPD_USERLIST" ]] || [[ ! -s "$VSFTPD_USERLIST" ]]; then
        msg_warn "No hay usuarios FTP registrados aun."
        pausar
        return
    fi

    printf "  %-20s %-15s %-35s\n" "USUARIO" "GRUPO FTP" "DIRECTORIO RAIZ (chroot)"
    printf "  %-20s %-15s %-35s\n" "────────────────────" "───────────────" "───────────────────────────────────"

    while IFS= read -r usr; do
        [[ -z "$usr" ]] && continue

        local grp="(sin grupo)"
        getent group "$GRP_REPROBADOS"  | grep -qw "$usr" && grp="$GRP_REPROBADOS"
        getent group "$GRP_RECURSADORES"| grep -qw "$usr" && grp="$GRP_RECURSADORES"

        printf "  %-20s %-15s %-35s\n" "$usr" "$grp" "$FTP_USUARIOS/$usr"
    done < "$VSFTPD_USERLIST"

    echo ""
    echo "  Acceso anonimo apunta a: $FTP_ANONIMO"
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. REINICIAR SERVICIO
# ─────────────────────────────────────────────────────────────────────────────
ftp_reiniciar() {
    msg_info "Reiniciando vsftpd..."
    systemctl restart vsftpd
    systemctl status vsftpd --no-pager -l | head -8
    msg_ok "vsftpd reiniciado."
    pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU DEL MODULO FTP
# ─────────────────────────────────────────────────────────────────────────────
menu_ftp() {
    while true; do
        clear
        echo ""
        echo "----------------------------------------------"
        echo "         ADMINISTRACION SERVIDOR FTP          "
        echo "              vsftpd - AlmaLinux              "
        echo "----------------------------------------------"
        echo "  1. Verificar estado del servicio            "
        echo "  2. Instalar vsftpd                          "
        echo "  3. Configurar servidor FTP                  "
        echo "  4. Crear usuarios FTP (masivo)              "
        echo "  5. Cambiar grupo de un usuario              "
        echo "  6. Listar usuarios FTP                      "
        echo "  7. Reiniciar vsftpd                         "
        echo "  0. Salir                                    "
        echo "----------------------------------------------"
        read -rp "  Opcion: " opc
...2
        case "$opc" in
            1) ftp_verificar ;;
            2) ftp_instalar ;;
            3) ftp_configurar ;;
            4) ftp_gestionar_usuarios ;;
            5) ftp_cambiar_grupo ;;
            6) ftp_listar_usuarios ;;
            7) ftp_reiniciar ;;
            0) msg_info "Saliendo..."; break ;;
            *) msg_warn "Opcion no valida." ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA
# Solo se ejecuta si el script se llama directamente (no si es incluido)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _ftp_verificar_root
    menu_ftp
fi
