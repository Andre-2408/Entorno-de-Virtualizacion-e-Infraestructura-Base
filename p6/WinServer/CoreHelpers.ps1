#
# CoreHelpers.ps1
# Utilidades base del gestor HTTP - Windows Server 2022
#
# Equivalente a utils.sh de la practica Linux.
# Provee: colores ANSI, salida formateada, verificacion de privilegios,
# helpers de red, gestion de servicios y separadores visuales.
#

#Requires -Version 5.1

$ESC   = [char]27
$RED   = "$ESC[0;31m"
$GREEN = "$ESC[0;32m"
$YELLOW= "$ESC[1;33m"
$BLUE  = "$ESC[0;34m"
$CYAN  = "$ESC[0;36m"
$GRAY  = "$ESC[0;90m"
$NC    = "$ESC[0m"    # Reset

function aputs_info {
    param([string]$Mensaje)
    Write-Host "${BLUE}[INFO]${NC} $Mensaje"
}

function aputs_success {
    param([string]$Mensaje)
    Write-Host "${GREEN}[SUCCESS]${NC} $Mensaje"
}

function aputs_warning {
    param([string]$Mensaje)
    Write-Host "${YELLOW}[WARNING]${NC} $Mensaje"
}

function aputs_error {
    param([string]$Mensaje)
    Write-Host "${RED}[ERROR]${NC} $Mensaje"
}

# Solicita entrada al usuario con prompt coloreado.
# Equivalente a agets. Devuelve el valor leido.
# Uso: $valor = agets "Ingrese el puerto"
function agets {
    param([string]$Prompt)
    Write-Host -NoNewline "${CYAN}[INPUT]${NC} ${Prompt}: "
    return (Read-Host)
}

# Pausa hasta que el usuario presione Enter.
# Equivalente a pause() de utils.sh
function pause_menu {
    Write-Host ""
    Read-Host "  Presiona Enter para continuar..."
}

function check_privileges {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        aputs_error "Este script requiere permisos de Administrador."
        aputs_info  "Ejecute PowerShell como Administrador y reintente."
        return $false
    }

    aputs_warning "Detectado ejecucion como Administrador"
    return $true
}

# Verifica si un paquete esta instalado via Chocolatey.
# Uso: check_package_installed "nginx"  === $true / $false
function check_package_installed {
    param([string]$Package)
    $result = choco list --local $Package 2>$null | Where-Object { $_ -match "^$Package " }
    return ($null -ne $result -and $result.Count -gt 0)
}

# Verifica si un servicio de Windows esta corriendo (equivale a is-active).
# Uso: check_service_active "W3SVC"  === $true / $false
function check_service_active {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

# Verifica si un servicio arranca automaticamente en boot (equivale a is-enabled).
# Uso: check_service_enabled "W3SVC"  === $true / $false
function check_service_enabled {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.StartType -eq 'Automatic')
}

# Devuelve la primera IP IPv4 de una interfaz de red.
# Uso: get_interface_ip "Ethernet"
function get_interface_ip {
    param([string]$InterfaceName)
    $addr = Get-NetIPAddress -InterfaceAlias $InterfaceName `
                             -AddressFamily IPv4 `
                             -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty IPAddress
    if ($addr) { return $addr }
    return "Sin IP"
}

# Lista interfaces de red activas excluyendo loopback.
# Equivalente a get_network_interfaces de utils.sh
function get_network_interfaces {
    return (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -ne 'Loopback' } |
            Select-Object -ExpandProperty Name)
}

# Verifica conectividad con un ping simple.
# Uso: check_connectivity "192.168.100.10"  === $true / $false
function check_connectivity {
    param([string]$HostTarget = "8.8.8.8")
    return (Test-Connection -ComputerName $HostTarget -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

# Verifica si un puerto TCP esta en escucha en localhost.
# Equivalente a check_port_listening de utils.sh (usa ss en Linux, netstat aqui)
# Uso: check_port_listening 80  === $true / $false
function check_port_listening {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conn -and $conn.Count -gt 0)
}

# Verifica si un usuario local de Windows existe.
# Equivalente a check_user_exists de utils.sh
# Uso: check_user_exists "apacheuser"  === $true / $false
function check_user_exists {
    param([string]$UserName)
    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    return ($null -ne $user)
}

function draw_line {
    Write-Host "========================================================================================================================"
}

# Cabecera con titulo centrado entre separadores.
# Uso: draw_header "Monitor HTTP"
function draw_header {
    param([string]$Title)
    Write-Host ""
    draw_line
    Write-Host "  $Title"
    draw_line
}