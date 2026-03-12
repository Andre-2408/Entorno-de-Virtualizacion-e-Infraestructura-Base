#
# Monitor.ps1
# Grupo E - Monitoreo de servicios HTTP
#
# Equivalente a Monitor.sh de la practica Linux.
# En Windows: Get-Service / Get-Process / Get-EventLog / Get-NetTCPConnection /
#             New-NetFirewallRule / curl.exe en lugar de systemctl / ss / journalctl
#
# Funciones publicas:
#   http_monitoreo_estado()   - PID, memoria, CPU, uptime de los 4 servicios
#   http_monitoreo_puertos()  - Puertos en escucha + estado en Windows Firewall
#   http_monitoreo_logs()     - Event Log del servicio + resumen de errores
#   http_monitoreo_headers()  - curl.exe -I + auditoria de security headers
#   http_monitoreo_config()   - Configuracion activa, webroot, usuario
#   http_menu_monitoreo()     - Submenu interactivo del Grupo E
#
# Funciones internas (prefijo _):
#   _http_mon_estado_servicio()           - Detalle de un servicio especifico
#   _http_mon_firewall_puerto()           - Estado de un puerto en Windows Firewall
#   _http_mon_verificar_headers_seguridad() - Auditoria de security headers
#
# Requiere: CoreHelpers.ps1, HTTPGlobals.ps1, InputGuard.ps1,
#           StatusCheck.ps1 hasta VersionControl.ps1
#

#Requires -Version 5.1

function _http_mon_estado_servicio {
    param([hashtable]$Svc)

    Write-Host "  ${CYAN} $($Svc.Nombre)${NC}"
    Write-Host "  ============================================================================================================================================================"

    # Version instalada
    $version = if ($Svc.Interno -eq "iis") {
        (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
            -ErrorAction SilentlyContinue).VersionString
    }
    else {
        $paquete = http_nombre_paquete $Svc.Interno
        $info = choco list --local $paquete 2>$null |
        Where-Object { $_ -match "^$paquete\s" }
        if ($info) {
            ($info -split '\s+')[1]
        }
        else {
            # Fallback: si el servicio Windows existe, esta instalado aunque choco no lo reporte
            $svcObj = Get-Service -Name $Svc.WinSvc -ErrorAction SilentlyContinue
            if ($svcObj) { "instalado" } else { $null }
        }
    }

    if (-not $version) {
        Write-Host ("  ${GRAY}[--]${NC}  No instalado")
        Write-Host ""
        return
    }

    Write-Host ("  ${GREEN}[OK]${NC}  {0,-14}: {1}" -f "Version", $version)

    # Estado del servicio Windows
    $winSvc = Get-Service -Name $Svc.WinSvc -ErrorAction SilentlyContinue
    if ($null -ne $winSvc -and $winSvc.Status -eq 'Running') {
        # PID via WMI
        $wmiSvc = Get-CimInstance Win32_Service `
            -Filter "Name='$($Svc.WinSvc)'" -ErrorAction SilentlyContinue
        $pid_ = if ($wmiSvc) { $wmiSvc.ProcessId } else { "?" }

        Write-Host ("  ${GREEN}[OK]${NC}  {0,-14}: ${GREEN}ACTIVO${NC} - PID: {1}" -f "Estado", $pid_)

        # Tiempo activo (fecha de inicio del proceso)
        $proc = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
        if ($proc) {
            $uptime = (Get-Date) - $proc.StartTime
            $uptimeStr = "{0}d {1}h {2}m" -f `
                [math]::Floor($uptime.TotalDays), $uptime.Hours, $uptime.Minutes
            Write-Host ("        {0,-14}: {1}" -f "Activo desde", $proc.StartTime.ToString("yyyy-MM-dd HH:mm"))
            Write-Host ("        {0,-14}: {1}" -f "Uptime", $uptimeStr)

            # Memoria en MB
            $memMB = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            Write-Host ("        {0,-14}: {1} MB" -f "Memoria", $memMB)

            # CPU % via Get-Counter (snapshot breve)
            $cpuCounter = "\Process($($proc.ProcessName))\% Processor Time"
            try {
                $cpu = (Get-Counter $cpuCounter -SampleInterval 1 -MaxSamples 1 `
                        -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
                Write-Host ("        {0,-14}: {1:N1}%%" -f "CPU", $cpu)
            }
            catch { }
        }
    }
    else {
        $estado = if ($winSvc) { $winSvc.Status } else { "no encontrado" }
        Write-Host ("  ${RED}[!!]${NC}  {0,-14}: ${RED}INACTIVO${NC} ({1})" -f "Estado", $estado)

        # Ultimo evento del Event Log para dar pista del error
        $ultimoEvento = Get-EventLog -LogName System `
            -Source "*$($Svc.Interno)*" -Newest 1 `
            -ErrorAction SilentlyContinue
        if ($ultimoEvento) {
            $msg = $ultimoEvento.Message -replace '\s+', ' '
            Write-Host ("        {0,-14}: {1}" -f "Ultimo evento", $msg.Substring(0, [Math]::Min(70, $msg.Length)) + "...")
        }
    }

    # Inicio automatico
    if ($null -ne $winSvc) {
        if ($winSvc.StartType -eq 'Automatic') {
            Write-Host ("        {0,-14}: ${GREEN}habilitado${NC}" -f "Boot")
        }
        else {
            Write-Host ("        {0,-14}: ${YELLOW}$($winSvc.StartType)${NC}" -f "Boot")
        }
    }

    # Puerto en escucha
    $puertoActivo = _http_obtener_puerto_activo $Svc.WinSvc
    if ($puertoActivo -gt 0) {
        Write-Host ("  ${GREEN}[OK]${NC}  {0,-14}: {1}/tcp en escucha" -f "Puerto", $puertoActivo)
    }
    else {
        $puertoConf = _http_leer_puerto_config $Svc.Interno
        Write-Host ("  ${YELLOW}[--]${NC}  {0,-14}: sin escucha (config: {1}/tcp)" -f "Puerto", $puertoConf)
    }

    Write-Host ""
}

function http_monitoreo_estado {
    Clear-Host
    draw_header "Estado de Servicios HTTP"

    Write-Host ""
    Write-Host ("  {0,-20} {1}" -f "Hora del informe:", (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    Write-Host ("  {0,-20} {1} ({2})" -f "Servidor:", $env:COMPUTERNAME, `
        (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } |
            Select-Object -First 1 -ExpandProperty IPAddress))
    Write-Host ""
    draw_line
    Write-Host ""

    $servicios = @(
        @{ Nombre = "IIS"; Interno = "iis"; WinSvc = $Script:HTTP_WINSVC_IIS }
        @{ Nombre = "Apache (httpd)"; Interno = "apache"; WinSvc = $Script:HTTP_WINSVC_APACHE }
        @{ Nombre = "Nginx"; Interno = "nginx"; WinSvc = $Script:HTTP_WINSVC_NGINX }
        @{ Nombre = "Tomcat"; Interno = "tomcat"; WinSvc = $Script:HTTP_WINSVC_TOMCAT }
    )

    foreach ($svc in $servicios) {
        _http_mon_estado_servicio $svc
    }

    draw_line

    # Resumen del sistema
    Write-Host ""
    aputs_info "Resumen del sistema:"
    Write-Host ""

    $instalados = 0
    $activos = 0
    foreach ($svc in $servicios) {
        $paquete = if ($svc.Interno -eq "iis") { $null } else {
            http_nombre_paquete $svc.Interno
        }
        $estaInstalado = if ($svc.Interno -eq "iis") {
            Import-Module ServerManager -ErrorAction SilentlyContinue
            $null -ne (Get-WindowsFeature "Web-Server" -ErrorAction SilentlyContinue |
                Where-Object Installed)
        }
        else {
            # Verificar por servicio Windows - mas fiable que choco list
            $null -ne (Get-Service -Name $svc.WinSvc -ErrorAction SilentlyContinue)
        }

        if ($estaInstalado) {
            $instalados++
            if (check_service_active $svc.WinSvc) { $activos++ }
        }
    }

    Write-Host ("  {0,-30} {1} de 4" -f "Servicios instalados:", $instalados)
    Write-Host ("  {0,-30} {1} de {2} instalados" -f "Servicios activos:", $activos, $instalados)

    # Carga del sistema (CPU media del proceso System)
    try {
        $cpuTotal = (Get-Counter '\Processor(_Total)\% Processor Time' `
                -SampleInterval 1 -MaxSamples 1 `
                -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
        Write-Host ("  {0,-30} {1:N1}%%" -f "Uso de CPU (sistema):", $cpuTotal)
    }
    catch { }
}

function _http_mon_firewall_puerto {
    param([int]$Puerto)

    $reglas = Get-NetFirewallRule -Direction Inbound -Enabled True `
        -ErrorAction SilentlyContinue
    $abierto = $false

    foreach ($regla in $reglas) {
        $pf = $regla | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if ($pf -and ($pf.LocalPort -contains "$Puerto" -or $pf.LocalPort -eq "Any")) {
            $abierto = $true
            break
        }
    }

    if ($abierto) {
        Write-Host ("  ${GREEN}[ABIERTO]${NC}  {0}/tcp" -f $Puerto)
    }
    else {
        Write-Host ("  ${YELLOW}[CERRADO]${NC}  {0}/tcp" -f $Puerto)
    }
}

function http_monitoreo_puertos {
    Clear-Host
    draw_header "Monitoreo de Puertos HTTP"
    Write-Host ""

    $servicios = @(
        @{ Nombre = "IIS"; Interno = "iis"; WinSvc = $Script:HTTP_WINSVC_IIS }
        @{ Nombre = "Apache"; Interno = "apache"; WinSvc = $Script:HTTP_WINSVC_APACHE }
        @{ Nombre = "Nginx"; Interno = "nginx"; WinSvc = $Script:HTTP_WINSVC_NGINX }
        @{ Nombre = "Tomcat"; Interno = "tomcat"; WinSvc = $Script:HTTP_WINSVC_TOMCAT }
    )

    # ====== Capa 1: Puertos de servicios HTTP instalados ==================================================================
    aputs_info "Puertos de servicios HTTP instalados:"
    Write-Host ""
    Write-Host ("  {0,-20} {1,-16} {2,-16} {3}" -f "SERVICIO", "PUERTO CONFIG", "PUERTO ACTIVO", "ESTADO")
    Write-Host "  ======================================================================================================================================================================================="

    $puertosAVerificar = @()

    foreach ($svc in $servicios) {
        $puertoConf = _http_leer_puerto_config $svc.Interno
        $puertoActivo = _http_obtener_puerto_activo $svc.WinSvc
        $estadoStr = if (check_service_active $svc.WinSvc) {
            "${GREEN}activo${NC}"
        }
        else { "${YELLOW}inactivo${NC}" }

        Write-Host ("  {0,-20} {1,-16} {2,-16} " -f `
                $svc.Nombre,
            "${puertoConf}/tcp",
            $(if ($puertoActivo -gt 0) { "${puertoActivo}/tcp" } else { "-" }))
        # Estado en la misma linea (con color)
        Write-Host -NoNewline ""

        if ([int]$puertoConf -gt 0) { $puertosAVerificar += [int]$puertoConf }
        if ($puertoActivo -gt 0) { $puertosAVerificar += $puertoActivo }
    }

    Write-Host ""
    draw_line

    # ====== Capa 2: Estado de puertos en Windows Firewall ===============================================================
    Write-Host ""
    aputs_info "Estado en Windows Firewall:"
    Write-Host ""

    $mpfService = Get-Service -Name mpssvc -ErrorAction SilentlyContinue
    if ($null -ne $mpfService -and $mpfService.Status -eq 'Running') {
        aputs_success "Windows Firewall: ACTIVO"
        Write-Host ""

        # Verificar puertos relevantes + defaults
        $todosLosPuertos = ($puertosAVerificar + @(80, 443, 8080, 8443)) |
        Sort-Object -Unique
        foreach ($p in $todosLosPuertos) {
            _http_mon_firewall_puerto $p
        }

        Write-Host ""
        aputs_info "Reglas de entrada activas (primeras 5):"
        Get-NetFirewallRule -Direction Inbound -Enabled True `
            -ErrorAction SilentlyContinue |
        Select-Object -First 5 -ExpandProperty DisplayName |
        ForEach-Object { Write-Host "    - $_" }

    }
    else {
        aputs_warning "Windows Firewall: INACTIVO"
        aputs_info    "Sin reglas activas - todos los puertos expuestos"
    }

    Write-Host ""
    draw_line

    # ====== Capa 3: Todos los puertos TCP en escucha del sistema ==========================================
    Write-Host ""
    aputs_info "Todos los puertos TCP en escucha del sistema:"
    Write-Host ""
    Write-Host ("  {0,-12} {1,-22} {2}" -f "ESTADO", "DIRECCION LOCAL", "PROCESO")
    Write-Host "  ==========================================================================================================================================================================="

    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Sort-Object LocalPort |
    ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        $nombre = if ($proc) { $proc.Name } else { "sistema" }
        Write-Host ("  {0,-12} {1,-22} {2}" -f `
                $_.State,
            "$($_.LocalAddress):$($_.LocalPort)",
            $nombre)
    }
}

function http_monitoreo_logs {
    Clear-Host
    draw_header "Logs de Servicio HTTP"

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    $winsvc = http_nombre_winsvc $servicio
    http_draw_servicio_header $servicio "Logs del Servicio"

    # Numero de lineas a mostrar
    $nLineas = ""
    do {
        $nLineas = agets "Numero de eventos a mostrar [50]"
        if ([string]::IsNullOrWhiteSpace($nLineas)) { $nLineas = "50" }
    } while (-not (http_validar_lineas_log $nLineas))

    $n = [int]$nLineas

    Write-Host ""
    draw_line
    aputs_info "Ultimos $n eventos - Get-EventLog (System + Application) para $winsvc"
    draw_line
    Write-Host ""

    # Obtener eventos del Event Log filtrados por el nombre del servicio
    $patron = $servicio.ToLower()
    $eventos = Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application' } `
        -MaxEvents ($n * 3) -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match $patron -or
        $_.ProviderName -match [regex]::Escape($winsvc) } |
    Select-Object -First $n

    if ($eventos) {
        $eventos | ForEach-Object {
            $levelStr = switch ($_.LevelDisplayName) {
                "Error" { "${RED}[ERR]${NC}" }
                "Warning" { "${YELLOW}[WRN]${NC}" }
                default { "${GRAY}[INF]${NC}" }
            }
            Write-Host ("  {0} {1}  {2}" -f `
                    $levelStr,
                $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss"),
                ($_.Message -split '\n')[0])
        }
    }
    else {
        aputs_info "(Sin eventos recientes en el Event Log para este servicio)"
        aputs_info "El servicio puede escribir logs propios en su directorio de instalacion"
    }

    Write-Host ""
    draw_line
    Write-Host ""

    # ====== Resumen de eventos - ultimas 24 horas =======================================================================================
    aputs_info "Resumen de eventos - ultimas 24 horas:"
    Write-Host ""

    $hace24h = (Get-Date).AddHours(-24)

    $todosEventos = Get-WinEvent -FilterHashtable @{
        LogName   = 'System', 'Application'
        StartTime = $hace24h
    } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match $patron -or
        $_.ProviderName -match [regex]::Escape($winsvc) }

    $nErrores = ($todosEventos | Where-Object { $_.LevelDisplayName -eq "Error" }).Count
    $nWarnings = ($todosEventos | Where-Object { $_.LevelDisplayName -eq "Warning" }).Count
    $nReinicios = ($todosEventos | Where-Object { $_.Message -match "start|restart|started" }).Count

    Write-Host ("  {0,-30} {1}" -f "Errores (24h):", $nErrores)
    Write-Host ("  {0,-30} {1}" -f "Advertencias (24h):", $nWarnings)
    Write-Host ("  {0,-30} {1}" -f "Reinicios (24h):", $nReinicios)

    Write-Host ""

    if ($nErrores -gt 5) {
        aputs_warning "Alto numero de errores detectados ($nErrores)"
        Write-Host ""
        aputs_info "Ultimos 5 errores:"
        $todosEventos |
        Where-Object { $_.LevelDisplayName -eq "Error" } |
        Select-Object -Last 5 |
        ForEach-Object {
            Write-Host ("    [{0}] {1}" -f `
                    $_.TimeCreated.ToString("HH:mm:ss"),
                ($_.Message -split '\n')[0])
        }
    }

    # ====== Logs de acceso del servicio (archivos propios) ===============================================================
    Write-Host ""
    $logAcceso = switch ($servicio) {
        "iis" { "C:\inetpub\logs\LogFiles\W3SVC1\u_ex$(Get-Date -Format 'yyMMdd').log" }
        "apache" {
            $apacheRoot = Split-Path (Split-Path $Script:HTTP_CONF_APACHE)
            Join-Path $apacheRoot "logs\access.log"
        }
        "nginx" {
            $nginxRoot = Split-Path (Split-Path $Script:HTTP_CONF_NGINX)
            Join-Path $nginxRoot "logs\access.log"
        }
        "tomcat" {
            $tomcatRoot = Split-Path (Split-Path $Script:HTTP_CONF_TOMCAT)
            Join-Path $tomcatRoot "logs\localhost_access_log.$(Get-Date -Format 'yyyy-MM-dd').txt"
        }
    }

    if (Test-Path $logAcceso) {
        aputs_info "Resumen de log de acceso HTTP: $logAcceso"
        Write-Host ""

        $lineas = Get-Content $logAcceso -ErrorAction SilentlyContinue
        $nTotal = if ($lineas) { $lineas.Count } else { 0 }
        $n4xx = ($lineas | Where-Object { $_ -match '" [4]\d{2} ' }).Count
        $n5xx = ($lineas | Where-Object { $_ -match '" [5]\d{2} ' }).Count

        Write-Host ("  {0,-30} {1}" -f "Total peticiones:", $nTotal)
        Write-Host ("  {0,-30} {1}" -f "Errores cliente 4xx:", $n4xx)
        Write-Host ("  {0,-30} {1}" -f "Errores servidor 5xx:", $n5xx)

        if ($n5xx -gt 0) {
            Write-Host ""
            aputs_warning "$n5xx errores de servidor detectados en access_log"
            aputs_info    "Ultimas 3 lineas con error 5xx:"
            $lineas | Where-Object { $_ -match '" [5]\d{2} ' } |
            Select-Object -Last 3 |
            ForEach-Object { Write-Host "    $_" }
        }
    }
}

function _http_mon_verificar_headers_seguridad {
    param([string[]]$Respuesta)

    Write-Host ""
    aputs_info "Auditoria de security headers (configurados en Grupo C):"
    Write-Host ""

    $headersEsperados = @(
        "X-Frame-Options",
        "X-Content-Type-Options",
        "X-XSS-Protection",
        "Referrer-Policy"
    )

    foreach ($h in $headersEsperados) {
        $linea = $Respuesta | Where-Object { $_ -match "^$h\s*:" } | Select-Object -First 1
        if ($linea) {
            $valor = ($linea -replace "^$h\s*:\s*", "").Trim()
            Write-Host ("  ${GREEN}[OK]${NC}    {0,-32} {1}" -f "${h}:", $valor)
        }
        else {
            Write-Host ("  ${YELLOW}[--]${NC}    {0,-32} AUSENTE" -f "${h}:")
        }
    }

    # Verificar Server - no debe revelar version
    Write-Host ""
    $serverLinea = $Respuesta | Where-Object { $_ -match "^Server\s*:" } | Select-Object -First 1
    if ($serverLinea) {
        $serverValor = ($serverLinea -replace "^Server\s*:\s*", "").Trim()
        if ($serverValor -match '\d+\.\d+') {
            Write-Host ("  ${YELLOW}[!!]${NC}    {0,-32} {1}" -f "Server:", $serverValor)
            aputs_warning "  El header Server revela version - aplique Grupo C opcion 2"
        }
        else {
            Write-Host ("  ${GREEN}[OK]${NC}    {0,-32} {1}" -f "Server:", $serverValor)
        }
    }
}

function http_monitoreo_headers {
    Clear-Host
    draw_header "Headers HTTP en Vivo"

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    $winsvc = http_nombre_winsvc $servicio
    http_draw_servicio_header $servicio "curl.exe -I"

    # Detectar puerto activo del servicio
    $puerto = _http_obtener_puerto_activo $winsvc
    if ($puerto -eq 0) {
        # Servicio inactivo - leer del archivo de config
        $puerto = [int](_http_leer_puerto_config $servicio)
    }

    if ($puerto -eq 0) {
        aputs_error "No se pudo detectar el puerto del servicio"
        aputs_info  "Verifique que el servicio esta activo: Get-Service $winsvc"
        return
    }

    aputs_info "Realizando peticion HEAD a http://localhost:${puerto} ..."
    Write-Host ""

    # curl.exe -I : peticion HEAD - solo headers, sin cuerpo
    # --max-time 5 : timeout de 5 segundos
    # --silent    : sin barra de progreso
    # --show-error: pero si mostrar errores de conexion
    $respuesta = curl.exe -sI --max-time 5 "http://localhost:${puerto}" 2>&1

    if ($LASTEXITCODE -ne 0) {
        aputs_error "curl.exe fallo con codigo $LASTEXITCODE"
        Write-Host ""
        aputs_info "Detalle del error:"
        $respuesta | ForEach-Object { Write-Host "    $_" }
        Write-Host ""
        aputs_info "Causas posibles:"
        Write-Host "    - El servicio esta inactivo"
        Write-Host "    - El puerto ${puerto} no coincide con el configurado"
        Write-Host "    - El Firewall esta bloqueando la conexion local"
        return
    }

    draw_line
    aputs_info "Respuesta completa de http://localhost:${puerto} :"
    draw_line
    Write-Host ""

    # Mostrar todos los headers con indentacion
    $lineasRespuesta = $respuesta -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    $lineasRespuesta | ForEach-Object { Write-Host "    $_" }

    # ====== Auditoria de security headers ===============================================================================================================
    _http_mon_verificar_headers_seguridad $lineasRespuesta

    Write-Host ""
    draw_line
    aputs_info "Comando equivalente desde red interna:"
    Write-Host "    curl.exe -I http://192.168.100.20:${puerto}"
    aputs_info "Equivalente PowerShell (sin flags curl):"
    Write-Host "    Invoke-WebRequest -Method HEAD -Uri http://localhost:${puerto} -UseBasicParsing"
}

function http_monitoreo_config {
    Clear-Host
    draw_header "Configuracion Activa del Servicio"

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    http_draw_servicio_header $servicio "Configuracion Activa"

    $confFile = http_get_conf_archivo $servicio

    # ====== Archivo de configuracion ==============================================================================================================================
    aputs_info "Archivo de configuracion: $confFile"
    Write-Host ""

    if (-not (Test-Path $confFile)) {
        aputs_error "Archivo no encontrado: $confFile"
        # Para IIS mostrar el binding activo via WebAdministration
        if ($servicio -eq "iis") {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $bindings = Get-WebBinding "Default Web Site" -ErrorAction SilentlyContinue
            if ($bindings) {
                aputs_info "Bindings activos de IIS:"
                $bindings | ForEach-Object {
                    Write-Host ("    Protocolo: {0}  Puerto: {1}" -f `
                            $_.protocol, ($_.bindingInformation -split ':')[1])
                }
            }
        }
    }
    else {
        aputs_info "Directivas activas (sin comentarios ni lineas vacias):"
        Write-Host ""
        # Filtrar comentarios y lineas vacias - equivale a grep -vE "^#|^$"
        Get-Content $confFile |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' } |
        Select-Object -First 40 |
        ForEach-Object { Write-Host "    $_" }
    }

    Write-Host ""
    draw_line

    # ====== Puerto configurado ================================================================================================================================================
    Write-Host ""
    $puertoConf = _http_leer_puerto_config $servicio
    $puertoActivo = _http_obtener_puerto_activo (http_nombre_winsvc $servicio)

    Write-Host ("  {0,-22}: {1}/tcp" -f "Puerto en config", $puertoConf)
    if ($puertoActivo -gt 0) {
        Write-Host ("  {0,-22}: {1}/tcp (activo)" -f "Puerto en escucha", $puertoActivo)
    }
    else {
        Write-Host ("  {0,-22}: sin escucha" -f "Puerto en escucha")
    }

    Write-Host ""
    draw_line

    # ====== Webroot =================================================================================================================================================================================
    Write-Host ""
    $webroot = http_get_webroot $servicio
    aputs_info "Directorio web (webroot): $webroot"
    Write-Host ""

    if (Test-Path $webroot -PathType Container) {
        # Propietario del directorio
        $acl = Get-Acl $webroot -ErrorAction SilentlyContinue
        Write-Host ("  {0,-18}: {1}" -f "Propietario", $acl.Owner)

        # Contenido del webroot
        Write-Host ""
        aputs_info "Contenido de ${webroot}:"
        Get-ChildItem $webroot -ErrorAction SilentlyContinue |
        Format-Table -AutoSize Name, Length, LastWriteTime |
        Out-String | ForEach-Object { Write-Host "    $_" }
    }
    else {
        aputs_warning "Webroot no existe: $webroot"
    }

    Write-Host ""
    draw_line

    # ====== Usuario del proceso =============================================================================================================================================
    Write-Host ""
    $usuario = http_get_usuario_servicio $servicio
    aputs_info "Usuario del servicio: $usuario"
    Write-Host ""

    $userObj = Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue

    if ($servicio -eq "iis") {
        Write-Host "  Cuenta integrada: NT AUTHORITY\IUSR"
        Write-Host "  ${GREEN}[OK]${NC}  Gestionada por Windows - sin login interactivo"
    }
    elseif ($null -ne $userObj) {
        Write-Host ("  {0,-18}: {1}" -f "SID", $userObj.SID)
        Write-Host ("  {0,-18}: {1}" -f "Habilitado", $userObj.Enabled)

        # Verificar restriccion de login (equivale a /sbin/nologin en Linux)
        # Comprobamos la politica de denegacion de inicio de sesion local
        $secPol = secedit /export /cfg "$env:TEMP\secpol_check.inf" /quiet 2>$null
        if (Test-Path "$env:TEMP\secpol_check.inf") {
            $polContent = Get-Content "$env:TEMP\secpol_check.inf" -Raw
            if ($polContent -match "SeDenyInteractiveLogonRight.*$usuario") {
                Write-Host "  ${GREEN}[OK]${NC}  Login interactivo denegado (equivale a /sbin/nologin)"
            }
            else {
                Write-Host "  ${YELLOW}[!!]${NC}  Login interactivo NO restringido - verifique la politica"
            }
            Remove-Item "$env:TEMP\secpol_check.inf" -ErrorAction SilentlyContinue
        }
    }
    else {
        aputs_warning "Usuario '$usuario' no existe en el sistema"
        aputs_info    "Use Grupo B opcion 2) para instalar y crear el usuario"
    }

    Write-Host ""
    draw_line
}

function http_menu_monitoreo {
    while ($true) {
        Clear-Host
        draw_header "Monitoreo de Servicios HTTP"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Estado del servicio   (PID, memoria, CPU, uptime)"
        Write-Host "  ${BLUE}2)${NC} Monitoreo de puertos  (escucha + Windows Firewall)"
        Write-Host "  ${BLUE}3)${NC} Logs del servicio     (Event Log + resumen errores)"
        Write-Host "  ${BLUE}4)${NC} Headers HTTP en vivo  (curl.exe -I + auditoria seguridad)"
        Write-Host "  ${BLUE}5)${NC} Configuracion activa  (directivas + webroot + usuario)"
        Write-Host "  ${BLUE}6)${NC} Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" { http_monitoreo_estado; Write-Host ""; pause_menu }
            "2" { http_monitoreo_puertos; Write-Host ""; pause_menu }
            "3" { http_monitoreo_logs; Write-Host ""; pause_menu }
            "4" { http_monitoreo_headers; Write-Host ""; pause_menu }
            "5" { http_monitoreo_config; Write-Host ""; pause_menu }
            "6" { return }
            default {
                aputs_error "Opcion invalida. Seleccione entre 1 y 6"
                Start-Sleep -Seconds 2
            }
        }
    }
}