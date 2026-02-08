Write-Host "Instalacion DHCP Server" 

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Ejecuta como Administrador" 
    exit 1
}

if (!(Get-WindowsFeature DHCP).Installed) {
    Write-Host "Instalando rol DHCP"
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

$LeaseTime = Read-Host "Tiempo de concesion en dias [1]"
if (!$LeaseTime) { $LeaseTime = "1.00:00:00" } else { $LeaseTime = "$LeaseTime.00:00:00" }

Write-Host "Creando ambito"
Add-DhcpServerv4Scope -Name $ScopeName -StartRange $Start -EndRange $End -SubnetMask 255.255.255.0 -LeaseDuration $LeaseTime


Write-Host "Configurando opciones de red"
Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -Router $Gateway -DnsServer $DNS


Write-Host "Autorizando servidor DHCP"
Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -IPAddress (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -like "192.168.*"}).IPAddress


Restart-Service DHCPServer
