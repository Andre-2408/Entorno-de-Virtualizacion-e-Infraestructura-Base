#
# ConfigManager.ps1
# Grupo C - Configuracion y seguridad de servicios HTTP
#
# Equivalente a ConfigManager.sh de la practica Linux.
#
# Funciones publicas:
#   http_cambiar_puerto()         - Cambia el puerto de escucha con rollback
#   http_configurar_seguridad()   - Security headers + ServerTokens
#   http_restringir_metodos()     - Perfiles Recomendado / Estricto / Personalizado
#   http_menu_configurar()        - Submenu del Grupo C (incluye D)
#
# Funciones internas (prefijo _):
#   _http_leer_puerto_config()    - Lee el puerto desde el archivo de config
#   _http_actualizar_firewall_puerto() - Abre el nuevo puerto, cierra el viejo
#   _http_seguridad_iis()         - Headers via web.config (IIS)
#   _http_seguridad_apache()      - security.conf para Apache Windows
#   _http_seguridad_nginx()       - add_header en nginx.conf
#   _http_seguridad_tomcat()      - HttpHeaderSecurityFilter en web.xml
#   _http_metodos_iis()           - requestFiltering en web.config
#   _http_metodos_apache()        - LimitExcept en security.conf
#   _http_metodos_nginx()         - if ($request_method) en nginx.conf
#   _http_metodos_tomcat()        - security-constraint en web.xml
#
# Requiere: CoreHelpers.ps1, HTTPGlobals.ps1, InputGuard.ps1,
#           StatusCheck.ps1, Installer.ps1
#

#Requires -Version 5.1

function _http_leer_puerto_config {
    param([string]$Servicio)

    $confFile = http_get_conf_archivo $Servicio

    switch ($Servicio) {
        "iis" {
            # Leer binding del Default Web Site via WebAdministration
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $binding = Get-WebBinding -Name "Default Web Site" `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($binding) {
                return ($binding.bindingInformation -split ':')[1]
            }
            return "$($Script:HTTP_PUERTO_DEFAULT_IIS)"
        }
        "apache" {
            # Re-detectar si la ruta guardada no existe
            if (-not (Test-Path $confFile)) {
                $candidatos = @(
                    "$env:APPDATA\Apache24\conf\httpd.conf",
                    "$env:APPDATA\Apache2.4\conf\httpd.conf",
                    "C:\Apache24\conf\httpd.conf",
                    "C:\Apache2.4\conf\httpd.conf"
                )
                foreach ($c in $candidatos) {
                    if (Test-Path $c) { $confFile = $c; $Script:HTTP_CONF_APACHE = $c; break }
                }
                if (-not (Test-Path $confFile)) {
                    $found = Get-ChildItem -Path $env:APPDATA -Recurse -Filter httpd.conf `
                        -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) { $confFile = $found.FullName; $Script:HTTP_CONF_APACHE = $confFile }
                }
            }
            if (Test-Path $confFile) {
                $linea = Get-Content $confFile |
                Where-Object { $_ -match '^\s*Listen\s+\d+' } |
                Select-Object -First 1
                if ($linea) { return ($linea -replace '.*Listen\s+', '').Trim() }
            }
            return "$($Script:HTTP_PUERTO_DEFAULT_APACHE)"
        }
        "nginx" {
            # Buscar directiva listen en nginx.conf
            if (Test-Path $confFile) {
                $linea = Get-Content $confFile |
                Where-Object { $_ -match '^\s*listen\s+\d+' } |
                Select-Object -First 1
                if ($linea) { return ($linea -replace '.*listen\s+|;.*', '').Trim() }
            }
            return "$($Script:HTTP_PUERTO_DEFAULT_NGINX)"
        }
        "tomcat" {
            # Leer atributo port del Connector HTTP en server.xml
            if (Test-Path $confFile) {
                [xml]$xml = Get-Content $confFile -ErrorAction SilentlyContinue
                $conn = $xml.Server.Service.Connector |
                Where-Object { $_.protocol -match 'HTTP' } |
                Select-Object -First 1
                if ($conn) { return $conn.port }
            }
            return "$($Script:HTTP_PUERTO_DEFAULT_TOMCAT)"
        }
    }
    return "80"
}

function _http_actualizar_firewall_puerto {
    param([int]$PuertoNuevo, [int]$PuertoViejo)

    aputs_info "Actualizando reglas de Windows Firewall..."

    # Abrir el nuevo puerto
    $nombreNuevo = "HTTP_puerto_$PuertoNuevo"
    $existeNueva = Get-NetFirewallRule -DisplayName $nombreNuevo -ErrorAction SilentlyContinue
    if (-not $existeNueva) {
        New-NetFirewallRule -DisplayName $nombreNuevo `
            -Direction Inbound -Protocol TCP `
            -LocalPort $PuertoNuevo -Action Allow | Out-Null
        aputs_success "Puerto ${PuertoNuevo}/tcp abierto en Firewall"
    }
    else {
        aputs_info "Regla para ${PuertoNuevo}/tcp ya existia"
    }

    # Cerrar el puerto viejo si es diferente al nuevo
    if ($PuertoNuevo -ne $PuertoViejo) {
        $nombreViejo = "HTTP_puerto_$PuertoViejo"
        $existeVieja = Get-NetFirewallRule -DisplayName $nombreViejo `
            -ErrorAction SilentlyContinue
        if ($existeVieja) {
            Remove-NetFirewallRule -DisplayName $nombreViejo -ErrorAction SilentlyContinue
            aputs_success "Puerto ${PuertoViejo}/tcp eliminado del Firewall"
        }
    }
}

function http_cambiar_puerto {
    Clear-Host
    draw_header "Cambiar Puerto de Servicio HTTP"

    # Paso 1: Seleccion del servicio instalado
    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    http_draw_servicio_header $servicio "Cambio de Puerto"

    # Paso 2: Puerto actual
    $puertoActual = _http_leer_puerto_config $servicio
    if ([string]::IsNullOrEmpty($puertoActual)) {
        aputs_warning "No se pudo detectar el puerto actual automaticamente"
        $puertoActual = switch ($servicio) {
            "iis" { "$($Script:HTTP_PUERTO_DEFAULT_IIS)" }
            "apache" { "$($Script:HTTP_PUERTO_DEFAULT_APACHE)" }
            "nginx" { "$($Script:HTTP_PUERTO_DEFAULT_NGINX)" }
            "tomcat" { "$($Script:HTTP_PUERTO_DEFAULT_TOMCAT)" }
        }
        aputs_info "Usando puerto por defecto: ${puertoActual}"
    }
    else {
        aputs_info "Puerto actual configurado: ${puertoActual}/tcp"
    }

    Write-Host ""

    # Paso 3: Nuevo puerto
    $puertoNuevo = ""
    do {
        $puertoNuevo = agets "Nuevo puerto [actual: ${puertoActual}]"
        if ([string]::IsNullOrWhiteSpace($puertoNuevo)) {
            aputs_error "Debe ingresar un numero de puerto"
            $puertoNuevo = ""
            Write-Host ""
        }
        elseif (-not (http_validar_puerto_cambio $puertoNuevo $puertoActual)) {
            $puertoNuevo = ""
            Write-Host ""
        }
    } while ([string]::IsNullOrEmpty($puertoNuevo))

    Write-Host ""
    aputs_warning "Se modificara la configuracion de ${servicio}:"
    Write-Host "    Puerto actual : ${puertoActual}/tcp"
    Write-Host "    Puerto nuevo  : ${puertoNuevo}/tcp"
    Write-Host ""

    # Confirmacion
    $confirmado = $false
    do {
        $resp = agets "Confirmar cambio? [s/n]"
        $rc = http_validar_confirmacion $resp
        if ($rc -eq 0) { $confirmado = $true; break }
        if ($rc -eq 1) { aputs_info "Cambio cancelado"; Start-Sleep 1; return }
        Write-Host ""
    } while ($true)

    draw_line
    Write-Host ""

    # Paso 4: Backup
    $confFile = http_get_conf_archivo $servicio

    # Re-detectar ruta real si la ruta guardada no existe
    if ($servicio -eq "apache" -and -not (Test-Path $confFile)) {
        $candidatos = @(
            "$env:APPDATA\Apache24\conf\httpd.conf",
            "$env:APPDATA\Apache2.4\conf\httpd.conf",
            "C:\Apache24\conf\httpd.conf",
            "C:\Apache2.4\conf\httpd.conf"
        )
        foreach ($c in $candidatos) {
            if (Test-Path $c) { $confFile = $c; $Script:HTTP_CONF_APACHE = $c; break }
        }
        if (-not (Test-Path $confFile)) {
            $found = Get-ChildItem -Path $env:APPDATA -Recurse -Filter httpd.conf `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $confFile = $found.FullName; $Script:HTTP_CONF_APACHE = $confFile }
        }
        if (Test-Path $confFile) { aputs_info "httpd.conf re-detectado: $confFile" }
    }

    aputs_info "PASO 1/5 - Backup de configuracion"
    if (-not (http_crear_backup $confFile)) {
        aputs_error "No se pudo crear backup - operacion cancelada por seguridad"
        return
    }

    Write-Host ""

    # Paso 5: Editar el archivo de configuracion
    aputs_info "PASO 2/5 - Aplicando nuevo puerto en $confFile"

    switch ($servicio) {
        "iis" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            Remove-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue
            New-WebBinding -Name "Default Web Site" -Protocol http `
                -Port ([int]$puertoNuevo) | Out-Null
            aputs_success "Binding IIS actualizado a ${puertoNuevo}/tcp"
        }
        "apache" {
            (Get-Content $confFile) -replace 'Listen\s+\d+', "Listen $puertoNuevo" |
            Set-Content $confFile -Force
            aputs_success "Puerto ${puertoNuevo} configurado en httpd.conf"
        }
        "nginx" {
            (Get-Content $confFile) -replace 'listen\s+\d+;', "listen $puertoNuevo;" |
            Set-Content $confFile -Force
            aputs_success "Puerto ${puertoNuevo} configurado en nginx.conf"
        }
        "tomcat" {
            [xml]$xml = Get-Content $confFile
            $connector = $null
            foreach ($c in $xml.Server.Service.Connector) {
                if ($c.protocol -match 'HTTP') { $connector = $c; break }
            }
            if ($connector) {
                $connector.SetAttribute("port", $puertoNuevo)
                $xml.Save($confFile)
                aputs_success "Puerto ${puertoNuevo} configurado en server.xml"
            }
            else {
                aputs_error "No se encontro el Connector HTTP en server.xml"
                return $false
            }
        }
    }

    Write-Host ""

    # Paso 6: Restart (el socket cambia - reload no es suficiente)
    aputs_info "PASO 3/5 - Reiniciando servicio para aplicar nuevo puerto"
    if (-not (http_reiniciar_servicio $servicio)) {
        aputs_error "El servicio no levanto - restaurando configuracion anterior"
        http_restaurar_backup $confFile
        http_reiniciar_servicio $servicio
        return
    }
    Write-Host ""

    # Paso 7: Verificar respuesta HTTP en el nuevo puerto
    aputs_info "PASO 4/5 - Verificando respuesta HTTP en puerto ${puertoNuevo}"
    Start-Sleep -Seconds 2

    if (-not (http_verificar_respuesta $servicio ([int]$puertoNuevo))) {
        aputs_error "Sin respuesta en puerto ${puertoNuevo} - restaurando"
        http_restaurar_backup $confFile
        http_reiniciar_servicio $servicio
        aputs_info "Configuracion restaurada al puerto ${puertoActual}"
        return
    }
    Write-Host ""

    # Paso 8: Firewall
    aputs_info "PASO 5/5 - Actualizando reglas de Windows Firewall"
    _http_actualizar_firewall_puerto ([int]$puertoNuevo) ([int]$puertoActual)
    Write-Host ""

    # Paso 9: Actualizar index.html
    $verActual = if ($servicio -ne "iis") {
        choco list --local-only (http_nombre_paquete $servicio) 2>$null |
        Where-Object { $_ -match "^$servicio\s" } |
        ForEach-Object { ($_ -split '\s+')[1] }
    }
    else { "sistema" }

    http_crear_index $servicio $verActual ([int]$puertoNuevo)

    Write-Host ""
    draw_line
    aputs_success "Puerto cambiado exitosamente: ${puertoActual} === ${puertoNuevo}"
    draw_line
}

function _http_seguridad_iis {
    aputs_info "Aplicando security headers en IIS via web.config..."
    Write-Host ""

    $webConfig = "$($Script:HTTP_DIR_IIS)\web.config"
    http_crear_backup $webConfig

    # Leer verbos existentes del web.config actual para preservarlos
    $verbsXml = ""
    if (Test-Path $webConfig) {
        try {
            [xml]$xmlExistente = Get-Content $webConfig -ErrorAction SilentlyContinue
            $verbs = $xmlExistente.SelectNodes("//verbs/add")
            if ($verbs -and $verbs.Count -gt 0) {
                $verbsXml = ($verbs | ForEach-Object {
                    "          <add verb=`"$($_.verb)`" allowed=`"$($_.allowed)`" />"
                }) -join "`n"
            }
        } catch {}
    }

    # Si no habia verbos previos, usar perfil recomendado por defecto
    if ([string]::IsNullOrWhiteSpace($verbsXml)) {
        $verbsXml = @"
          <add verb="GET"  allowed="true" />
          <add verb="POST" allowed="true" />
          <add verb="HEAD" allowed="true" />
"@
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <security>
      <requestFiltering removeServerHeader="true">
        <!-- allowUnlisted="false" bloquea todos los metodos no listados explicitamente -->
        <verbs allowUnlisted="false">
$verbsXml
        </verbs>
      </requestFiltering>
    </security>
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        <add name="X-Frame-Options"        value="SAMEORIGIN" />
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="Referrer-Policy"        value="strict-origin-when-cross-origin" />
        <add name="X-XSS-Protection"       value="1; mode=block" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
"@

    try {
        if (-not (Test-Path $Script:HTTP_DIR_IIS -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:HTTP_DIR_IIS -Force | Out-Null
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($webConfig, $xml, $utf8NoBom)
        aputs_success "web.config escrito en $webConfig"
        Write-Host "    removeServerHeader        -> true"
        Write-Host "    X-Frame-Options           -> SAMEORIGIN"
        Write-Host "    X-Content-Type-Options    -> nosniff"
        Write-Host "    Referrer-Policy           -> strict-origin-when-cross-origin"
        Write-Host "    X-XSS-Protection          -> 1; mode=block"
        if (-not [string]::IsNullOrWhiteSpace($verbsXml)) {
            aputs_info "requestFiltering (verbos existentes preservados)"
        }
        return $true
    }
    catch {
        aputs_error "No se pudo escribir web.config: $($_.Exception.Message)"
        return $false
    }
}

function _http_seguridad_apache {
    aputs_info "Aplicando security headers en Apache (httpd)..."
    Write-Host ""

    $apacheConfDir = Split-Path $Script:HTTP_CONF_APACHE
    $extraDir      = Join-Path $apacheConfDir "extra"
    $securityConf  = Join-Path $extraDir "security.conf"
    if (-not (Test-Path $extraDir)) {
        New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
    }
    if (Test-Path $securityConf) { http_crear_backup $securityConf }

    # Leer contenido existente (puede tener bloque Directory de _http_metodos_apache)
    # y preservarlo - solo reemplazamos la seccion de headers/tokens
    $existente = if (Test-Path $securityConf) {
        $bytes = [System.IO.File]::ReadAllBytes($securityConf)
        $enc   = New-Object System.Text.UTF8Encoding $false
        $off   = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF `
                     -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        $enc.GetString($bytes, $off, $bytes.Length - $off)
    } else { "" }

    # Extraer el bloque <Directory> existente para preservarlo
    $bloqueDirectory = ""
    if ($existente -match '(?s)(\r?\n#[^\r\n]*Control de metodos[^\r\n]*\r?\n.*?</Directory>\s*)') {
        $bloqueDirectory = $Matches[1]
    } elseif ($existente -match '(?s)(<Directory[^>]*>.*?</Directory>\s*)') {
        $bloqueDirectory = "`n" + $Matches[1]
    }

    # Cabecera + tokens + headers (seccion que esta funcion controla)
    $seccionHeaders = @"
# security.conf - Generado por ConfigManager.ps1
# Apache HTTP Server - Windows Server 2022

# Ocultar version del servidor en headers HTTP
ServerTokens Prod
ServerSignature Off

# Deshabilitar TRACE - previene Cross-Site Tracing (XST)
# TraceEnable es la UNICA solucion - LimitExcept no intercepta TRACE en Apache
TraceEnable Off

# Activar mod_headers si no esta cargado
<IfModule !mod_headers.c>
    LoadModule headers_module modules/mod_headers.so
</IfModule>

# Security Headers - aplicados a todas las respuestas HTTP
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>
"@

    # Reconstruir: seccion headers + bloque Directory preservado (si existia)
    $nuevoContenido = $seccionHeaders + $bloqueDirectory

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($securityConf, $nuevoContenido, $utf8NoBom)

        # Incluir security.conf desde httpd.conf si aun no esta incluido
        $httpdConf = $Script:HTTP_CONF_APACHE
        if (Test-Path $httpdConf) {
            $contenidoHttpd = Get-Content $httpdConf -Raw
            if ($contenidoHttpd -notmatch 'security\.conf') {
                [System.IO.File]::AppendAllText($httpdConf, "`nInclude `"$securityConf`"`n", $utf8NoBom)
                aputs_info "Include security.conf agregado a httpd.conf"
            }
        }

        aputs_success "security.conf escrito en $securityConf"
        Write-Host "    ServerTokens              -> Prod"
        Write-Host "    ServerSignature           -> Off"
        Write-Host "    TraceEnable               -> Off"
        Write-Host "    X-Frame-Options           -> SAMEORIGIN"
        Write-Host "    X-Content-Type-Options    -> nosniff"
        Write-Host "    Referrer-Policy           -> strict-origin-when-cross-origin"
        Write-Host "    X-XSS-Protection          -> 1; mode=block"
        if ($bloqueDirectory) { aputs_info "Bloque Directory/LimitExcept preservado" }
        return $true
    }
    catch {
        aputs_error "No se pudo escribir security.conf: $($_.Exception.Message)"
        return $false
    }
}

function _http_seguridad_nginx {
    aputs_info "Aplicando security headers en Nginx..."
    Write-Host ""

    $confFile = $Script:HTTP_CONF_NGINX
    http_crear_backup $confFile

    if (-not (Test-Path $confFile)) {
        aputs_error "nginx.conf no encontrado: $confFile"
        return $false
    }

    # Leer eliminando BOM si existe (Get-Content en PS5.1 puede preservarlo)
    $bytes = [System.IO.File]::ReadAllBytes($confFile)
    if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $contenido = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        $contenido = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    # server_tokens off va en el bloque http {} - correcto
    if ($contenido -match 'server_tokens') {
        $contenido = $contenido -replace 'server_tokens\s+\w+;', 'server_tokens off;'
        aputs_success "server_tokens off: actualizado"
    }
    else {
        $contenido = $contenido -replace '(http\s*\{)', "`$1`n    server_tokens off;"
        aputs_success "server_tokens off: agregado"
    }

    # add_header debe ir dentro del bloque server {}, no en http {}
    # Insertamos antes del primer location / dentro de server {}
    $headers = [ordered]@{
        "X-Frame-Options"        = "SAMEORIGIN"
        "X-Content-Type-Options" = "nosniff"
        "Referrer-Policy"        = "strict-origin-when-cross-origin"
        "X-XSS-Protection"       = "1; mode=block"
    }

    # Eliminar add_header anteriores que pudimos haber insertado mal
    $contenido = $contenido -replace '(?m)^\s*add_header\s+X-Frame-Options[^\n]*\n', ''
    $contenido = $contenido -replace '(?m)^\s*add_header\s+X-Content-Type-Options[^\n]*\n', ''
    $contenido = $contenido -replace '(?m)^\s*add_header\s+Referrer-Policy[^\n]*\n', ''
    $contenido = $contenido -replace '(?m)^\s*add_header\s+X-XSS-Protection[^\n]*\n', ''

    # Construir bloque de headers
    $headersBloque = ""
    foreach ($h in $headers.Keys) {
        $headersBloque += "        add_header $h `"$($headers[$h])`" always;`r`n"
    }
    $headersBloque += "`r`n"

    # Insertar dentro de server {}, justo antes del primer location
    $contenido = $contenido -replace '(\r?\n        location\s+/\s*\{)', "`n$headersBloque`$1"

    foreach ($h in $headers.Keys) {
        aputs_success "${h}: agregado"
    }

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($confFile, $contenido, $utf8NoBom)
    }
    catch {
        aputs_error "Error al escribir nginx.conf: $($_.Exception.Message)"
        return $false
    }

    # Verificar sintaxis fuera del try - para que return $false salga de la funcion
    $nginxExe = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nginxExe) {
        $nginxDir = Split-Path $nginxExe.FullName
        $test = & cmd /c "cd /d `"$nginxDir`" && `"$($nginxExe.FullName)`" -t 2>&1"
        if ($LASTEXITCODE -eq 0) {
            aputs_success "Sintaxis de nginx.conf valida"
        }
        else {
            aputs_error "Error de sintaxis detectado:"
            $test | ForEach-Object { Write-Host "    $_" }
            aputs_error "Restaurando backup"
            http_restaurar_backup $confFile
            return $false
        }
    }
    else {
        aputs_warning "nginx.exe no encontrado - sintaxis no verificada"
    }
    return $true
}

function _http_seguridad_tomcat {
    aputs_info "Aplicando security headers en Tomcat..."
    Write-Host ""

    $webXml = $null
    $candidatos = @(
        "C:\ProgramData\Tomcat9\conf\web.xml",
        "C:\ProgramData\Tomcat10\conf\web.xml",
        "C:\tools\tomcat\conf\web.xml"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { $webXml = $c; break }
    }
    if (-not $webXml) {
        $found = Get-ChildItem "C:\ProgramData" -Recurse -Filter web.xml `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'conf' } | Select-Object -First 1
        if ($found) { $webXml = $found.FullName }
    }
    if (-not $webXml) {
        aputs_error "web.xml no encontrado en rutas conocidas de Tomcat"
        return $false
    }
    aputs_info "web.xml localizado: $webXml"

    http_crear_backup $webXml

    try {
        [xml]$xml = Get-Content $webXml

        # Eliminar filtro anterior si existe para evitar duplicados
        $filtroAnterior = $xml.SelectNodes("//filter[filter-name='httpHeaderSecurity']")
        foreach ($n in $filtroAnterior) { $n.ParentNode.RemoveChild($n) | Out-Null }
        $mappingAnterior = $xml.SelectNodes("//filter-mapping[filter-name='httpHeaderSecurity']")
        foreach ($n in $mappingAnterior) { $n.ParentNode.RemoveChild($n) | Out-Null }

        # Crear nodo <filter> con HttpHeaderSecurityFilter
        $filterNode = $xml.CreateElement("filter")
        $filterNode.InnerXml = @"
<filter-name>httpHeaderSecurity</filter-name>
<filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>
<init-param><param-name>antiClickJackingEnabled</param-name><param-value>true</param-value></init-param>
<init-param><param-name>antiClickJackingOption</param-name><param-value>SAMEORIGIN</param-value></init-param>
<init-param><param-name>blockContentTypeSniffingEnabled</param-name><param-value>true</param-value></init-param>
<init-param><param-name>xssProtectionEnabled</param-name><param-value>true</param-value></init-param>
"@

        # Crear nodo <filter-mapping>
        $mappingNode = $xml.CreateElement("filter-mapping")
        $mappingNode.InnerXml = @"
<filter-name>httpHeaderSecurity</filter-name>
<url-pattern>/*</url-pattern>
<dispatcher>REQUEST</dispatcher>
"@

        $xml.DocumentElement.AppendChild($filterNode) | Out-Null
        $xml.DocumentElement.AppendChild($mappingNode) | Out-Null
        $xml.Save($webXml)

        aputs_success "HttpHeaderSecurityFilter configurado en web.xml"
        Write-Host "    X-Frame-Options           -> SAMEORIGIN"
        Write-Host "    X-Content-Type-Options    -> nosniff"
        Write-Host "    X-XSS-Protection          -> activado"
        return $true
    }
    catch {
        aputs_error "Error al modificar web.xml: $($_.Exception.Message)"
        http_restaurar_backup $webXml
        return $false
    }
}

function http_configurar_seguridad {
    Clear-Host
    draw_header "Configurar Security Headers"

    aputs_info "Protege contra: Clickjacking, MIME sniffing, XSS, info leakage"
    Write-Host ""

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    http_draw_servicio_header $servicio "Security Headers"

    $ok = $false
    switch ($servicio) {
        "iis" { $ok = _http_seguridad_iis }
        "apache" { $ok = _http_seguridad_apache }
        "nginx" { $ok = _http_seguridad_nginx }
        "tomcat" { $ok = _http_seguridad_tomcat }
    }

    if ($ok -ne $true) {
        aputs_error "No se aplicaron los security headers - operacion cancelada"
        return
    }

    Write-Host ""
    aputs_info "Recargando servicio..."

    if (-not (http_recargar_servicio $servicio)) {
        aputs_error "El servicio no levanto con la nueva configuracion"
        aputs_info  "Restaurando configuracion anterior..."
        $confFile = http_get_conf_archivo $servicio
        http_restaurar_backup $confFile
        aputs_info "Reiniciando con configuracion anterior..."
        http_reiniciar_servicio $servicio
        return
    }

    Write-Host ""

    # Verificar headers reales con curl.exe
    $puerto = _http_leer_puerto_config $servicio
    if ($puerto) {
        aputs_info "Headers presentes en respuesta HTTP real:"
        Write-Host ""
        $headers = curl.exe -sI --max-time 5 "http://localhost:${puerto}" 2>$null
        $headers | Where-Object { $_ -match 'Server:|X-Frame|X-Content|X-XSS|Referrer' } |
        ForEach-Object { Write-Host "    $_" }
    }

    Write-Host ""
    draw_line
    aputs_success "Security headers configurados correctamente"
}

function _http_metodos_iis {
    param(
        [string[]]$MetodosPermitidos
    )

    aputs_info "Configurando metodos HTTP en IIS via requestFiltering..."
    Write-Host ""

    $webConfig = "$($Script:HTTP_DIR_IIS)\web.config"
    http_crear_backup $webConfig

    # Leer customHeaders existentes para preservarlos
    $headersXml = ""
    if (Test-Path $webConfig) {
        try {
            [xml]$xmlExistente = Get-Content $webConfig -ErrorAction SilentlyContinue
            $headers = $xmlExistente.SelectNodes("//customHeaders/*")
            if ($headers -and $headers.Count -gt 0) {
                $headersXml = ($headers | ForEach-Object {
                    if ($_.LocalName -eq "remove") {
                        "        <remove name=`"$($_.name)`" />"
                    } else {
                        "        <add name=`"$($_.name)`" value=`"$($_.value)`" />"
                    }
                }) -join "`n"
            }
        } catch {}
    }

    # Si no habia headers previos, aplicar set completo por defecto
    if ([string]::IsNullOrWhiteSpace($headersXml)) {
        $headersXml = @"
        <remove name="X-Powered-By" />
        <add name="X-Frame-Options"        value="SAMEORIGIN" />
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="Referrer-Policy"        value="strict-origin-when-cross-origin" />
        <add name="X-XSS-Protection"       value="1; mode=block" />
"@
    }

    # Leer removeServerHeader existente
    $removeServerHeader = "true"
    if (Test-Path $webConfig) {
        try {
            [xml]$xmlExistente = Get-Content $webConfig -ErrorAction SilentlyContinue
            $rf = $xmlExistente.SelectSingleNode("//requestFiltering")
            if ($rf -and $rf.removeServerHeader -eq "false") { $removeServerHeader = "false" }
        } catch {}
    }

    # Construir verbos
    $verbsXml = ($MetodosPermitidos | ForEach-Object {
        "          <add verb=`"$_`" allowed=`"true`" />"
    }) -join "`n"

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <security>
      <requestFiltering removeServerHeader="$removeServerHeader">
        <!-- allowUnlisted="false" bloquea todos los metodos no listados explicitamente -->
        <verbs allowUnlisted="false">
$verbsXml
        </verbs>
      </requestFiltering>
    </security>
    <httpProtocol>
      <customHeaders>
$headersXml
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
"@

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($webConfig, $xml, $utf8NoBom)
        aputs_success "Metodos permitidos en IIS: $($MetodosPermitidos -join ', ')"
        if (-not [string]::IsNullOrWhiteSpace($headersXml)) {
            aputs_info "customHeaders existentes preservados"
        }
        return $true
    }
    catch {
        aputs_error "Error al escribir web.config: $($_.Exception.Message)"
        return $false
    }
}

function _http_metodos_apache {
    param([string]$MetodosPermitidos)

    aputs_info "Configurando metodos HTTP en Apache (security.conf)..."
    Write-Host ""

    $apacheConfDir = Split-Path $Script:HTTP_CONF_APACHE
    $extraDir      = Join-Path $apacheConfDir "extra"
    $securityConf  = Join-Path $extraDir "security.conf"
    if (-not (Test-Path $extraDir)) {
        New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
    }
    if (Test-Path $securityConf) { http_crear_backup $securityConf }

    # Detectar el webroot real de Apache (puede diferir de la constante)
    $webrootApache = $Script:HTTP_DIR_APACHE
    $htdocsReal = Join-Path (Split-Path $Script:HTTP_CONF_APACHE -Parent | Split-Path -Parent) "htdocs"
    if (Test-Path $htdocsReal) { $webrootApache = $htdocsReal }

    # Leer contenido existente y preservar la seccion de headers/tokens
    $existente = if (Test-Path $securityConf) {
        $bytes = [System.IO.File]::ReadAllBytes($securityConf)
        $enc   = New-Object System.Text.UTF8Encoding $false
        $off   = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF `
                     -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        $enc.GetString($bytes, $off, $bytes.Length - $off)
    } else { "" }

    # Extraer seccion de headers (todo lo que NO es el bloque Directory)
    $seccionHeaders = ($existente -replace '(?s)\r?\n#[^\r\n]*Control de metodos[^\r\n]*\r?\n.*?</Directory>\s*', '') `
                                  -replace '(?s)<Directory[^>]*>.*?</Directory>\s*', ''
    $seccionHeaders = $seccionHeaders.TrimEnd()

    # Si no hay seccion de headers todavia, crear una base minima
    if ([string]::IsNullOrWhiteSpace($seccionHeaders)) {
        $seccionHeaders = @"
# security.conf - Generado por ConfigManager.ps1
# Apache HTTP Server - Windows Server 2022

ServerTokens Prod
ServerSignature Off
TraceEnable Off

<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>
"@
    }

    # Nuevo bloque Directory con la ruta correcta
    $bloqueNuevo = @"

# Control de metodos HTTP
# LimitExcept: permite los metodos listados, deniega el resto
<Directory "$webrootApache">
    <LimitExcept $MetodosPermitidos>
        Require all denied
    </LimitExcept>
</Directory>
"@

    try {
        $nuevoContenido = $seccionHeaders + "`n" + $bloqueNuevo
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($securityConf, $nuevoContenido, $utf8NoBom)

        # Incluir security.conf desde httpd.conf si aun no esta incluido
        $httpdConf = $Script:HTTP_CONF_APACHE
        if (Test-Path $httpdConf) {
            $contenidoHttpd = Get-Content $httpdConf -Raw
            if ($contenidoHttpd -notmatch 'security\.conf') {
                [System.IO.File]::AppendAllText($httpdConf, "`nInclude `"$securityConf`"`n", $utf8NoBom)
                aputs_info "Include security.conf agregado a httpd.conf"
            }
        }

        aputs_success "Metodos permitidos en Apache: $MetodosPermitidos"
        aputs_info    "Webroot usado: $webrootApache"
        return $true
    }
    catch {
        aputs_error "Error al escribir security.conf: $($_.Exception.Message)"
        return $false
    }
}

function _http_metodos_nginx {
    param([string]$MetodosRegex)  # Formato: "TRACE|TRACK|DELETE"

    aputs_info "Configurando metodos HTTP en Nginx (nginx.conf)..."
    Write-Host ""

    $confFile = $Script:HTTP_CONF_NGINX
    http_crear_backup $confFile

    $bytes = [System.IO.File]::ReadAllBytes($confFile)
    if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $contenido = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        $contenido = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    # Eliminar bloque anterior si existe
    $contenido = $contenido -replace '(?s)# Control de metodos HTTP.*?\}\s*', ''

    # Insertar bloque antes del primer location /
    $bloqueMetodos = @"
        # Control de metodos HTTP
        # if ($request_method) devuelve 405 para los metodos bloqueados
        if (`$request_method ~ ^($MetodosRegex)`$) {
            return 405;
        }
"@

    $contenido = $contenido -replace '(\r?\n        location\s+/\s*\{)', "`n$bloqueMetodos`$1"

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($confFile, $contenido, $utf8NoBom)

        # Verificar sintaxis con ruta dinamica y desde el directorio de nginx
        $nginxExe = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxExe) {
            $nginxDir = Split-Path $nginxExe.FullName
            & cmd /c "cd /d `"$nginxDir`" && `"$($nginxExe.FullName)`" -t 2>&1" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                aputs_error "Error de sintaxis - restaurando nginx.conf"
                http_restaurar_backup $confFile
                return $false
            }
        }

        aputs_success "Metodos bloqueados en Nginx: $($MetodosRegex -replace '\|', ', ')"
        return $true
    }
    catch {
        aputs_error "Error al escribir nginx.conf: $($_.Exception.Message)"
        return $false
    }
}

function _http_metodos_tomcat {
    param([string[]]$MetodosBloqueados)

    aputs_info "Configurando metodos HTTP en Tomcat (web.xml)..."
    Write-Host ""

    $webXml = $null
    $candidatos = @(
        "C:\ProgramData\Tomcat9\conf\web.xml",
        "C:\ProgramData\Tomcat10\conf\web.xml",
        "C:\tools\tomcat\conf\web.xml"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { $webXml = $c; break }
    }
    if (-not $webXml) {
        $found = Get-ChildItem "C:\ProgramData" -Recurse -Filter web.xml `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'conf' } | Select-Object -First 1
        if ($found) { $webXml = $found.FullName }
    }
    if (-not $webXml) {
        aputs_error "web.xml no encontrado en rutas conocidas de Tomcat"
        return $false
    }
    aputs_info "web.xml localizado: $webXml"

    http_crear_backup $webXml

    try {
        [xml]$xml = Get-Content $webXml

        # Eliminar constraint anterior
        $prevConstraint = $xml.SelectNodes("//security-constraint[web-resource-collection/web-resource-name='Metodos Restringidos']")
        foreach ($n in $prevConstraint) { $n.ParentNode.RemoveChild($n) | Out-Null }

        # Construir nodo <security-constraint>
        $sc = $xml.CreateElement("security-constraint")
        $wrc = $xml.CreateElement("web-resource-collection")

        $wrn = $xml.CreateElement("web-resource-name")
        $wrn.InnerText = "Metodos Restringidos"
        $wrc.AppendChild($wrn) | Out-Null

        $up = $xml.CreateElement("url-pattern")
        $up.InnerText = "/*"
        $wrc.AppendChild($up) | Out-Null

        # http-method-omission: bloquea estos metodos aunque no haya auth
        foreach ($m in $MetodosBloqueados) {
            $hmo = $xml.CreateElement("http-method-omission")
            $hmo.InnerText = $m.ToUpper()
            $wrc.AppendChild($hmo) | Out-Null
        }

        $sc.AppendChild($wrc) | Out-Null
        #$ac = $xml.CreateElement("auth-constraint")
        #$sc.AppendChild($ac) | Out-Null

        $xml.DocumentElement.AppendChild($sc) | Out-Null
        $xml.Save($webXml)

        aputs_success "Metodos bloqueados en Tomcat: $($MetodosBloqueados -join ', ')"
        return $true
    }
    catch {
        aputs_error "Error al modificar web.xml: $($_.Exception.Message)"
        http_restaurar_backup $webXml
        return $false
    }
}

function http_restringir_metodos {
    Clear-Host
    draw_header "Control de Metodos HTTP"

    aputs_info "Metodos peligrosos a restringir:"
    Write-Host "    TRACE  - Refleja la peticion (facilita XST / Cross-Site Tracing)"
    Write-Host "    TRACK  - Variante de TRACE en IIS"
    Write-Host "    DELETE - Puede eliminar recursos del servidor"
    Write-Host "    PUT    - Puede subir archivos arbitrarios"
    Write-Host ""

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    http_draw_servicio_header $servicio "Control de Metodos HTTP"

    aputs_info "Perfiles de restriccion:"
    Write-Host ""
    Write-Host "  ${BLUE}1)${NC} Recomendado  - Bloquea: TRACE, TRACK"
    Write-Host "  ${BLUE}2)${NC} Estricto     - Bloquea: TRACE, TRACK, DELETE, PUT, PATCH"
    Write-Host "  ${BLUE}3)${NC} Personalizado - Ingresar manualmente"
    Write-Host ""

    $perfil = ""
    do {
        $perfil = agets "Seleccione perfil [1-3]"
    } while (-not (http_validar_opcion_menu $perfil 3))

    Write-Host ""

    # Resolver metodos segun perfil
    $metodosBloqueados = @()
    $metodosPermitidos = @()

    switch ($perfil) {
        "1" {
            $metodosBloqueados = @("TRACE", "TRACK")
            $metodosPermitidos = @("GET", "POST", "HEAD", "OPTIONS", "PUT", "DELETE")
        }
        "2" {
            $metodosBloqueados = @("TRACE", "TRACK", "DELETE", "PUT", "PATCH")
            $metodosPermitidos = @("GET", "POST", "HEAD")
        }
        "3" {
            aputs_info "Metodos disponibles: TRACE TRACK DELETE PUT PATCH OPTIONS CONNECT"
            aputs_info "Ingrese los metodos a BLOQUEAR separados por espacios (MAYUSCULAS)"
            Write-Host ""
            $entradaMetodos = agets "Metodos a bloquear"

            if ([string]::IsNullOrWhiteSpace($entradaMetodos)) {
                aputs_error "Debe ingresar al menos un metodo"
                return
            }

            $metodosValidos = @()
            foreach ($m in ($entradaMetodos -split '\s+')) {
                if (http_validar_metodo_http $m) {
                    $metodosValidos += $m.ToUpper()
                }
                else {
                    aputs_warning "Metodo ignorado: $m"
                }
            }

            if ($metodosValidos.Count -eq 0) {
                aputs_error "Ningun metodo valido ingresado"
                return
            }

            $metodosBloqueados = $metodosValidos
            $metodosPermitidos = @("GET", "POST", "HEAD")
        }
    }

    draw_line
    aputs_info "Configuracion a aplicar:"
    Write-Host "    Servicio          : $servicio"
    Write-Host "    Metodos bloqueados: $($metodosBloqueados -join ', ')"
    Write-Host "    Metodos permitidos: $($metodosPermitidos -join ', ')"
    Write-Host ""

    # Confirmacion
    $confirmado = $false
    do {
        $resp = agets "Confirmar? [s/n]"
        $rc = http_validar_confirmacion $resp
        if ($rc -eq 0) { $confirmado = $true; break }
        if ($rc -eq 1) { aputs_info "Operacion cancelada"; Start-Sleep 1; return }
        Write-Host ""
    } while ($true)

    Write-Host ""

    $ok = $false
    switch ($servicio) {
        "iis" { $ok = _http_metodos_iis    $metodosPermitidos }
        "apache" { $ok = _http_metodos_apache ($metodosPermitidos -join ' ') }
        "nginx" { $ok = _http_metodos_nginx  ($metodosBloqueados -join '|') }
        "tomcat" { $ok = _http_metodos_tomcat $metodosBloqueados }
    }

    if ($ok -ne $true) { return }

    Write-Host ""
    aputs_info "Recargando servicio..."
    http_recargar_servicio $servicio

    Write-Host ""
    draw_line
    aputs_success "Control de metodos HTTP aplicado correctamente"
}

function http_menu_configurar {
    while ($true) {
        Clear-Host
        draw_header "Configurar Servicio HTTP"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Cambiar puerto de escucha"
        Write-Host "  ${BLUE}2)${NC} Configurar security headers"
        Write-Host "  ${BLUE}3)${NC} Control de metodos HTTP"
        Write-Host "  ${BLUE}4)${NC} Gestion de versiones (upgrade / downgrade)"
        Write-Host "  ${BLUE}5)${NC} Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" { http_cambiar_puerto; Write-Host ""; pause_menu }
            "2" { http_configurar_seguridad; Write-Host ""; pause_menu }
            "3" { http_restringir_metodos; Write-Host ""; pause_menu }
            "4" { http_menu_versiones }
            "5" { return }
            default {
                aputs_error "Opcion invalida. Seleccione entre 1 y 5"
                Start-Sleep -Seconds 2
            }
        }
    }
}