# Instalacion DHCP Server - Windows Server 2022

Write-Host "Instalacion DHCP Server"

# Verificar privilegios
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Ejecuta como Administrador"
    exit 1
}

# Funcion para validar IP
function Validar-IP {
    param($ip)

    if ($ip -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        Write-Host "Error: $ip no tiene formato IPv4 valido"
        return $false
    }

    $octetos = $ip.Split(".")
    foreach ($oct in $octetos) {
        if ([int]$oct -gt 255) {
            Write-Host "Error: $ip tiene octetos fuera de rango (0-255)"
            return $false
        }
    }

    if ($ip -eq "0.0.0.0") {
        Write-Host "Error: 0.0.0.0 no es una IP valida"
        return $false
    }

    if ($ip -eq "255.255.255.255") {
        Write-Host "Error: 255.255.255.255 no es una IP valida"
        return $false
    }

    if ($octetos[3] -eq "0") {
        Write-Host "Error: $ip es una direccion de red, no de host"
        return $false
    }

    if ($octetos[3] -eq "255") {
        Write-Host "Error: $ip es una direccion de broadcast"
        return $false
    }

    return $true
}

# Funcion para pedir IP con validacion
function Pedir-IP {
    param($mensaje, $default)

    while ($true) {
        $ip = Read-Host "$mensaje [$default]"
        if (!$ip) { $ip = $default }

        if (Validar-IP $ip) {
            return $ip
        }
    }
}

# Verificar si DHCP esta instalado
if (!(Get-Service DHCPServer -ErrorAction SilentlyContinue)) {
    Write-Host "Instalando rol DHCP..."
    dism /online /enable-feature /featurename:DHCPServer /all
    Write-Host "Instalacion completada"
} else {
    Write-Host "DHCP ya esta instalado"
}

# Solicitar parametros con validacion
$ScopeName = Read-Host "Nombre del ambito [Red-Interna]"
if (!$ScopeName) { $ScopeName = "Red-Interna" }

$Start   = Pedir-IP "Rango inicial" "192.168.100.50"
$End     = Pedir-IP "Rango final"   "192.168.100.150"
$Gateway = Pedir-IP "Gateway"       "192.168.100.1"
$DNS     = Pedir-IP "DNS"           "192.168.100.1"

$LeaseTime = Read-Host "Tiempo de concesion en dias [1]"
if (!$LeaseTime) { $LeaseTime = "1.00:00:00" } else { $LeaseTime = "$LeaseTime.00:00:00" }

# Eliminar ambito existente si existe
Write-Host "`nVerificando ambitos existentes..."
$existingScope = Get-DhcpServerv4Scope | Where-Object { $_.ScopeId -eq "192.168.100.0" }
if ($existingScope) {
    Write-Host "Eliminando ambito existente..."
    Remove-DhcpServerv4Scope -ScopeId 192.168.100.0 -Force
}

# Crear ambito
Write-Host "Creando ambito..."
Add-DhcpServerv4Scope -Name $ScopeName -StartRange $Start -EndRange $End -SubnetMask 255.255.255.0 -LeaseDuration $LeaseTime -State Active

# Configurar Gateway
Write-Host "Configurando Gateway..."
Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -Router $Gateway

# Configurar DNS (sin validacion de conectividad)
Write-Host "Configurando DNS..."
try {
    $dnsIP = [System.Net.IPAddress]::Parse($DNS)
    $option = Get-DhcpServerv4OptionDefinition -OptionId 6 -ErrorAction Stop
    Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -OptionId 6 -Value $DNS -Force
    Write-Host "DNS configurado: $DNS"
} catch {
    Write-Host "Advertencia: DNS configurado sin validacion de conectividad"
    netsh dhcp server scope 192.168.100.0 set optionvalue 006 IPADDRESS $DNS | Out-Null
}

# Evitar error de AD en servidor standalone
try {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
} catch {}

# Reiniciar servicio
Write-Host "Reiniciando servicio DHCP..."
Restart-Service DHCPServer

# Resumen
Write-Host "INSTALACION COMPLETADA"
Write-Host "Ambito:  $ScopeName"
Write-Host "Rango:   $Start - $End"
Write-Host "Gateway: $Gateway"
Write-Host "DNS:     $DNS"
