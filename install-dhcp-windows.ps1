
Write-Host "=== Instalacion DHCP Server ===" 


if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Ejecuta como Administrador" 
    exit 1
}


if (!(Get-WindowsFeature DHCP).Installed) {
    Write-Host "Instalando rol DHCP..." 
    Install-WindowsFeature DHCP -IncludeManagementTools
    Write-Host "Instalacion completada" 
} else {
    Write-Host "DHCP ya esta instalado" 
}


$ScopeName = Read-Host "Nombre del ambito [Red-Interna]"
if (!$ScopeName) { $ScopeName = "Red-Interna" }

$Start = Read-Host "Rango inicial [192.168.100.50]"
if (!$Start) { $Start = "192.168.100.50" }

$End = Read-Host "Rango final [192.168.100.150]"
if (!$End) { $End = "192.168.100.150" }

$Gateway = Read-Host "Gateway [192.168.100.1]"
if (!$Gateway) { $Gateway = "192.168.100.1" }

$DNS = Read-Host "DNS [192.168.100.1]"
if (!$DNS) { $DNS = "192.168.100.1" }

Write-Host "`nVerificando ambitos existentes..." 
$ExistingScope = Get-DhcpServerv4Scope -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue
if ($ExistingScope) {
    Write-Host "Eliminando ambito existente..." 
    Remove-DhcpServerv4Scope -ScopeId 192.168.100.0 -Force
}

Write-Host "Creando ambito..." 
Add-DhcpServerv4Scope -Name $ScopeName -StartRange $Start -EndRange $End -SubnetMask 255.255.255.0 -State Active

Write-Host "Configurando opciones de red..." 
Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -Router $Gateway
Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -DnsServer $DNS


Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12 -Name ConfigurationState -Value 2


Write-Host "Reiniciando servicio DHCP..." 
Restart-Service DHCPServer
