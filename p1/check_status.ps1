
Write-Host "Nombre del equipo"
Write-Host $env:COMPUTERNAME
Write-Host ""

Write-Host "DIRECCION IP: "
$ipAddresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "127.*"}
foreach ($ip in $ipAddresses) {
    Write-Host "   Interfaz: $($ip.InterfaceAlias) - IP: $($ip.IPAddress)"
} 
Write-Host "" 

Write-Host "Espacio en Disco: "
Get-PSDrive -PSProvider FileSystem | Where-Object {$_.Used -ne $null} | Format-Table Name, @{Label="Size(GB)";Expression={[math]::Round($_.Used/1GB + $_.Free/1GB, 2)}}, @{Label="Used(GB)";Expression={[math]::Round($_.Used/1GB, 2)}}, @{Label="Free(GB)";Expression={[math]::Round($_.Free/1GB, 2)}}, @{Label="Use%";Expression={[math]::Round(($_.Used/($_.Used + $_.Free)) * 100, 2)}} -AutoSize
Write-Host ""