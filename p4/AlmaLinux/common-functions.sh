#!/bin/bash
# lib/common_functions.sh

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

msg_ok()   { echo -e "  ${G}[OK]${N} $1"; }
msg_err()  { echo -e "  ${R}[ERROR]${N} $1"; }
msg_info() { echo -e "  ${C}[INFO]${N} $1"; }
msg_warn() { echo -e "  ${Y}[AVISO]${N} $1"; }
pausar()   { echo ""; read -rp "  Presiona ENTER para continuar... " _; }

# ─────────────────────────────────────────
# VERIFICAR ROOT
# ─────────────────────────────────────────
verificar_root() {
    [[ $EUID -ne 0 ]] && msg_err "Ejecuta con sudo." && exit 1
}

# ─────────────────────────────────────────
# VALIDACION DE IP
# ─────────────────────────────────────────
validar_ip() {
    local ip=$1
    if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Error: '$ip' no tiene formato IPv4 valido" >&2; return 1
    fi
    IFS='.' read -r a b c d <<< "$ip"
    for oct in $a $b $c $d; do
        [ "$oct" -gt 255 ] && echo "Error: octeto '$oct' fuera de rango" >&2 && return 1
    done
    [ "$ip" = "0.0.0.0" ]         && echo "Error: 0.0.0.0 no valida" >&2 && return 1
    [ "$ip" = "255.255.255.255" ] && echo "Error: broadcast no valida" >&2 && return 1
    [ "$a" = "127" ]              && echo "Error: loopback no valida" >&2  && return 1
    [ "$d" = "0" ]                && echo "Error: direccion de red" >&2    && return 1
    [ "$d" = "255" ]              && echo "Error: direccion de broadcast" >&2 && return 1
    return 0
}

pedir_ip() {
    local msg=$1 def=$2 ip=""
    while true; do
        read -rp "  $msg [$def]: " ip >&2
        ip=${ip:-$def}
        validar_ip "$ip" && echo "$ip" && return 0
    done
}

ip_to_int() {
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

calcular_mascara() {
    local prefix=$1
    local full=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
    echo "$(( (full >> 24) & 255 )).$(( (full >> 16) & 255 )).$(( (full >> 8) & 255 )).$(( full & 255 ))"
}