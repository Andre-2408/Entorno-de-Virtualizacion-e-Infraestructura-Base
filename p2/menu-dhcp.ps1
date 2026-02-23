# lib/dhcp_functions.ps1
# Depende de: common_functions.ps1

$ADAPTADOR = "Ethernet 1"

# ─────────────────────────────────────────
# VERIFICAR INSTALACION
# ─────────────────────────────────────────
function DHCP-Verificar {
    Write-Host ""
    Write-Host "=== Verificando instalacion ==="

    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  Servicio DHCP: $($svc.Status)"
    } else {
        Write-Host "  Servicio DHCP: NO instalado"
    }

    $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if ($scope) {
        Write-Host "  Ambitos configurados:"
        $scope | Format-Table ScopeId, Name, StartRange, EndRange, State
    } else {
        Write-Host "  No hay ambitos configurados"
    }
    Pausar
}

# ─────────────────────────────────────────
# MONITOR
# ─────────────────────────────────────────
function DHCP-Monitor {
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
        Get-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue |
            Select-Object OptionId, Name, Value | Format-Table
        Write-Host ""
        Write-Host "r) Refrescar    0) Volver"
        $opt = Read-Host "> "
        if ($opt -eq "0") { return }
    }
}

# ─────────────────────────────────────────
# HELPER: CONFIGURAR ADAPTADOR + RANGO
# ─────────────────────────────────────────
function _DHCP-PedirDatos {
    $data = @{}

    $serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.*" -and $_.PrefixOrigin -eq "Manual" } | Select-Object -First 1).IPAddress
    if (!$serverIP) {
        $serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
    }
    Write-Host "  IP del servidor detectada: $serverIP"

    $prefix = Read-Host "  Prefijo de subred [24]"
    if (!$prefix) { $prefix = 24 }
    $data.mask = Calcular-Mascara $prefix
    Write-Host "  Mascara calculada: $($data.mask)"

    $data.name = Read-Host "  Nombre del ambito [Red-Interna]"
    if (!$data.name) { $data.name = "Red-Interna" }

    $data.start = Pedir-IP "Rango inicial" "192.168.100.50"
    while ($true) {
        $data.end = Pedir-IP "Rango final" "192.168.100.150"
        if ((IP-ToInt $data.end) -le (IP-ToInt $data.start)) {
            Write-Host "  Error: el final debe ser mayor que el inicial ($($data.start))"
            continue
        }
        break
    }

    $sp = $data.start.Split(".")
    $data.serverStatic = $data.start
    $data.startReal = "$($sp[0]).$($sp[1]).$($sp[2]).$([int]$sp[3] + 1)"
    Write-Host "  IP fija del servidor: $($data.serverStatic)"
    Write-Host "  Rango DHCP real:      $($data.startReal) - $($data.end)"

    $adapter = Get-NetAdapter -Name $ADAPTADOR -ErrorAction SilentlyContinue
    if (!$adapter) {
        Write-Wrn "Adaptador '$ADAPTADOR' no encontrado. Detectando automatico..."
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notlike "*Loopback*" } | Select-Object -First 1
    }
    if ($adapter) {
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $data.serverStatic -PrefixLength $prefix -ErrorAction SilentlyContinue | Out-Null
        Write-OK "IP fija $($data.serverStatic)/$prefix asignada en $($adapter.Name)"
    } else {
        Write-Wrn "No se encontro adaptador de red activo"
    }

    $lt = Read-Host "  Tiempo de concesion en dias [1]"
    $data.lease = if (!$lt) { "1.00:00:00" } else { "$lt.00:00:00" }

    $data.gateway = Read-Host "  Gateway (Enter para omitir)"
    if ($data.gateway) {
        while (!(Validar-IP $data.gateway)) {
            $data.gateway = Read-Host "  Gateway invalido. Intenta de nuevo (Enter para omitir)"
            if (!$data.gateway) { break }
        }
    }

    $data.dns1 = $null; $data.dns2 = $null
    $d1 = Read-Host "  ¿Configurar DNS primario? (s/n) [n]"
    if ($d1 -match "^[sS]$") {
        $data.dns1 = Pedir-IP "DNS primario" "192.168.100.1"
        $d2 = Read-Host "  ¿DNS alternativo? (s/n) [n]"
        if ($d2 -match "^[sS]$") {
            $data.dns2 = Pedir-IP "DNS alternativo" "8.8.8.8"
        }
    }
    return $data
}

function _DHCP-AplicarConfig {
    param($data)
    $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.ScopeId -eq "192.168.100.0" }
    if ($existing) {
        Write-Host "  Eliminando ambito existente..."
        Remove-DhcpServerv4Scope -ScopeId 192.168.100.0 -Force
    }

    Add-DhcpServerv4Scope -Name $data.name -StartRange $data.startReal -EndRange $data.end `
        -SubnetMask $data.mask -LeaseDuration $data.lease -State Active

    if ($data.gateway) {
        Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -Router $data.gateway
    }
    if ($data.dns1) {
        try {
            $dnsVals = if ($data.dns2) { @($data.dns1, $data.dns2) } else { @($data.dns1) }
            Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -OptionId 6 -Value $dnsVals -Force
        } catch { Write-Wrn "DNS configurado sin validacion" }
    }
    Restart-Service DHCPServer
}

# ─────────────────────────────────────────
# INSTALAR
# ─────────────────────────────────────────
function DHCP-Instalar {
    Write-Host ""
    Write-Host "=== Instalacion DHCP Server ==="

    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Wrn "DHCP ya instalado y activo."
        $r = Read-Host "  ¿Reinstalar? (s/n)"
        if ($r -notmatch "^[sS]$") { return }
    }

    if (!$svc) {
        Write-Host "  Instalando rol DHCP..."
        dism /online /enable-feature /featurename:DHCPServer /all
    }

    $data = _DHCP-PedirDatos

    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
    } catch {}

    _DHCP-AplicarConfig $data

    Write-Host ""
    Write-Host "=== INSTALACION COMPLETADA ==="
    Write-Host "  Ambito:  $($data.name)"
    Write-Host "  Rango:   $($data.startReal) - $($data.end)"
    Write-Host "  Mascara: $($data.mask)"
    if ($data.gateway) { Write-Host "  Gateway: $($data.gateway)" }
    if ($data.dns1)    { Write-Host "  DNS:     $($data.dns1) $(if ($data.dns2) { "/ $($data.dns2)" })" }
    Pausar
}

# ─────────────────────────────────────────
# MODIFICAR CONFIGURACION
# ─────────────────────────────────────────
function DHCP-Modificar {
    Write-Host ""
    Write-Host "=== Modificar configuracion DHCP ==="

    $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if (!$scope) {
        Write-Err "No hay configuracion. Instala primero."
        Pausar; return
    }

    Write-Host "  Configuracion actual:"
    $scope | Format-Table ScopeId, Name, StartRange, EndRange, State
    Get-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue |
        Select-Object OptionId, Name, Value | Format-Table

    $data = _DHCP-PedirDatos
    _DHCP-AplicarConfig $data

    Write-Host ""
    Write-Host "=== CONFIGURACION ACTUALIZADA ==="
    Write-Host "  Rango:   $($data.startReal) - $($data.end)"
    Write-Host "  Mascara: $($data.mask)"
    if ($data.gateway) { Write-Host "  Gateway: $($data.gateway)" }
    if ($data.dns1)    { Write-Host "  DNS:     $($data.dns1) $(if ($data.dns2) { "/ $($data.dns2)" })" }
    Pausar
}

# ─────────────────────────────────────────
# REINICIAR
# ─────────────────────────────────────────
function DHCP-Reiniciar {
    Write-Host ""
    Write-Host "Reiniciando servicio DHCP..."
    Restart-Service DHCPServer
    Get-Service DHCPServer | Select-Object Name, Status | Format-Table
    Pausar
}