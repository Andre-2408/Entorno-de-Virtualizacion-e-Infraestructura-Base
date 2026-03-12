#
# VersionControl.ps1
# Grupo D - Gestion de versiones (upgrade / downgrade)
#
# Equivalente a VersionControl.sh de la practica Linux.
# En Windows el gestor de paquetes es Chocolatey (choco) en lugar de dnf.
#
# Funciones publicas:
#   http_ver_version_instalada()   - Panel de versiones instaladas vs disponibles
#   http_upgrade_servicio()        - Actualiza a version superior (choco upgrade)
#   http_downgrade_servicio()      - Retrocede a version anterior (choco install --version)
#   http_menu_versiones()          - Submenu del Grupo D
#
# Funciones internas (prefijo _):
#   _http_comparar_versiones()     - Compara dos cadenas semver
#   _http_versiones_superiores()   - Filtra versiones > instalada
#   _http_versiones_inferiores()   - Filtra versiones < instalada
#   _http_ejecutar_cambio_version()- Orquestador comun upgrade/downgrade
#
# Requiere: CoreHelpers.ps1, HTTPGlobals.ps1, InputGuard.ps1,
#           StatusCheck.ps1, Installer.ps1, ConfigManager.ps1
#

#Requires -Version 5.1

function _http_comparar_versiones {
    param([string]$V1, [string]$V2)

    # Limpiar sufijos de release (ej: "2.4.58-1.fc43" === "2.4.58")
    $v1Clean = ($V1 -split '-')[0]
    $v2Clean = ($V2 -split '-')[0]

    try {
        $ver1 = [version]$v1Clean
        $ver2 = [version]$v2Clean

        if ($ver1 -lt $ver2) { return "menor" }
        if ($ver1 -gt $ver2) { return "mayor" }
        return "igual"
    }
    catch {
        # Si no se puede parsear como version, comparar como string
        if ($v1Clean -lt $v2Clean) { return "menor" }
        if ($v1Clean -gt $v2Clean) { return "mayor" }
        return "igual"
    }
}

function _http_versiones_superiores {
    param([string]$Servicio, [string]$VersionActual)

    $paquete = http_nombre_paquete $Servicio
    $verActClean = ($VersionActual -split '-')[0]

    $todas = choco list $paquete --all 2>$null |
    Where-Object { $_ -match "^$paquete\s+[\d]" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    return ($todas | Where-Object {
            $v = ($_ -split '-')[0]
            (_http_comparar_versiones $v $verActClean) -eq "mayor"
        } | Sort-Object { [version](($_ -split '-')[0]) } -Descending)
}

function _http_versiones_inferiores {
    param([string]$Servicio, [string]$VersionActual)

    $paquete = http_nombre_paquete $Servicio
    $verActClean = ($VersionActual -split '-')[0]

    $todas = choco list $paquete --all 2>$null |
    Where-Object { $_ -match "^$paquete\s+[\d]" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    return ($todas | Where-Object {
            $v = ($_ -split '-')[0]
            (_http_comparar_versiones $v $verActClean) -eq "menor"
        } | Sort-Object { [version](($_ -split '-')[0]) } -Descending)
}

function http_ver_version_instalada {
    Clear-Host
    draw_header "Version Instalada de Servicios HTTP"

    $servicios = @(
        @{ Interno = "iis"; Nombre = "IIS"; WinSvc = $Script:HTTP_WINSVC_IIS }
        @{ Interno = "apache"; Nombre = "Apache (httpd)"; WinSvc = $Script:HTTP_WINSVC_APACHE }
        @{ Interno = "nginx"; Nombre = "Nginx"; WinSvc = $Script:HTTP_WINSVC_NGINX }
        @{ Interno = "tomcat"; Nombre = "Tomcat"; WinSvc = $Script:HTTP_WINSVC_TOMCAT }
    )

    foreach ($svc in $servicios) {
        Write-Host ""
        Write-Host "  ${CYAN}=== $($svc.Nombre)${NC}"
        Write-Host "  "

        # IIS: version desde el registro
        if ($svc.Interno -eq "iis") {
            $iisReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
                -ErrorAction SilentlyContinue
            if ($iisReg) {
                Write-Host ("  ${GREEN}[OK]${NC}  {0,-20}: {1}" -f "Version instalada", $iisReg.VersionString)
                Write-Host ("        {0,-20}: Sistema Windows" -f "Gestor")
            }
            else {
                Write-Host ("  ${GRAY}[--]${NC}  No instalado")
            }
            Write-Host ""
            continue
        }

        # Resto: detectar via Get-Service (primario) + choco para version
        $paquete   = http_nombre_paquete $svc.Interno
        $svcObj    = Get-Service -Name $svc.WinSvc -ErrorAction SilentlyContinue
        $chocoInfo = choco list $paquete 2>$null | Where-Object { $_ -match "^$paquete\s" }

        if (-not $svcObj -and -not $chocoInfo) {
            Write-Host ("  ${GRAY}[--]${NC}  No instalado")
            Write-Host ""
            continue
        }

        $verInstalada = ($chocoInfo -split '\s+')[1]
        Write-Host ("  ${GREEN}[OK]${NC}  {0,-20}: {1}" -f "Version instalada", $verInstalada)

        # Fecha de instalacion (desde el log de choco si existe)
        $chocoLog = "$env:ChocolateyInstall\logs\chocolatey.log"
        if (Test-Path $chocoLog) {
            $fechaLine = Get-Content $chocoLog |
            Where-Object { $_ -match "Successfully installed '$paquete'" } |
            Select-Object -Last 1
            if ($fechaLine -match '\d{4}-\d{2}-\d{2}') {
                Write-Host ("        {0,-20}: {1}" -f "Instalado el", $Matches[0])
            }
        }

        # Estado del servicio
        if (check_service_active $svc.WinSvc) {
            $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='$($svc.WinSvc)'" `
                -ErrorAction SilentlyContinue
            $pidStr = if ($wmiSvc) { "PID: $($wmiSvc.ProcessId)" } else { "" }
            Write-Host ("        {0,-20}: {1}{2}" -f "Servicio", "${GREEN}ACTIVO${NC}", " - $pidStr")
        }
        else {
            Write-Host ("        {0,-20}: {1}" -f "Servicio", "${YELLOW}INACTIVO${NC}")
        }

        # Puerto activo
        $puertoActivo = _http_obtener_puerto_activo $svc.WinSvc
        if ($puertoActivo -gt 0) {
            Write-Host ("        {0,-20}: {1}/tcp" -f "Puerto activo", $puertoActivo)
        }
        else {
            $puertoConf = _http_leer_puerto_config $svc.Interno
            Write-Host ("        {0,-20}: {1}/tcp (servicio inactivo)" -f "Puerto en config", $puertoConf)
        }

        # Comparar con la ultima version disponible en choco
        aputs_info "  Consultando ultima version disponible en Chocolatey..."

        # choco info devuelve la version disponible en el repositorio
        $ultimaDisp = choco info $paquete 2>$null |
        Where-Object { $_ -match "^$paquete\s+[\d]" } |
        ForEach-Object { ($_ -split '\s+')[1] } |
        Select-Object -First 1

        if ($ultimaDisp) {
            $relacion = _http_comparar_versiones `
            ($verInstalada -split '-')[0] `
            ($ultimaDisp -split '-')[0]

            switch ($relacion) {
                "igual" {
                    Write-Host ("        ${GREEN}Al dia${NC} - ultima version: {0}" -f $ultimaDisp)
                }
                "menor" {
                    Write-Host ("        ${YELLOW}Actualizacion disponible${NC}: {0} -> {1}" -f $verInstalada, $ultimaDisp)
                    aputs_info  "  Use Grupo D opcion 2) para actualizar"
                }
                "mayor" {
                    Write-Host ("        ${CYAN}Version mas reciente que el repositorio${NC}: {0}" -f $verInstalada)
                }
            }
        }
        else {
            Write-Host ("        {0,-20}: no disponible (sin conexion)" -f "Version en repo")
        }

        Write-Host ""
    }

    draw_line
}


# Orquestador comun para upgrade y downgrade.
# En Windows: choco upgrade / choco install --version=X
# Flujo:
#   1. Leer version y puerto actuales
#   2. Mostrar versiones disponibles
#   3. Seleccionar version destino
#   4. Backup de configuracion
#   5. Ejecutar choco upgrade/install --version
#   6. Verificar que la version cambio
#   7. Reaplicar el puerto (choco puede resetear la config)
#   8. Reiniciar servicio
#   9. Verificar respuesta HTTP
#  10. Actualizar index.html
#
function _http_ejecutar_cambio_version {
    param(
        [string]   $Servicio,
        [string]   $Operacion,      # "upgrade" o "downgrade"
        [string[]] $VersionesDisp
    )

    if ($VersionesDisp.Count -eq 0) {
        if ($Operacion -eq "upgrade") {
            aputs_info "No hay versiones superiores disponibles en Chocolatey"
            aputs_info "El servicio ya esta en la version mas reciente"
        }
        else {
            aputs_info "No hay versiones anteriores disponibles en Chocolatey"
            aputs_info "Esta es la version mas antigua disponible"
        }
        return
    }

    $paquete = http_nombre_paquete $Servicio

    #  Paso 1: Leer estado actual 
    $verActual = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }
    $puertoActual = _http_leer_puerto_config $Servicio
    if ([string]::IsNullOrEmpty($puertoActual)) {
        $puertoActual = switch ($Servicio) {
            "iis" { "$($Script:HTTP_PUERTO_DEFAULT_IIS)" }
            "apache" { "$($Script:HTTP_PUERTO_DEFAULT_APACHE)" }
            "nginx" { "$($Script:HTTP_PUERTO_DEFAULT_NGINX)" }
            "tomcat" { "$($Script:HTTP_PUERTO_DEFAULT_TOMCAT)" }
        }
    }

    aputs_info "Version actual    : $verActual"
    aputs_info "Puerto preservado : ${puertoActual}/tcp"
    Write-Host ""

    #  Paso 2: Mostrar versiones disponibles ===
    $etiquetaOp = if ($Operacion -eq "upgrade") { "superiores" } else { "anteriores" }
    aputs_info "Versiones ${etiquetaOp} disponibles en Chocolatey:"
    Write-Host ""
    Write-Host ("  {0,-6} {1}" -f "NUM", "VERSION")
    Write-Host "  "

    for ($i = 0; $i -lt $VersionesDisp.Count; $i++) {
        Write-Host ("  {0,-6} {1}" -f "$($i+1))", $VersionesDisp[$i])
    }
    Write-Host ""

    #  Paso 3: Seleccionar version destino ===
    $idxElegido = ""
    do {
        $idxElegido = agets "Seleccione version destino [1-$($VersionesDisp.Count)]"
    } while (-not (http_validar_indice_version $idxElegido $VersionesDisp.Count))

    $versionDestino = $VersionesDisp[[int]$idxElegido - 1]

    Write-Host ""
    aputs_warning "Se realizara $Operacion de ${Servicio}:"
    Write-Host "    Version actual  : $verActual"
    Write-Host "    Version destino : $versionDestino"
    Write-Host "    Puerto          : ${puertoActual}/tcp (se preservara)"
    Write-Host ""

    # Confirmacion
    $confirmado = $false
    do {
        $resp = agets "Confirmar ${Operacion}? [s/n]"
        $rc = http_validar_confirmacion $resp
        if ($rc -eq 0) { $confirmado = $true; break }
        if ($rc -eq 1) {
            aputs_info "${Operacion} cancelado"
            Start-Sleep 1
            return
        }
        Write-Host ""
    } while ($true)

    draw_line
    Write-Host ""

    #  Paso 4: Backup 
    $confFile = http_get_conf_archivo $Servicio
    aputs_info "PASO 1/5 - Backup de configuracion"
    http_crear_backup $confFile
    Write-Host ""

    #  Paso 5: Ejecutar choco upgrade / install --version 
    aputs_info "PASO 2/5 - Ejecutando choco $Operacion a $versionDestino"
    Write-Host ""

    if ($Operacion -eq "upgrade") {
        # choco upgrade actualiza a la ultima por defecto - usamos install con version exacta
        $chocoResult = choco install $paquete --version=$versionDestino --allow-downgrade -y 2>&1
    }
    else {
        # Downgrade en choco tambien usa install --version con --allow-downgrade
        $chocoResult = choco install $paquete --version=$versionDestino --allow-downgrade -y 2>&1
    }

    $chocoResult | ForEach-Object { Write-Host "    $_" }

    if ($LASTEXITCODE -ne 0) {
        aputs_error "Error durante el $Operacion - restaurando configuracion"
        http_restaurar_backup $confFile
        return
    }

    Write-Host ""

    #  Paso 6: Verificar que la version cambio ===
    aputs_info "PASO 3/5 - Verificando version instalada tras $Operacion"
    $verNueva = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    if ($verNueva -eq $verActual) {
        aputs_warning "La version no cambio tras el $Operacion"
        aputs_info    "choco puede haber omitido el cambio si ya estaba satisfecho"
    }
    else {
        aputs_success "Version actualizada: $verActual -> $verNueva"
    }

    Write-Host ""

    #  Paso 7: Reaplicar puerto 
    # choco puede sobrescribir el archivo de configuracion con el del paquete
    # nuevo, reseteando el puerto al valor por defecto. Se reaaplica siempre.
    aputs_info "PASO 4/5 - Reaplying puerto $puertoActual en configuracion"

    switch ($Servicio) {
        "apache" {
            if (Test-Path $Script:HTTP_CONF_APACHE) {
                $apacheContent = (Get-Content $Script:HTTP_CONF_APACHE -Raw) -replace 'Listen\s+\d+', "Listen $puertoActual"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($Script:HTTP_CONF_APACHE, $apacheContent, $utf8NoBom)
            }
        }
        "nginx" {
            if (Test-Path $Script:HTTP_CONF_NGINX) {
                $nginxContent = (Get-Content $Script:HTTP_CONF_NGINX -Raw) -replace 'listen\s+\d+;', "listen $puertoActual;"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $nginxContent, $utf8NoBom)
            }
        }
        "tomcat" {
            if (Test-Path $Script:HTTP_CONF_TOMCAT) {
                [xml]$xml = Get-Content $Script:HTTP_CONF_TOMCAT
                $connector = $null
                foreach ($c in $xml.Server.Service.Connector) {
                    if ($c.protocol -match 'HTTP') { $connector = $c; break }
                }
                if ($connector) {
                    $connector.SetAttribute("port", $puertoActual)
                    $xml.Save($Script:HTTP_CONF_TOMCAT)
                }
            }
        }
        "iis" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            Remove-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue
            New-WebBinding -Name "Default Web Site" -Protocol http `
                -Port ([int]$puertoActual) | Out-Null
        }
    }

    aputs_success "Puerto $puertoActual reaplicado en configuracion"
    Write-Host ""

    #  Paso 8: Reiniciar servicio 
    aputs_info "PASO 5/5 - Reiniciando servicio"
    if (-not (http_reiniciar_servicio $Servicio)) {
        aputs_error "El servicio no levanto tras el $Operacion"
        aputs_warning "Restaurando configuracion anterior..."
        http_restaurar_backup $confFile
        # Intentar volver a la version anterior
        aputs_info "Intentando restaurar version $verActual..."
        choco install $paquete --version=$verActual --allow-downgrade -y 2>$null | Out-Null
        http_reiniciar_servicio $Servicio
        return
    }

    Write-Host ""

    #  Paso 9: Verificar respuesta HTTP 
    aputs_info "Verificando respuesta HTTP en puerto ${puertoActual}..."
    Start-Sleep -Seconds 2

    if (-not (http_verificar_respuesta $Servicio ([int]$puertoActual))) {
        aputs_warning "El servicio no responde - puede necesitar mas tiempo"
        aputs_info    "Verifique manualmente: curl.exe -I http://localhost:${puertoActual}"
    }

    Write-Host ""

    #  Paso 10: Actualizar index.html 
    http_crear_index $Servicio $verNueva ([int]$puertoActual)

    Write-Host ""
    draw_line
    aputs_success "${Operacion} completado: $verActual -> $verNueva"
    Write-Host "    Servicio : $Servicio"
    Write-Host "    Puerto   : ${puertoActual}/tcp (preservado)"
    draw_line
}

function http_upgrade_servicio {
    Clear-Host
    draw_header "Upgrade de Servicio HTTP"

    aputs_info "Actualiza el servicio a una version superior disponible en"
    aputs_info "Chocolatey. Preserva el puerto configurado."
    Write-Host ""

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    if ($servicio -eq "iis") {
        aputs_warning "IIS se actualiza via Windows Update, no via Chocolatey"
        aputs_info    "Use: Install-WindowsUpdate -AcceptAll (modulo PSWindowsUpdate)"
        return
    }

    http_draw_servicio_header $servicio "Upgrade de Version"

    aputs_info "Consultando versiones superiores disponibles en Chocolatey..."
    Write-Host ""

    $paquete = http_nombre_paquete $servicio
    $verActual = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    $versionesUpgrade = _http_versiones_superiores $servicio $verActual
    _http_ejecutar_cambio_version $servicio "upgrade" $versionesUpgrade
}

function http_downgrade_servicio {
    Clear-Host
    draw_header "Downgrade de Servicio HTTP"

    aputs_warning "El downgrade retrocede el servicio a una version anterior."
    aputs_warning "Use esto solo si la version actual presenta problemas."
    Write-Host ""

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    if ($servicio -eq "iis") {
        aputs_warning "IIS no puede hacer downgrade de forma sencilla en Windows"
        aputs_info    "Considere usar un punto de restauracion del sistema"
        return
    }

    http_draw_servicio_header $servicio "Downgrade de Version"

    aputs_info "Consultando versiones anteriores disponibles en Chocolatey..."
    Write-Host ""

    $paquete = http_nombre_paquete $servicio
    $verActual = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    $versionesDowngrade = _http_versiones_inferiores $servicio $verActual
    _http_ejecutar_cambio_version $servicio "downgrade" $versionesDowngrade
}

function http_menu_versiones {
    while ($true) {
        Clear-Host
        draw_header "Gestion de Versiones HTTP"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Ver version instalada y disponibilidad de actualizaciones"
        Write-Host "  ${BLUE}2)${NC} Upgrade   - actualizar a version superior"
        Write-Host "  ${BLUE}3)${NC} Downgrade - retroceder a version anterior"
        Write-Host "  ${BLUE}4)${NC} Volver al menu de configuracion"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" { http_ver_version_instalada; Write-Host ""; pause_menu }
            "2" { http_upgrade_servicio; Write-Host ""; pause_menu }
            "3" { http_downgrade_servicio; Write-Host ""; pause_menu }
            "4" { return }
            default {
                aputs_error "Opcion invalida. Seleccione entre 1 y 4"
                Start-Sleep -Seconds 2
            }
        }
    }
}