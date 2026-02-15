# ============================================================
# DHCP Server Manager - Windows Server 2022
# ============================================================

# ─────────────────────────────────────────
# FUNCIONES DE VALIDACION
# ─────────────────────────────────────────

function Validar-IP {
    param($ip)

    if ($ip -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        Write-Host "Error: '$ip' no tiene formato IPv4 valido"
        return $false
    }

    $o = $ip.Split(".")
    foreach ($oct in $o) {
        if ([int]$oct -gt 255) {
            Write-Host "Error: octeto '$oct' fuera de rango (0-255)"
            return $false
        }
    }

    if ($ip -eq "0.0.0.0")         { Write-Host "Error: 0.0.0.0 no es valida"; return $false }
    if ($ip -eq "255.255.255.255") { Write-Host "Error: 255.255.255.255 no es valida"; return $false }
    if ($o[0] -eq "127")           { Write-Host "Error: 127.x.x.x es loopback, no valida"; return $false }
    if ($o[3] -eq "0")             { Write-Host "Error: $ip es direccion de red"; return $false }
    if ($o[3] -eq "255")           { Write-Host "Error: $ip es broadcast"; return $false }

    return $true
}

function Pedir-IP {
    param($mensaje, $default)
    while ($true) {
        $ip = Read-Host "$mensaje [$default]"
        if (!$ip) { $ip = $default }
        if (Validar-IP $ip) { return $ip }
    }
}

function IP-ToInt {
    param($ip)
    $o = $ip.Split(".")
    return ([int]$o[0] * 16777216) + ([int]$o[1] * 65536) + ([int]$o[2] * 256) + [int]$o[3]
}

function Calcular-Mascara {
    param([int]$prefix)
    $octetos = @(0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $prefix - ($i * 8)))
        $octetos[$i] = [int](256 - [Math]::Pow(2, 8 - $bits))
    }
    return "$($octetos[0]).$($octetos[1]).$($octetos[2]).$($octetos[3])"
}

function Misma-Subred {
    param($ip1, $ip2, $mask)
    $o1 = $ip1.Split(".")
    $o2 = $ip2.Split(".")
    $om = $mask.Split(".")
    for ($i = 0; $i -lt 4; $i++) {
        if (([int]$o1[$i] -band [int]$om[$i]) -ne ([int]$o2[$i] -band [int]$om[$i])) {
            return $false
        }
    }
    return $true
}

# ─────────────────────────────────────────
# VERIFICAR INSTALACION
# ─────────────────────────────────────────
function Verificar-Instalacion {
    Write-Host ""
    Write-Host "=== Verificando instalacion ==="

    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Servicio DHCP: $($svc.Status)"
    } else {
        Write-Host "Servicio DHCP: NO instalado"
    }

    $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if ($scope) {
        Write-Host "Ambitos configurados:"
        $scope | Format-Table ScopeId, Name, StartRange, EndRange, State
    } else {
        Write-Host "No hay ambitos configurados"
    }

    Read-Host "Presiona Enter para volver al menu"
}

# ─────────────────────────────────────────
# MONITOR
# ─────────────────────────────────────────
function Monitor {
    while ($true) {
        Clear-Host
        Write-Host "=== MONITOR DHCP SERVER ==="
        Write-Host ""

        Write-Host "Estado del servicio:"
        Get-Service DHCPServer | Select-Object Name, Status | Format-Table

        Write-Host "Ambitos:"
        Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Format-Table ScopeId, Name, StartRange, EndRange, State

        Write-Host "Concesiones activas:"
        $leases = Get-DhcpServerv4Lease -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue
        if ($leases) {
            $leases | Select-Object IPAddress, ClientId, HostName, LeaseExpiryTime | Format-Table
            Write-Host "Total: $($leases.Count)"
        } else {
            Write-Host "No hay concesiones activas"
        }

        Write-Host "Opciones de red:"
        Get-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue | Select-Object OptionId, Name, Value | Format-Table

        Write-Host ""
        Write-Host "r) Refrescar    0) Volver al menu"
        $opt = Read-Host "> "
        if ($opt -eq "0") { return }
    }
}

# ─────────────────────────────────────────
# INSTALACION
# ─────────────────────────────────────────
function Instalar {
    Write-Host ""
    Write-Host "=== Instalacion DHCP Server ==="

    # Verificar si ya esta instalado
    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "DHCP ya esta instalado y activo."
        $resp = Read-Host "Deseas reinstalar? (s/n)"
        if ($resp -notmatch "^[sS]$") {
            Write-Host "Volviendo al menu..."
            return
        }
    }

    # Instalar si no existe
    if (!$svc) {
        Write-Host "Instalando rol DHCP..."
        dism /online /enable-feature /featurename:DHCPServer /all
    }

    # Detectar IP del servidor
    $serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.*" -and $_.PrefixOrigin -eq "Manual" } | Select-Object -First 1).IPAddress
    if (!$serverIP) {
        $serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
    }
    Write-Host "IP del servidor detectada: $serverIP"

    # Prefijo de subred
    $prefix = Read-Host "Prefijo de subred [24]"
    if (!$prefix) { $prefix = 24 }
    $mask = Calcular-Mascara $prefix
    Write-Host "Mascara calculada: $mask"

    # Nombre del ambito
    $ScopeName = Read-Host "Nombre del ambito [Red-Interna]"
    if (!$ScopeName) { $ScopeName = "Red-Interna" }

    # Rango inicial
    $Start = Pedir-IP "Rango inicial" "192.168.100.50"

    # Rango final
    while ($true) {
        $End = Pedir-IP "Rango final" "192.168.100.150"
        if ((IP-ToInt $End) -le (IP-ToInt $Start)) {
            Write-Host "Error: el rango final debe ser mayor que el inicial ($Start)"
            continue
        }
        break
    }

    # Ignorar primera IP (+1)
    $startParts = $Start.Split(".")
    $serverStatic = $Start
    $startReal = "$($startParts[0]).$($startParts[1]).$($startParts[2]).$([int]$startParts[3] + 1)"
    Write-Host "IP fija del servidor: $serverStatic"
    Write-Host "Rango DHCP real:      $startReal - $End"

    # Asignar IP fija al servidor
    Write-Host "Configurando IP fija $serverStatic/$prefix en el adaptador..."
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notlike "*Loopback*" } | Where-Object { (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.*" } | Select-Object -First 1
    if (!$adapter) {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notlike "*Loopback*" } | Select-Object -First 1
    }
    if ($adapter) {
        # Eliminar IPs existentes en ese adaptador
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        # Asignar nueva IP fija
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $serverStatic -PrefixLength $prefix -ErrorAction SilentlyContinue | Out-Null
        Write-Host "IP fija $serverStatic/$prefix asignada en $($adapter.Name)"
    } else {
        Write-Host "Advertencia: No se encontro adaptador de red activo"
    }

    # Lease time
    $LeaseTime = Read-Host "Tiempo de concesion en dias [1]"
    if (!$LeaseTime) { $LeaseTime = "1.00:00:00" } else { $LeaseTime = "$LeaseTime.00:00:00" }

    # Gateway (opcional)
    $Gateway = Read-Host "Gateway (Enter para omitir)"
    if ($Gateway) {
        while (!(Validar-IP $Gateway)) {
            $Gateway = Read-Host "Gateway invalido. Intenta de nuevo (Enter para omitir)"
            if (!$Gateway) { break }
        }
    }

    # DNS (opcional)
    $DNS1 = $null
    $DNS2 = $null
    $confDNS1 = Read-Host "Configurar DNS primario? (s/n) [n]"
    if ($confDNS1 -match "^[sS]$") {
        $DNS1 = Pedir-IP "DNS primario" "192.168.100.1"
        
        $confDNS2 = Read-Host "Configurar DNS alternativo? (s/n) [n]"
        if ($confDNS2 -match "^[sS]$") {
            $DNS2 = Pedir-IP "DNS alternativo" "8.8.8.8"
        }
    }

    # Eliminar ambito existente
    $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.ScopeId -eq "192.168.100.0" }
    if ($existing) {
        Write-Host "Eliminando ambito existente..."
        Remove-DhcpServerv4Scope -ScopeId 192.168.100.0 -Force
    }

    # Crear ambito
    Write-Host "Creando ambito..."
    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $startReal -EndRange $End -SubnetMask $mask -LeaseDuration $LeaseTime -State Active

    # Configurar Gateway
    if ($Gateway) {
        Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -Router $Gateway
    }

    # Configurar DNS
    if ($DNS1) {
        try {
            if ($DNS2) {
                Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -OptionId 6 -Value $DNS1, $DNS2 -Force
            } else {
                Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -OptionId 6 -Value $DNS1 -Force
            }
        } catch {
            Write-Host "Advertencia: DNS configurado sin validacion de conectividad"
        }
    }

    # Standalone server
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
    } catch {}

    # Reiniciar
    Restart-Service DHCPServer

    Write-Host ""
    Write-Host "=== INSTALACION COMPLETADA ==="
    Write-Host "Ambito:  $ScopeName"
    Write-Host "Rango:   $startReal - $End"
    Write-Host "Mascara: $mask"
    if ($Gateway) { Write-Host "Gateway: $Gateway" }
    if ($DNS1)    { Write-Host "DNS:     $DNS1 $(if ($DNS2) { "/ $DNS2" })" }

    Read-Host "Presiona Enter para volver al menu"
}

# ─────────────────────────────────────────
# MODIFICAR CONFIGURACION
# ─────────────────────────────────────────
function Modificar {
    Write-Host ""
    Write-Host "=== Modificar configuracion DHCP ==="

    $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if (!$scope) {
        Write-Host "Error: No hay configuracion existente. Instala primero."
        Read-Host "Presiona Enter para volver al menu"
        return
    }

    Write-Host "Configuracion actual:"
    $scope | Format-Table ScopeId, Name, StartRange, EndRange, State
    Get-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue | Select-Object OptionId, Name, Value | Format-Table

    # IP del servidor
    $serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.*" -and $_.PrefixOrigin -eq "Manual" } | Select-Object -First 1).IPAddress
    if (!$serverIP) {
        $serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" } | Select-Object -First 1).IPAddress
    }

    # Prefijo y mascara
    $prefix = Read-Host "Prefijo de subred [24]"
    if (!$prefix) { $prefix = 24 }
    $mask = Calcular-Mascara $prefix
    Write-Host "Mascara: $mask"

    # Nombre del ambito
    $ScopeName = Read-Host "Nombre del ambito [Red-Interna]"
    if (!$ScopeName) { $ScopeName = "Red-Interna" }

    # Rango inicial
    $Start = Pedir-IP "Rango inicial" "192.168.100.50"

    # Rango final
    while ($true) {
        $End = Pedir-IP "Rango final" "192.168.100.150"
        if ((IP-ToInt $End) -le (IP-ToInt $Start)) {
            Write-Host "Error: el rango final debe ser mayor que el inicial ($Start)"
            continue
        }
        break
    }

    # Ignorar primera IP (+1)
    $startParts = $Start.Split(".")
    $serverStatic = $Start
    $startReal = "$($startParts[0]).$($startParts[1]).$($startParts[2]).$([int]$startParts[3] + 1)"
    Write-Host "IP fija del servidor: $serverStatic"
    Write-Host "Rango DHCP real:      $startReal - $End"

    # Asignar IP fija al servidor
    Write-Host "Configurando IP fija $serverStatic/$prefix en el adaptador..."
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notlike "*Loopback*" } | Where-Object { (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -like "192.168.*" } | Select-Object -First 1
    if (!$adapter) {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notlike "*Loopback*" } | Select-Object -First 1
    }
    if ($adapter) {
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $serverStatic -PrefixLength $prefix -ErrorAction SilentlyContinue | Out-Null
        Write-Host "IP fija $serverStatic/$prefix asignada en $($adapter.Name)"
    } else {
        Write-Host "Advertencia: No se encontro adaptador de red activo"
    }

    # Lease time
    $LeaseTime = Read-Host "Tiempo de concesion en dias [1]"
    if (!$LeaseTime) { $LeaseTime = "1.00:00:00" } else { $LeaseTime = "$LeaseTime.00:00:00" }

    # Gateway (opcional)
    $Gateway = Read-Host "Gateway (Enter para omitir)"
    if ($Gateway) {
        while (!(Validar-IP $Gateway)) {
            $Gateway = Read-Host "Gateway invalido. Intenta de nuevo (Enter para omitir)"
            if (!$Gateway) { break }
        }
    }

    # DNS (opcional)
    $DNS1 = $null
    $DNS2 = $null
    $confDNS1 = Read-Host "Configurar DNS primario? (s/n) [n]"
    if ($confDNS1 -match "^[sS]$") {
        $DNS1 = Pedir-IP "DNS primario" "192.168.100.1"
        
        $confDNS2 = Read-Host "Configurar DNS alternativo? (s/n) [n]"
        if ($confDNS2 -match "^[sS]$") {
            $DNS2 = Pedir-IP "DNS alternativo" "8.8.8.8"
        }
    }

    # Eliminar ambito existente
    Remove-DhcpServerv4Scope -ScopeId 192.168.100.0 -Force -ErrorAction SilentlyContinue

    # Crear nuevo ambito
    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $startReal -EndRange $End -SubnetMask $mask -LeaseDuration $LeaseTime -State Active

    if ($Gateway) {
        Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -Router $Gateway
    }

    if ($DNS1) {
        try {
            $dnsValues = if ($DNS2) { @($DNS1, $DNS2) } else { @($DNS1) }
            Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -OptionId 6 -Value $dnsValues -Force
        } catch {
            Write-Host "Advertencia: DNS configurado sin validacion"
        }
    }

    Restart-Service DHCPServer

    Write-Host ""
    Write-Host "=== CONFIGURACION ACTUALIZADA ==="
    Write-Host "Rango:   $startReal - $End"
    Write-Host "Mascara: $mask"
    if ($Gateway) { Write-Host "Gateway: $Gateway" }
    if ($DNS1)    { Write-Host "DNS:     $DNS1 $(if ($DNS2) { "/ $DNS2" })" }

    Read-Host "Presiona Enter para volver al menu"
}

# ─────────────────────────────────────────
# REINICIAR SERVICIO
# ─────────────────────────────────────────
function Reiniciar {
    Write-Host ""
    Write-Host "Reiniciando servicio DHCP..."
    Restart-Service DHCPServer
    Get-Service DHCPServer | Select-Object Name, Status | Format-Table
    Read-Host "Presiona Enter para volver al menu"
}

# ─────────────────────────────────────────
# VERIFICAR PRIVILEGIOS
# ─────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Ejecuta como Administrador"
    exit 1
}

# ─────────────────────────────────────────
# MENU PRINCIPAL
# ─────────────────────────────────────────
while ($true) {
    Clear-Host
    Write-Host "================================"
    Write-Host "  DHCP Server Manager - Windows "
    Write-Host "================================"
    Write-Host "1) Verificar instalacion"
    Write-Host "2) Instalar DHCP"
    Write-Host "3) Modificar configuracion"
    Write-Host "4) Monitor"
    Write-Host "5) Reiniciar servicio"
    Write-Host "6) Salir"
    Write-Host "--------------------------------"
    $opt = Read-Host "> "

    switch ($opt) {
        "1" { Verificar-Instalacion }
        "2" { Instalar }
        "3" { Modificar }
        "4" { Monitor }
        "5" { Reiniciar }
        "6" { Write-Host "Saliendo..."; exit 0 }
        default { Write-Host "Opcion invalida"; Start-Sleep 1 }
    }
}