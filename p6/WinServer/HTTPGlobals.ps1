#
# HTTPGlobals.ps1
# Constantes globales y helpers especificos de servicios HTTP - Windows Server 2022
#
# Equivalente a HTTPGlobals.sh de la practica Linux.
# Servicios Windows: IIS (W3SVC), Apache Win64 (httpd), Nginx Win, Tomcat
#
# Uso: . "$PSScriptRoot\HTTPGlobals.ps1"
#

#Requires -Version 5.1

$Script:HTTP_SERVICIO_IIS = "iis"
$Script:HTTP_SERVICIO_APACHE = "apache"
$Script:HTTP_SERVICIO_NGINX = "nginx"
$Script:HTTP_SERVICIO_TOMCAT = "tomcat"

$Script:HTTP_WINSVC_IIS = "W3SVC"       # IIS World Wide Web Publishing Service
$Script:HTTP_WINSVC_APACHE = "Apache2.4"   # Apache HTTP Server (httpd)
$Script:HTTP_WINSVC_NGINX = "nginx"       # Nginx (instalado como servicio)

# Detectar el nombre real del servicio Tomcat instalado
$_tomcatSvc = Get-Service -ErrorAction SilentlyContinue |
Where-Object { $_.Name -match '^Tomcat' } |
Select-Object -First 1
$Script:HTTP_WINSVC_TOMCAT = if ($_tomcatSvc) { $_tomcatSvc.Name } else { "Tomcat9" }

$Script:HTTP_DIR_IIS = "C:\inetpub\wwwroot"
$Script:HTTP_DIR_APACHE = "C:\tools\httpd\htdocs"
$Script:HTTP_DIR_NGINX = "C:\tools\nginx\html"
$Script:HTTP_DIR_TOMCAT = "C:\ProgramData\Tomcat9\webapps\ROOT"

$Script:HTTP_CONF_IIS = "C:\Windows\System32\inetsrv\config\applicationHost.config"
$Script:HTTP_CONF_APACHE = "C:\tools\httpd\conf\httpd.conf"
$Script:HTTP_CONF_NGINX = "C:\tools\nginx\conf\nginx.conf"
$Script:HTTP_CONF_TOMCAT = "C:\ProgramData\Tomcat9\conf\server.xml"

# choco puede instalar en rutas distintas a las constantes default.
# Llama a esta funcion al arrancar para actualizar las constantes.
function http_detectar_rutas_reales {
    # -Depth no existe en PS 5.1 (PS 6+). Se usan candidatos explicitos
    # para evitar Get-ChildItem -Recurse sobre C:\ que tarda minutos.

    # choco instala apache-httpd en USERPROFILE\AppData\Roaming\Apache24\
    # En sesiones elevadas USERPROFILE es correcto; APPDATA apunta a systemprofile.
    $roaming = "$env:USERPROFILE\AppData\Roaming"
    $apacheCandidatos = @(
        "C:\tools\httpd\conf\httpd.conf",
        "$roaming\Apache24\conf\httpd.conf",
        "$roaming\Apache2.4\conf\httpd.conf",
        "C:\Apache24\conf\httpd.conf",
        "C:\Apache2.4\conf\httpd.conf",
        "C:\Program Files\Apache Software Foundation\Apache2.4\conf\httpd.conf",
        "C:\Program Files (x86)\Apache Software Foundation\Apache2.4\conf\httpd.conf"
    )
    foreach ($c in $apacheCandidatos) {
        if (Test-Path $c) {
            $Script:HTTP_CONF_APACHE = $c
            $apacheRoot = Split-Path (Split-Path $c)
            $htdocs = Join-Path $apacheRoot "htdocs"
            if (Test-Path $htdocs) { $Script:HTTP_DIR_APACHE = $htdocs }
            break
        }
    }

    # Apache: detectar nombre real del servicio Windows
    # choco registra "Apache" (mayuscula), no "Apache2.4" ni "httpd"
    $svcApache = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -imatch '^Apache|^httpd' } | Select-Object -First 1
    if ($svcApache) { $Script:HTTP_WINSVC_APACHE = $svcApache.Name }

    # ====== Nginx =======================================================================================================================================================================================
    # Candidatos estaticos ordenados por probabilidad
    $nginxCandidatos = [System.Collections.Generic.List[string]]@(
        "C:\tools\nginx\conf\nginx.conf",
        "C:\nginx\conf\nginx.conf"
    )
    # Subdirectorios versionados en C:\tools (nginx-1.28.0, nginx-1.29.5, etc.)
    if (Test-Path "C:\tools") {
        $nginxConfDinamico = Get-ChildItem "C:\tools" -Filter nginx.conf `
            -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxConfDinamico) { $nginxCandidatos.Insert(0, $nginxConfDinamico.FullName) }
    }
    # ProgramData\chocolatey\lib\nginx\tools (choco >= 2.0)
    $chocoLibNginx = "$env:ProgramData\chocolatey\lib\nginx\tools"
    if (Test-Path $chocoLibNginx) {
        $nginxConfChoco = Get-ChildItem $chocoLibNginx -Filter nginx.conf `
            -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxConfChoco) { $nginxCandidatos.Insert(0, $nginxConfChoco.FullName) }
    }
    foreach ($c in $nginxCandidatos) {
        if (Test-Path $c) {
            $Script:HTTP_CONF_NGINX = $c
            $nginxHtml = Join-Path (Split-Path (Split-Path $c)) "html"
            if (Test-Path $nginxHtml) { $Script:HTTP_DIR_NGINX = $nginxHtml }
            break
        }
    }

    # ====== Tomcat ====================================================================================================================================================================================
    $tomcatCandidatos = @(
        "C:\ProgramData\Tomcat9\conf\server.xml",
        "C:\ProgramData\Tomcat10\conf\server.xml",
        "C:\tools\tomcat\conf\server.xml"
    )
    foreach ($tc in $tomcatCandidatos) {
        if (Test-Path $tc) {
            $Script:HTTP_CONF_TOMCAT = $tc
            $webappsRoot = Join-Path (Split-Path (Split-Path $tc)) "webapps\ROOT"
            if (Test-Path $webappsRoot) { $Script:HTTP_DIR_TOMCAT = $webappsRoot }
            break
        }
    }
}

$Script:HTTP_USUARIO_IIS = "IUSR"           # Cuenta anonima de IIS (built-in)
$Script:HTTP_USUARIO_APACHE = "apacheuser"     # Usuario local creado por el gestor
$Script:HTTP_USUARIO_NGINX = "nginxuser"      # Usuario local creado por el gestor
$Script:HTTP_USUARIO_TOMCAT = "tomcatuser"     # Usuario local creado por el gestor

$Script:HTTP_PUERTO_DEFAULT_IIS = 80
$Script:HTTP_PUERTO_DEFAULT_APACHE = 80
$Script:HTTP_PUERTO_DEFAULT_NGINX = 80
$Script:HTTP_PUERTO_DEFAULT_TOMCAT = 8080

$Script:HTTP_PUERTOS_RESERVADOS = @(22, 25, 53, 135, 139, 445, 3306, 3389, 5432, 6379, 27017)

function http_verificar_dependencias {
    $faltantes = 0

    $pathMachine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $pathUser = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $pathFull = ($pathMachine + ";" + $pathUser) -split ';' |
    Where-Object { $_ -ne '' } |
    Select-Object -Unique
    $env:PATH = $pathFull -join ';'

    # Asegurar JAVA_HOME si temurin esta instalado y la variable no esta definida
    if (-not $env:JAVA_HOME) {
        $javaExe = Get-ChildItem "C:\Program Files\Eclipse Adoptium" `
            -Recurse -Filter java.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($javaExe) {
            $env:JAVA_HOME = Split-Path $javaExe.DirectoryName
        }
    }

    # Herramientas criticas - sin estas el gestor no puede operar
    $herramientas = @{
        "choco"    = "Gestor de paquetes Chocolatey"
        "netsh"    = "Configuracion de firewall (netsh advfirewall)"
        "sc.exe"   = "Control de servicios de Windows"
        "curl.exe" = "Verificacion HTTP en vivo (curl -I)"
    }

    aputs_info "Verificando herramientas necesarias..."
    Write-Host ""

    foreach ($cmd in $herramientas.Keys) {
        $encontrado = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($encontrado) {
            Write-Host "  ${GREEN}[OK]${NC}  $($cmd.PadRight(15)) encontrado en: $($encontrado.Source)"
        }
        else {
            # Caso especial: choco no encontrado - intentar instalarlo automaticamente
            if ($cmd -eq "choco") {
                aputs_info "Chocolatey no encontrado - instalando automaticamente..."
                try {
                    # Comando oficial de instalacion de Chocolatey
                    Set-ExecutionPolicy Bypass -Scope Process -Force
                    [System.Net.ServicePointManager]::SecurityProtocol = `
                        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
                    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString(
                            'https://community.chocolatey.org/install.ps1'))

                    # Refrescar PATH tras la instalacion
                    $env:PATH += ";C:\ProgramData\chocolatey\bin"

                    $encontrado = Get-Command choco -ErrorAction SilentlyContinue
                    if ($encontrado) {
                        aputs_success "Chocolatey instalado correctamente: $(choco --version)"
                    }
                    else {
                        Write-Host "  ${RED}[NO]${NC}  $($cmd.PadRight(15)) instalacion fallida"
                        $faltantes++
                    }
                }
                catch {
                    Write-Host "  ${RED}[NO]${NC}  $($cmd.PadRight(15)) error al instalar: $($_.Exception.Message)"
                    $faltantes++
                }
            }
            else {
                Write-Host "  ${RED}[NO]${NC}  $($cmd.PadRight(15)) NO encontrado - $($herramientas[$cmd])"
                $faltantes++
            }
        }
    }

    # Modulo WebAdministration (IIS) - necesario solo para IIS
    Write-Host ""
    if (Get-Module -ListAvailable -Name WebAdministration) {
        Write-Host "  ${GREEN}[OK]${NC}  WebAdministration (IIS) disponible"
    }
    else {
        Write-Host "  ${YELLOW}[WARN]${NC} WebAdministration no instalado (solo necesario para IIS)"
        aputs_info  "  Instale con: Install-WindowsFeature Web-Scripting-Tools"
    }

    # Java - necesario solo para Tomcat
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) {
        $jver = (java -version 2>&1 | Select-Object -First 1)
        Write-Host "  ${GREEN}[OK]${NC}  java           $jver"
    }
    else {
        Write-Host "  ${YELLOW}[WARN]${NC} java no instalado (requerido solo para Tomcat)"
        aputs_info  "  Instale con: choco install temurin17 -y"
    }

    Write-Host ""

    if ($faltantes -gt 0) {
        aputs_error "$faltantes herramienta(s) critica(s) no encontrada(s)"
        return $false
    }

    aputs_success "Todas las dependencias criticas disponibles"

    # Actualizar constantes de ruta con la instalacion real de cada servicio
    # (choco puede instalar en rutas distintas a las constantes default)
    http_detectar_rutas_reales

    return $true
}

# Verifica si un puerto TCP esta actualmente en uso.
# Uso: http_puerto_en_uso 8080  === $true / $false
function http_puerto_en_uso {
    param([int]$Puerto)
    $conn = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conn)
}

# Obtiene el nombre del proceso que ocupa un puerto.
# Uso: http_quien_usa_puerto 80  === "httpd" | "w3wp" | "desconocido"
function http_quien_usa_puerto {
    param([int]$Puerto)
    $conn = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
    if ($null -eq $conn) { return "desconocido" }

    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) { return $proc.Name }
    return "PID $($conn.OwningProcess)"
}

# Devuelve el nombre del paquete Chocolatey del servicio.
# Uso: http_nombre_paquete "apache"  === "apache-httpd"
function http_nombre_paquete {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis" { return "iis" }            # Se instala con DISM, no choco
        "apache" { return "apache-httpd" }
        "nginx" { return "nginx" }
        "tomcat" { return "tomcat" }
        default { return $Servicio }
    }
}

# Devuelve el nombre del servicio Windows (Get-Service) del servicio HTTP.
# Uso: http_nombre_winsvc "apache"  === "Apache2.4"
function http_nombre_winsvc {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis" { return $Script:HTTP_WINSVC_IIS }
        "apache" { return $Script:HTTP_WINSVC_APACHE }
        "nginx" { return $Script:HTTP_WINSVC_NGINX }
        "tomcat" { return $Script:HTTP_WINSVC_TOMCAT }
        default { return $Servicio }
    }
}

# Devuelve el directorio webroot del servicio.
# Uso: http_get_webroot "nginx"  === "C:\tools\nginx\html"
function http_get_webroot {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis" { return $Script:HTTP_DIR_IIS }
        "apache" { return $Script:HTTP_DIR_APACHE }
        "nginx" { return $Script:HTTP_DIR_NGINX }
        "tomcat" { return $Script:HTTP_DIR_TOMCAT }
        default { return "C:\inetpub\wwwroot" }
    }
}

# Devuelve el usuario local dedicado al servicio.
# Uso: http_get_usuario_servicio "apache"  === "apacheuser"
function http_get_usuario_servicio {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis" { return $Script:HTTP_USUARIO_IIS }
        "apache" { return $Script:HTTP_USUARIO_APACHE }
        "nginx" { return $Script:HTTP_USUARIO_NGINX }
        "tomcat" { return $Script:HTTP_USUARIO_TOMCAT }
        default { return "nobody" }
    }
}

# Devuelve la ruta del archivo de configuracion principal del servicio.
# Uso: http_get_conf_archivo "nginx"  === "C:\tools\nginx\conf\nginx.conf"
function http_get_conf_archivo {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis" { return $Script:HTTP_CONF_IIS }
        "apache" { return $Script:HTTP_CONF_APACHE }
        "nginx" { return $Script:HTTP_CONF_NGINX }
        "tomcat" { return $Script:HTTP_CONF_TOMCAT }
        default { return "" }
    }
}

# Crea un backup del archivo de configuracion con timestamp.
# Uso: http_crear_backup "C:\tools\nginx\conf\nginx.conf"
function http_crear_backup {
    param([string]$Archivo)

    if (-not (Test-Path $Archivo)) {
        aputs_warning "Archivo no encontrado para backup: $Archivo"
        return $false
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backup = "${Archivo}.bak_${timestamp}"

    try {
        Copy-Item -Path $Archivo -Destination $backup -Force
        aputs_success "Backup creado: $backup"
        return $true
    }
    catch {
        aputs_error "No se pudo crear backup de: $Archivo"
        aputs_error $_.Exception.Message
        return $false
    }
}

# Restaura el backup mas reciente de un archivo de configuracion.
# Uso: http_restaurar_backup "C:\tools\nginx\conf\nginx.conf"
function http_restaurar_backup {
    param([string]$Archivo)

    $dir = Split-Path $Archivo -Parent
    $nombre = Split-Path $Archivo -Leaf
    $backups = Get-ChildItem -Path $dir -Filter "${nombre}.bak_*" `
        -ErrorAction SilentlyContinue |
    Sort-Object Name

    if ($backups.Count -eq 0) {
        aputs_error "No se encontro ningun backup para: $Archivo"
        return $false
    }

    $reciente = $backups | Select-Object -Last 1
    aputs_info "Restaurando desde: $($reciente.FullName)"

    try {
        Copy-Item -Path $reciente.FullName -Destination $Archivo -Force
        aputs_success "Archivo restaurado correctamente"
        return $true
    }
    catch {
        aputs_error "Error al restaurar el backup: $($_.Exception.Message)"
        return $false
    }
}

function http_draw_servicio_header {
    param([string]$Servicio, [string]$Accion)
    Write-Host ""
    Write-Host "================================================================================================================================================"
    Write-Host "  ${CYAN}[HTTP]${NC} $Servicio - $Accion"
    Write-Host "================================================================================================================================================"
    Write-Host ""
}

function http_draw_resumen {
    param([string]$Servicio, [string]$Puerto, [string]$Version)
    Write-Host ""
    Write-Host "  ===================================================================================================================================="
    Write-Host "  ===  ${GREEN}Despliegue completado exitosamente${NC}        ==="
    Write-Host "  ===================================================================================================================================="
    Write-Host ("  ===  {0,-10} {1,-30} ===" -f "Servicio:", $Servicio)
    Write-Host ("  ===  {0,-10} {1,-30} ===" -f "Version:", $Version)
    Write-Host ("  ===  {0,-10} {1,-30} ===" -f "Puerto:", "${Puerto}/tcp")
    Write-Host "  ===================================================================================================================================="
    Write-Host ""
    aputs_info "Verificacion rapida:"
    Write-Host "    curl.exe -I http://localhost:${Puerto}"
    Write-Host ""
}

function http_recargar_servicio {
    param([string]$Servicio)
    $winsvc = http_nombre_winsvc $Servicio
    aputs_info "Recargando configuracion de $winsvc..."

    # IIS tiene iisreset para recarga sin parar el servicio
    if ($Servicio -eq "iis") {
        $resultado = iisreset /noforce 2>&1
        if ($LASTEXITCODE -eq 0) {
            aputs_success "IIS recargado correctamente"
            return $true
        }
        aputs_warning "iisreset fallo - intentando restart..."
    }

    return (http_reiniciar_servicio $Servicio)
}

function http_reiniciar_servicio {
    param([string]$Servicio)
    $winsvc = http_nombre_winsvc $Servicio
    aputs_info "Reiniciando $winsvc..."

    try {
        Restart-Service -Name $winsvc -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        if (check_service_active $winsvc) {
            $pid_ = (Get-Process | Where-Object { $_.Name -match ($Servicio -replace "iis", "w3wp") } |
                Select-Object -First 1).Id
            aputs_success "$winsvc reiniciado$(if($pid_){" - PID: $pid_"})"
            return $true
        }
        else {
            aputs_error "$winsvc no levanto tras el reinicio"
            aputs_info  "Revise: Get-EventLog -LogName System -Source $winsvc -Newest 10"
            return $false
        }
    }
    catch {
        aputs_error "Error al reiniciar ${winsvc}: $($_.Exception.Message)"
        return $false
    }
}

# Verifica que el servicio responde HTTP en el puerto indicado.
# Uso: http_verificar_respuesta "apache" 8080
function http_verificar_respuesta {
    param([string]$Servicio, [int]$Puerto)

    aputs_info "Verificando respuesta HTTP en localhost:${Puerto}..."
    Write-Host ""

    $headers = curl.exe -sI --max-time 5 "http://localhost:${Puerto}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        aputs_error "El servicio no responde en el puerto $Puerto"
        return $false
    }

    $headers | ForEach-Object { Write-Host "    $_" }
    aputs_success "Servicio respondiendo en puerto $Puerto"
    return $true
}