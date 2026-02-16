# =========================================================
# Script de configuracion de servidor DNS - Windows Server
# Dominio: reprobados.com | Interfaz: Ethernet1
# =========================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$DOMINIO_BASE = "reprobados.com"
$ADAPTADOR = "Ethernet1"
$EVIDENCIA_DIR = "C:\Evidencias_DNS"
$LOG = "$EVIDENCIA_DIR\dns_script.log"
$script:IP_SERVIDOR = ""
$script:IP_CLIENTE = ""

function Write-OK    { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Err   { param([string]$m) Write-Host "  [ERROR] $m" -ForegroundColor Red }
function Write-Inf   { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor Cyan }
function Write-Wrn   { param([string]$m) Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Pausar { Write-Host ""; Read-Host "  Presione ENTER para continuar" }

function Test-IP {
    param([string]$IP)
    if ($IP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        foreach ($o in $IP.Split('.')) { if ([int]$o -lt 0 -or [int]$o -gt 255) { return $false } }
        return $true
    }
    return $false
}

function Get-ServerIP {
    $a = Get-NetAdapter -Name $ADAPTADOR -ErrorAction SilentlyContinue
    if ($a) {
        $c = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1
        if ($c) { $script:IP_SERVIDOR = $c.IPAddress }
    }
}

# verificar administrador
$cur = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($cur)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Error: ejecute como Administrador." -ForegroundColor Red
    pause; exit 1
}

if (-not (Test-Path $EVIDENCIA_DIR)) { New-Item -ItemType Directory -Path $EVIDENCIA_DIR -Force | Out-Null }

# =========================================================
# FUNCION: CONFIGURAR IP ESTATICA
# =========================================================
function Configurar-IP {
    $a = Get-NetAdapter -Name $ADAPTADOR -ErrorAction SilentlyContinue
    if (-not $a) { Write-Err "Adaptador '$ADAPTADOR' no encontrado."; return $false }
    $idx = $a.InterfaceIndex

    if ($a.Status -ne "Up") {
        Write-Wrn "Adaptador inactivo, activando..."
        Enable-NetAdapter -Name $ADAPTADOR -Confirm:$false
        Start-Sleep 3
    }

    $cfg = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1
    $dhcp = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4

    if ($dhcp.Dhcp -eq "Disabled" -and $cfg) {
        $script:IP_SERVIDOR = $cfg.IPAddress
        Write-OK "IP estatica ya configurada: $($script:IP_SERVIDOR)"
        return $true
    }

    Write-Wrn "Adaptador en DHCP, se necesita IP fija."
    if ($cfg) { $ipDef = $cfg.IPAddress; $prDef = $cfg.PrefixLength } else { $ipDef = "192.168.1.10"; $prDef = 24 }
    Write-Host ""

    do { $inIP = Read-Host "  IP del servidor [$ipDef]"
        if ([string]::IsNullOrWhiteSpace($inIP)) { $inIP = $ipDef }
    } while (-not (Test-IP $inIP))

    $inPref = Read-Host "  Prefijo CIDR [$prDef]"
    if ([string]::IsNullOrWhiteSpace($inPref)) { $inPref = $prDef }

    $gwDef = (Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue).NextHop
    if (-not $gwDef) { $gwDef = "192.168.1.1" }

    do { $inGW = Read-Host "  Gateway [$gwDef]"
        if ([string]::IsNullOrWhiteSpace($inGW)) { $inGW = $gwDef }
    } while (-not (Test-IP $inGW))

    $inDNS = Read-Host "  DNS respaldo [8.8.8.8]"
    if ([string]::IsNullOrWhiteSpace($inDNS)) { $inDNS = "8.8.8.8" }

    Remove-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $idx -IPAddress $inIP -PrefixLength ([int]$inPref) -DefaultGateway $inGW | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @("127.0.0.1", $inDNS)

    $script:IP_SERVIDOR = $inIP
    Write-OK "IP configurada: $($script:IP_SERVIDOR)/$inPref"
    return $true
}

# funcion para obtener zonas personalizadas
function Get-ZonasCustom {
    try {
        return Get-DnsServerZone -ErrorAction Stop | Where-Object {
            $_.ZoneType -eq "Primary" -and $_.ZoneName -notlike "*in-addr*" -and
            $_.ZoneName -ne "TrustAnchors" -and $_.IsAutoCreated -eq $false
        }
    } catch { return $null }
}

# =========================================================
# MENU PRINCIPAL
# =========================================================
while ($true) {
    Clear-Host
    Get-ServerIP

    $feat = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
    $estPkg = if ($feat.Installed) { "Instalado" } else { "No instalado" }
    $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
    $estSvc = if ($svc -and $svc.Status -eq "Running") { "Activo" } else { "Inactivo" }

    Write-Host ""
    Write-Host "  SERVIDOR DNS - Windows Server" -ForegroundColor White
    Write-Host "  ================================================"
    Write-Host "  DNS: $estPkg | Servicio: $estSvc | IP: $($script:IP_SERVIDOR)"
    Write-Host "  ================================================"
    Write-Host ""
    Write-Host "  1) Verificar instalacion"
    Write-Host "  2) Instalar DNS"
    Write-Host "  3) Configurar (zona $DOMINIO_BASE)"
    Write-Host "  4) Reconfigurar"
    Write-Host "  5) Administrar dominios (ABC)"
    Write-Host "  6) Validar y probar resolucion"
    Write-Host "  0) Salir"
    Write-Host ""
    $opc = Read-Host "  Opcion"

    switch ($opc) {

# =========================================================
# 1) VERIFICAR
# =========================================================
    "1" {
        Clear-Host
        Write-Host "`n  -- VERIFICACION DE INSTALACION --`n"

        Write-Host "  Rol DNS:"
        $feat = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
        if ($feat.Installed) { Write-OK "Instalado" } else { Write-Err "No instalado" }

        Write-Host "`n  Servicio:"
        $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { Write-OK "Activo" } else { Write-Wrn "Inactivo" }

        Write-Host "`n  Adaptador $ADAPTADOR :"
        $a = Get-NetAdapter -Name $ADAPTADOR -ErrorAction SilentlyContinue
        if ($a) {
            Write-OK "Estado: $($a.Status)"
            $cfg = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1
            if ($cfg) { Write-OK "IP: $($cfg.IPAddress)/$($cfg.PrefixLength)" }
            $d = Get-NetIPInterface -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4
            if ($d.Dhcp -eq "Disabled") { Write-OK "IP Estatica" } else { Write-Wrn "DHCP" }
        } else { Write-Err "No encontrado" }

        Write-Host "`n  Zonas:"
        $zonas = Get-ZonasCustom
        if ($zonas) { foreach ($z in $zonas) { Write-Host "    - $($z.ZoneName)" } }
        else { Write-Wrn "Ninguna zona personalizada" }

        Write-Host "`n  Firewall:"
        $reglas = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*DNS*" -and $_.Direction -eq "Inbound" -and $_.Enabled -eq "True" }
        if ($reglas) { Write-OK "Reglas DNS habilitadas ($($reglas.Count))" } else { Write-Wrn "Sin reglas DNS" }

        Pausar
    }

# =========================================================
# 2) INSTALAR
# =========================================================
    "2" {
        Clear-Host
        Write-Host "`n  -- INSTALACION DE DNS --`n"

        $feat = Get-WindowsFeature -Name DNS
        if ($feat.Installed) {
            Write-OK "Ya esta instalado, no hay nada que hacer."
            $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") { Write-OK "Servicio activo." }
            Pausar
            continue
        }

        Write-Inf "Instalando rol DNS con herramientas de administracion..."
        Write-Host ""
        $res = Install-WindowsFeature -Name DNS -IncludeManagementTools

        if ($res.Success) {
            Write-Host ""
            Write-OK "Rol DNS instalado."
            if ($res.RestartNeeded -eq "Yes") {
                Write-Wrn "Se necesita reiniciar. Reinicie y vuelva a ejecutar."
                Pausar; exit 0
            }
            Start-Service DNS -ErrorAction SilentlyContinue
            Write-OK "Servicio iniciado."
            Write-Inf "Use la opcion 3 para configurar la zona."
        } else {
            Write-Err "Fallo en la instalacion."
        }
        Pausar
    }

# =========================================================
# 3) CONFIGURAR
# =========================================================
    "3" {
        Clear-Host
        Write-Host "`n  -- CONFIGURACION INICIAL --`n"

        $feat = Get-WindowsFeature -Name DNS
        if (-not $feat.Installed) { Write-Err "DNS no instalado. Use opcion 2."; Pausar; continue }

        Configurar-IP

        Write-Host ""
        Write-Inf "Los registros A apuntaran a la IP del cliente."
        do { $script:IP_CLIENTE = Read-Host "  IP de la maquina cliente" } while (-not (Test-IP $script:IP_CLIENTE))

        # crear zona (eliminar si ya existe)
        Write-Host ""
        $existe = Get-DnsServerZone -Name $DOMINIO_BASE -ErrorAction SilentlyContinue
        if ($existe) {
            Write-Wrn "Zona existente, se reemplazara."
            Remove-DnsServerZone -Name $DOMINIO_BASE -Force
            Start-Sleep 2
        }

        Write-Inf "Creando zona $DOMINIO_BASE..."
        Add-DnsServerPrimaryZone -Name $DOMINIO_BASE -ZoneFile "db.$DOMINIO_BASE.dns" -DynamicUpdate None
        Start-Sleep 2

        Add-DnsServerResourceRecordA -ZoneName $DOMINIO_BASE -Name "@" -IPv4Address $script:IP_CLIENTE
        Write-OK "$DOMINIO_BASE -> A -> $($script:IP_CLIENTE)"

        Add-DnsServerResourceRecordCName -ZoneName $DOMINIO_BASE -Name "www" -HostNameAlias "$DOMINIO_BASE"
        Write-OK "www.$DOMINIO_BASE -> CNAME -> $DOMINIO_BASE"

        Add-DnsServerResourceRecordA -ZoneName $DOMINIO_BASE -Name "ns1" -IPv4Address $script:IP_SERVIDOR
        Write-OK "ns1.$DOMINIO_BASE -> A -> $($script:IP_SERVIDOR)"

        # firewall
        Write-Host ""
        $reglas = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*DNS*" -and $_.Direction -eq "Inbound" }
        if ($reglas) {
            $reglas | Enable-NetFirewallRule
            Write-OK "Reglas DNS habilitadas."
        } else {
            New-NetFirewallRule -DisplayName "DNS (UDP-In)" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow | Out-Null
            New-NetFirewallRule -DisplayName "DNS (TCP-In)" -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow | Out-Null
            Write-OK "Reglas de firewall creadas."
        }

        Write-Host ""
        Write-Host "  Resumen:"
        Write-Host "    $DOMINIO_BASE      -> A     $($script:IP_CLIENTE)"
        Write-Host "    www.$DOMINIO_BASE  -> CNAME $DOMINIO_BASE"
        Write-Host "    ns1.$DOMINIO_BASE  -> A     $($script:IP_SERVIDOR)"

        Pausar
    }

# =========================================================
# 4) RECONFIGURAR
# =========================================================
    "4" {
        Clear-Host
        Write-Host "`n  -- RECONFIGURAR --`n"
        Write-Host "  1) Cambiar IP estatica ($ADAPTADOR)"
        Write-Host "  2) Cambiar IP cliente en zona $DOMINIO_BASE"
        Write-Host "  3) Reiniciar servicio DNS"
        Write-Host "  0) Volver"
        Write-Host ""
        $s4 = Read-Host "  Opcion"

        switch ($s4) {
            "1" {
                Configurar-IP
                $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq "Running") {
                    Restart-Service DNS; Write-OK "DNS reiniciado."
                }
                Pausar
            }
            "2" {
                do { $nIP = Read-Host "  Nueva IP del cliente" } while (-not (Test-IP $nIP))
                try {
                    $rA = Get-DnsServerResourceRecord -ZoneName $DOMINIO_BASE -Name "@" -RRType A -ErrorAction Stop
                    foreach ($r in $rA) { Remove-DnsServerResourceRecord -ZoneName $DOMINIO_BASE -InputObject $r -Force }
                } catch {}
                Add-DnsServerResourceRecordA -ZoneName $DOMINIO_BASE -Name "@" -IPv4Address $nIP
                Write-OK "Registro actualizado: $DOMINIO_BASE -> $nIP"
                Pausar
            }
            "3" {
                Restart-Service DNS -ErrorAction SilentlyContinue; Start-Sleep 2
                $svc = Get-Service -Name DNS
                if ($svc.Status -eq "Running") { Write-OK "Servicio activo" } else { Write-Err "No pudo iniciar" }
                Pausar
            }
        }
    }

# =========================================================
# 5) ADMINISTRAR DOMINIOS (ABC)
# =========================================================
    "5" {
        $volverABC = $false
        while (-not $volverABC) {
            Clear-Host
            Write-Host "`n  -- ADMINISTRACION DE DOMINIOS --"
            Write-Host "  Dominio -> IP -> Funcionamiento: Comunicaciones entre IP`n"
            Write-Host "  1) Consultar  (listar zonas y registros)"
            Write-Host "  2) Agregar    (nueva zona)"
            Write-Host "  3) Configurar (editar registros)"
            Write-Host "  4) Eliminar   (quitar zona)"
            Write-Host "  0) Volver"
            Write-Host ""
            $s5 = Read-Host "  Opcion"

            switch ($s5) {

            # --- CONSULTAR ---
            "1" {
                Clear-Host
                Write-Host "`n  -- ZONAS CONFIGURADAS --`n"
                $zonas = Get-ZonasCustom
                if (-not $zonas) { Write-Wrn "No hay zonas."; Pausar; continue }

                $n = 1
                foreach ($z in $zonas) {
                    Write-Host "  [$n] $($z.ZoneName)"
                    Write-Host "      Tipo: $($z.ZoneType)"
                    try {
                        $regs = Get-DnsServerResourceRecord -ZoneName $z.ZoneName -ErrorAction Stop
                        $rA = $regs | Where-Object { $_.RecordType -eq "A" }
                        if ($rA) {
                            Write-Host "      Registros A:"
                            foreach ($r in $rA) {
                                $nm = $r.HostName; $ip = $r.RecordData.IPv4Address.IPAddressToString
                                if ($nm -eq "@") { Write-Host "        $($z.ZoneName) -> $ip" }
                                else { Write-Host "        $nm.$($z.ZoneName) -> $ip" }
                            }
                        }
                        $rC = $regs | Where-Object { $_.RecordType -eq "CNAME" }
                        if ($rC) {
                            Write-Host "      Registros CNAME:"
                            foreach ($r in $rC) { Write-Host "        $($r.HostName).$($z.ZoneName) -> $($r.RecordData.HostNameAlias)" }
                        }
                    } catch { Write-Wrn "      No se pudieron leer registros" }
                    Write-Host ""
                    $n++
                }
                Pausar
            }

            # --- AGREGAR ---
            "2" {
                Clear-Host
                Write-Host "`n  -- AGREGAR DOMINIO --`n"
                Get-ServerIP
                if ([string]::IsNullOrWhiteSpace($script:IP_SERVIDOR)) { Write-Err "Sin IP en $ADAPTADOR"; Pausar; continue }

                $nd = Read-Host "  Nombre del dominio (ej: ejemplo.com)"
                if ([string]::IsNullOrWhiteSpace($nd) -or $nd -notmatch '\.') { Write-Err "Invalido."; Pausar; continue }

                $ex = Get-DnsServerZone -Name $nd -ErrorAction SilentlyContinue
                if ($ex) { Write-Err "'$nd' ya existe. Use Configurar."; Pausar; continue }

                do { $ipD = Read-Host "  IP destino para $nd" } while (-not (Test-IP $ipD))

                Write-Inf "Creando zona $nd..."
                Add-DnsServerPrimaryZone -Name $nd -ZoneFile "db.$nd.dns" -DynamicUpdate None
                Start-Sleep 2

                Add-DnsServerResourceRecordA -ZoneName $nd -Name "@" -IPv4Address $ipD
                Write-OK "$nd -> A -> $ipD"
                Add-DnsServerResourceRecordCName -ZoneName $nd -Name "www" -HostNameAlias "$nd"
                Write-OK "www.$nd -> CNAME -> $nd"
                Add-DnsServerResourceRecordA -ZoneName $nd -Name "ns1" -IPv4Address $script:IP_SERVIDOR
                Write-OK "ns1.$nd -> A -> $($script:IP_SERVIDOR)"
                Pausar
            }

            # --- CONFIGURAR REGISTROS ---
            "3" {
                Clear-Host
                Write-Host "`n  -- CONFIGURAR REGISTROS --`n"
                $zonas = Get-ZonasCustom
                if (-not $zonas) { Write-Wrn "No hay zonas."; Pausar; continue }

                $za = @($zonas)
                for ($i = 0; $i -lt $za.Count; $i++) { Write-Host "  $($i+1)) $($za[$i].ZoneName)" }
                Write-Host ""
                $sel = Read-Host "  Seleccione zona"
                $ix = [int]$sel - 1
                if ($ix -lt 0 -or $ix -ge $za.Count) { Write-Err "Invalido."; Pausar; continue }
                $zs = $za[$ix].ZoneName

                $volverReg = $false
                while (-not $volverReg) {
                    Clear-Host
                    Write-Host "`n  -- Editando: $zs --`n"
                    Write-Host "  Registros actuales:"
                    try {
                        $regs = Get-DnsServerResourceRecord -ZoneName $zs | Where-Object { $_.RecordType -eq "A" -or $_.RecordType -eq "CNAME" }
                        foreach ($r in $regs) {
                            if ($r.RecordType -eq "A") { Write-Host "    $($r.HostName) -> A -> $($r.RecordData.IPv4Address.IPAddressToString)" }
                            elseif ($r.RecordType -eq "CNAME") { Write-Host "    $($r.HostName) -> CNAME -> $($r.RecordData.HostNameAlias)" }
                        }
                    } catch {}

                    Write-Host ""
                    Write-Host "  1) Agregar registro A"
                    Write-Host "  2) Agregar registro CNAME"
                    Write-Host "  3) Eliminar registro"
                    Write-Host "  4) Cambiar IP raiz (@)"
                    Write-Host "  0) Volver"
                    Write-Host ""
                    $ac = Read-Host "  Opcion"

                    switch ($ac) {
                        "1" {
                            $sd = Read-Host "  Subdominio (ej: ftp, mail)"
                            if ([string]::IsNullOrWhiteSpace($sd)) { Write-Err "Vacio."; Start-Sleep 1; continue }
                            try { $ex = Get-DnsServerResourceRecord -ZoneName $zs -Name $sd -RRType A -ErrorAction Stop
                                Remove-DnsServerResourceRecord -ZoneName $zs -InputObject $ex -Force } catch {}
                            do { $ipS = Read-Host "  IP para $sd.$zs" } while (-not (Test-IP $ipS))
                            Add-DnsServerResourceRecordA -ZoneName $zs -Name $sd -IPv4Address $ipS
                            Write-OK "A: $sd.$zs -> $ipS"
                            Start-Sleep 2
                        }
                        "2" {
                            $an = Read-Host "  Nombre del alias"
                            if ([string]::IsNullOrWhiteSpace($an)) { Write-Err "Vacio."; Start-Sleep 1; continue }
                            $at = Read-Host "  Apunta a (ej: mail.$zs)"
                            if ([string]::IsNullOrWhiteSpace($at)) { Write-Err "Vacio."; Start-Sleep 1; continue }
                            try { $ex = Get-DnsServerResourceRecord -ZoneName $zs -Name $an -RRType CNAME -ErrorAction Stop
                                Remove-DnsServerResourceRecord -ZoneName $zs -InputObject $ex -Force } catch {}
                            Add-DnsServerResourceRecordCName -ZoneName $zs -Name $an -HostNameAlias $at
                            Write-OK "CNAME: $an.$zs -> $at"
                            Start-Sleep 2
                        }
                        "3" {
                            $rd = Read-Host "  Nombre del registro a eliminar"
                            if ([string]::IsNullOrWhiteSpace($rd)) { Write-Err "Vacio."; Start-Sleep 1; continue }
                            try {
                                $enc = Get-DnsServerResourceRecord -ZoneName $zs -Name $rd -ErrorAction Stop | Where-Object { $_.RecordType -eq "A" -or $_.RecordType -eq "CNAME" }
                                foreach ($r in $enc) { Remove-DnsServerResourceRecord -ZoneName $zs -InputObject $r -Force }
                                Write-OK "'$rd' eliminado."
                            } catch { Write-Err "No se encontro '$rd'." }
                            Start-Sleep 2
                        }
                        "4" {
                            do { $nIP = Read-Host "  Nueva IP para $zs (@)" } while (-not (Test-IP $nIP))
                            try {
                                $rA = Get-DnsServerResourceRecord -ZoneName $zs -Name "@" -RRType A -ErrorAction Stop
                                foreach ($r in $rA) { Remove-DnsServerResourceRecord -ZoneName $zs -InputObject $r -Force }
                            } catch {}
                            Add-DnsServerResourceRecordA -ZoneName $zs -Name "@" -IPv4Address $nIP
                            Write-OK "IP raiz actualizada: $zs -> $nIP"
                            Start-Sleep 2
                        }
                        "0" { $volverReg = $true }
                    }
                }
            }

            # --- ELIMINAR ---
            "4" {
                Clear-Host
                Write-Host "`n  -- ELIMINAR DOMINIO --`n"
                $zonas = Get-ZonasCustom
                if (-not $zonas) { Write-Wrn "No hay zonas."; Pausar; continue }

                $za = @($zonas)
                for ($i = 0; $i -lt $za.Count; $i++) { Write-Host "  $($i+1)) $($za[$i].ZoneName)" }
                Write-Host ""
                $sel = Read-Host "  Zona a eliminar"
                $ix = [int]$sel - 1
                if ($ix -lt 0 -or $ix -ge $za.Count) { Write-Err "Invalido."; Pausar; continue }
                $zd = $za[$ix].ZoneName

                Write-Host ""
                Write-Host "  Seguro de eliminar '$zd'?" -ForegroundColor Red
                $conf = Read-Host "  Escriba SI para confirmar"
                if ($conf -ne "SI") { Write-Inf "Cancelado."; Pausar; continue }

                Remove-DnsServerZone -Name $zd -Force
                Write-OK "Zona '$zd' eliminada."
                Pausar
            }

            "0" { $volverABC = $true }
            }
        }
    }

# =========================================================
# 6) VALIDAR Y PROBAR
# =========================================================
    "6" {
        Clear-Host
        Write-Host "`n  -- VALIDACION Y PRUEBAS --`n"

        $evid = "$EVIDENCIA_DIR\validacion_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $cont = @()
        $cont += "=== REPORTE DNS - $(Get-Date) ==="
        $cont += "Servidor: $env:COMPUTERNAME | IP: $($script:IP_SERVIDOR)"
        $cont += ""

        # servicio
        Write-Host "  Estado del servicio:"
        $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { Write-OK "Activo"; $cont += "Servicio: Activo" }
        else { Write-Err "Inactivo"; $cont += "Servicio: Inactivo" }

        # pruebas por zona
        Write-Host "`n  Pruebas de resolucion:"
        $zonas = Get-ZonasCustom

        if (-not $zonas) { Write-Wrn "No hay zonas."; Pausar; continue }

        foreach ($z in $zonas) {
            $nm = $z.ZoneName
            Write-Host "`n  --- $nm ---"
            $cont += "=== $nm ==="

            # nslookup
            $r1 = nslookup $nm 127.0.0.1 2>&1 | Out-String
            $cont += $r1
            if ($r1 -match '\d+\.\d+\.\d+\.\d+') { Write-OK "nslookup $nm : OK" } else { Write-Wrn "nslookup $nm : sin respuesta" }

            $r2 = nslookup "www.$nm" 127.0.0.1 2>&1 | Out-String
            $cont += $r2
            if ($r2 -match '\d+\.\d+\.\d+\.\d+') { Write-OK "nslookup www.$nm : OK" } else { Write-Wrn "nslookup www.$nm : sin respuesta" }

            # Resolve-DnsName
            try {
                $r3 = Resolve-DnsName -Name $nm -Server 127.0.0.1 -Type A -ErrorAction Stop
                $cont += ($r3 | Format-Table | Out-String)
                Write-OK "Resolve-DnsName $nm -> $($r3.IPAddress)"
            } catch { Write-Wrn "Resolve-DnsName $nm : error"; $cont += "Error: $_" }

            # registros
            try { $cont += (Get-DnsServerResourceRecord -ZoneName $nm | Format-Table -AutoSize | Out-String) } catch {}

            # ping
            $cont += (ping $nm -n 2 2>&1 | Out-String)
            $cont += (ping "www.$nm" -n 2 2>&1 | Out-String)
        }

        $cont | Out-File -FilePath $evid -Encoding UTF8
        Write-Host ""
        Write-OK "Evidencias: $evid"
        Pausar
    }

    "0" { Write-Host "`n  Saliendo..."; exit 0 }
    }
}