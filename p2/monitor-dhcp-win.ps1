# Monitor DHCP Server - Windows Server 2022

Write-Host "=== MONITOR DHCP SERVER ==="

# Estado del servicio
Write-Host "`nEstado del servicio:"
Get-Service DHCPServer | Select-Object Name, Status, StartType | Format-Table

# Ambitos configurados
Write-Host "Ambitos configurados:"
Get-DhcpServerv4Scope | Format-Table ScopeId, Name, StartRange, EndRange, State

# Concesiones activas
Write-Host "Concesiones activas:"
$leases = Get-DhcpServerv4Lease -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue
if ($leases) {
    $leases | Select-Object IPAddress, ClientId, HostName, LeaseExpiryTime | Format-Table
    Write-Host "Total concesiones: $($leases.Count)"
} else {
    Write-Host "No hay concesiones activas"
}

# Opciones configuradas
Write-Host "Opciones de red:"
Get-DhcpServerv4OptionValue -ScopeId 192.168.100.0 | Select-Object OptionId, Name, Value | Format-Table

# Estadisticas
Write-Host "Estadisticas:"
Get-DhcpServerv4Statistics | Select-Object TotalScopes, TotalAddresses, InUseAddresses, AvailableAddresses | Format-Table