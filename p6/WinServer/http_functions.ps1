# http_functions.ps1
# Gestion de servidores HTTP: IIS, Apache Win64, Nginx para Windows
# Requiere: ejecucion como Administrador

# ─────────────────────────────────────────────────────────────────────────────
# FUNCIONES DE SALIDA (compatibilidad si no viene de common-functions.ps1)
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Get-Command Write-OK -ErrorAction SilentlyContinue)) {
    function Write-OK  { param($m) Write-Host "  [OK] $m"     -ForegroundColor Green  }
    function Write-Err { param($m) Write-Host "  [ERROR] $m"  -ForegroundColor Red    }
    function Write-Inf { param($m) Write-Host "  [INFO] $m"   -ForegroundColor Cyan   }
    function Write-Wrn { param($m) Write-Host "  [AVISO] $m"  -ForegroundColor Yellow }
    function Pausar    { Write-Host ""; Read-Host "  Presiona ENTER para continuar" }
}

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES GLOBALES
# ─────────────────────────────────────────────────────────────────────────────
$HTTP_STATE_FILE  = "C:\http-manager\state.ps1"
$HTTP_CHOCO_OK    = $null   # cache: si chocolatey esta disponible

# Puertos reservados (no permitidos para HTTP)
$HTTP_PUERTOS_RESERVADOS = @(22, 21, 25, 53, 110, 143, 443, 993, 995, 3306, 5432, 8443)

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS INTERNOS
# ─────────────────────────────────────────────────────────────────────────────

# Nombre del servicio Windows segun el servidor HTTP
# Apache puede registrarse con distintos nombres segun el instalador/version
function _HTTP-NombreServicio {
    param([string]$Svc)
    switch ($Svc) {
        "iis"    { return "W3SVC" }
        "apache" {
            foreach ($n in @("Apache2.4","Apache24","Apache2","ApacheHTTPServer","httpd","apache")) {
                if (Get-Service $n -ErrorAction SilentlyContinue) { return $n }
            }
            return "Apache2.4"   # fallback si ningun servicio encontrado
        }
        "nginx"  { return "nginx" }
        default  { return $Svc }
    }
}

# Lee el webroot REAL desde el archivo de configuracion del servicio
# Esto soluciona el problema de "Welcome to nginx!" / pagina por defecto
function _HTTP-WebrootReal {
    param([string]$Svc)
    switch ($Svc) {
        "nginx" {
            $confPath = $null
            foreach ($pat in @(
                "C:\nginx\conf\nginx.conf",
                "C:\nginx*\conf\nginx.conf",
                "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\conf\nginx.conf",
                "C:\ProgramData\chocolatey\lib\nginx\tools\nginx\conf\nginx.conf"
            )) {
                $f = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($f) { $confPath = $f.FullName; break }
            }
            if ($confPath) {
                $rootLine = Get-Content $confPath |
                            Where-Object { $_ -match '^\s*root\s+' } |
                            Select-Object -First 1
                if ($rootLine -match '^\s*root\s+([^;]+);') {
                    $rootVal = $Matches[1].Trim().Trim('"').Replace('/', '\')
                    if (-not [System.IO.Path]::IsPathRooted($rootVal)) {
                        # "root html;" -> relativo al directorio padre de conf/
                        $nginxBase = Split-Path (Split-Path $confPath)
                        $rootVal = Join-Path $nginxBase $rootVal
                    }
                    $rootVal = [System.IO.Path]::GetFullPath($rootVal)
                    New-Item -ItemType Directory -Path $rootVal -Force -ErrorAction SilentlyContinue | Out-Null
                    return $rootVal
                }
            }
            return $null
        }
        "apache" {
            $confPath = $null
            foreach ($pat in @(
                "C:\Apache24\conf\httpd.conf",
                "C:\Apache*\conf\httpd.conf",
                "C:\ProgramData\chocolatey\lib\apache-httpd*\tools\Apache*\conf\httpd.conf"
            )) {
                $f = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($f) { $confPath = $f.FullName; break }
            }
            if ($confPath) {
                $drLine = Get-Content $confPath |
                          Where-Object { $_ -match '^\s*DocumentRoot\s+' -and $_ -notmatch '^\s*#' } |
                          Select-Object -First 1
                if ($drLine -match '^\s*DocumentRoot\s+"?([^"]+)"?') {
                    $dr = $Matches[1].Trim().Trim('"').Replace('/', '\')
                    $srvRoot = Split-Path (Split-Path $confPath)
                    $dr = $dr -replace '\$\{SRVROOT\}', $srvRoot
                    $dr = [System.IO.Path]::GetFullPath($dr)
                    if (Test-Path $dr) { return $dr }
                }
            }
            return $null
        }
        "iis" {
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $site = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
                if ($site) {
                    $path = $site.PhysicalPath -replace '%SystemDrive%', $env:SystemDrive
                    return $path
                }
            } catch {}
            return "C:\inetpub\wwwroot"
        }
    }
    return $null
}

# Webroot segun el servidor — primero intenta leerlo del archivo de config real
function _HTTP-Webroot {
    param([string]$Svc)
    # Intentar webroot real desde configuracion del servicio
    $real = _HTTP-WebrootReal $Svc
    if ($real) { return $real }
    # Fallback a deteccion por patrones de rutas conocidas
    switch ($Svc) {
        "iis"    { return "C:\inetpub\wwwroot" }
        "apache" {
            $ap = Get-Item "C:\Apache*\htdocs" -ErrorAction SilentlyContinue |
                  Select-Object -First 1
            if (-not $ap) {
                $ap = Get-ChildItem "C:\ProgramData\chocolatey\lib\apache-httpd*\tools\Apache*\htdocs" `
                      -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($ap) { return $ap.FullName } else { return "C:\Apache24\htdocs" }
        }
        "nginx"  {
            $ng = Get-ChildItem "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\html" `
                                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ng) { return $ng.FullName }
            $ng = Get-Item "C:\nginx*\html" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ng) { return $ng.FullName } else { return "C:\nginx\html" }
        }
    }
}

# Guarda / actualiza la entrada de UN servicio en el archivo de estado
# Formato: svc|puerto|version  (una linea por servicio)
function _HTTP-GuardarEstado {
    param([string]$Svc, [string]$Puerto, [string]$Version)
    New-Item -ItemType Directory -Path (Split-Path $HTTP_STATE_FILE) -Force | Out-Null
    $lines = @()
    if (Test-Path $HTTP_STATE_FILE) {
        $lines = Get-Content $HTTP_STATE_FILE |
                 Where-Object { $_ -notmatch "^$Svc\|" -and $_ -notmatch '^\s*$' }
    }
    $lines += "${Svc}|${Puerto}|${Version}"
    $lines | Set-Content $HTTP_STATE_FILE -Encoding UTF8
}

# Elimina la entrada de un servicio del archivo de estado
function _HTTP-EliminarEstado {
    param([string]$Svc)
    if (-not (Test-Path $HTTP_STATE_FILE)) { return }
    $lines = Get-Content $HTTP_STATE_FILE |
             Where-Object { $_ -notmatch "^$Svc\|" -and $_ -notmatch '^\s*$' }
    $lines | Set-Content $HTTP_STATE_FILE -Encoding UTF8
}

# Lee todos los servicios activos del archivo de estado.
# Popula: $script:HTTP_ACTIVE_SVCS (array)
#         $script:HTTP_SVCS_PUERTOS / $script:HTTP_SVCS_VERSIONES (hashtables)
# Compat: $script:HTTP_SVC / HTTP_PUERTO / HTTP_VERSION apuntan al primer servicio
function _HTTP-LeerEstado {
    $script:HTTP_SVC      = ""
    $script:HTTP_PUERTO   = ""
    $script:HTTP_VERSION  = ""
    $script:HTTP_ACTIVE_SVCS    = @()
    $script:HTTP_SVCS_PUERTOS   = @{}
    $script:HTTP_SVCS_VERSIONES = @{}
    if (-not (Test-Path $HTTP_STATE_FILE)) { return }
    # Detectar formato antiguo (sin '|') y convertirlo al nuevo formato pipe-separado
    $rawContent = Get-Content $HTTP_STATE_FILE -Raw
    if ($rawContent -notmatch '\|') {
        # Formato antiguo: lineas como  $HTTP_SVC = "tomcat"  o  HTTP_SVC="tomcat"
        $oSvc = ""; $oPuerto = ""; $oVersion = ""
        foreach ($ln in ($rawContent -split "`n")) {
            $ln = $ln.Trim()
            if ($ln -match '^\$?HTTP_SVC\s*=\s*"([^"]*)"')     { $oSvc     = $Matches[1] }
            if ($ln -match '^\$?HTTP_PUERTO\s*=\s*"([^"]*)"')   { $oPuerto  = $Matches[1] }
            if ($ln -match '^\$?HTTP_VERSION\s*=\s*"([^"]*)"')  { $oVersion = $Matches[1] }
        }
        if ($oSvc) {
            "${oSvc}|${oPuerto}|${oVersion}" | Set-Content $HTTP_STATE_FILE -Encoding UTF8
        } else {
            Remove-Item $HTTP_STATE_FILE -Force -ErrorAction SilentlyContinue
            return
        }
    }
    foreach ($line in (Get-Content $HTTP_STATE_FILE)) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith('#')) { continue }
        $parts = $line -split '\|', 3
        if ($parts.Count -lt 2) { continue }
        $s = $parts[0].Trim()
        $p = $parts[1].Trim()
        $v = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
        # Sanidad: ignorar entradas con caracteres invalidos en el nombre de servicio
        if ($s -notmatch '^[a-zA-Z0-9_-]+$') { continue }
        $script:HTTP_ACTIVE_SVCS += $s
        $script:HTTP_SVCS_PUERTOS[$s]   = $p
        $script:HTTP_SVCS_VERSIONES[$s] = $v
        if ([string]::IsNullOrEmpty($script:HTTP_SVC)) {
            $script:HTTP_SVC     = $s
            $script:HTTP_PUERTO  = $p
            $script:HTTP_VERSION = $v
        }
    }
}

# Devuelve el puerto de un servicio especifico desde el archivo de estado
function _HTTP-PuertoDeServicio {
    param([string]$Svc)
    if (-not (Test-Path $HTTP_STATE_FILE)) { return "" }
    $line = Get-Content $HTTP_STATE_FILE |
            Where-Object { $_ -match "^$Svc\|" } | Select-Object -First 1
    if ($line) { return ($line -split '\|')[1] }
    return ""
}

# Si hay un solo servicio activo lo devuelve; si hay varios, pide al usuario elegir.
# Devuelve $null si no hay servicios activos.
function _HTTP-SeleccionarActivo {
    _HTTP-LeerEstado
    if ($HTTP_ACTIVE_SVCS.Count -eq 0) {
        Write-Wrn "No hay servicios HTTP gestionados."
        return $null
    }
    if ($HTTP_ACTIVE_SVCS.Count -eq 1) { return $HTTP_ACTIVE_SVCS[0] }
    Write-Host ""
    Write-Host "  Servicios activos:"
    for ($i = 0; $i -lt $HTTP_ACTIVE_SVCS.Count; $i++) {
        $s = $HTTP_ACTIVE_SVCS[$i]
        $p = $HTTP_SVCS_PUERTOS[$s]
        Write-Host ("    {0}) {1} (puerto: {2})" -f ($i + 1), $s, $p)
    }
    while ($true) {
        $sel = Read-Host "  Seleccione servicio [1-$($HTTP_ACTIVE_SVCS.Count)]"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $HTTP_ACTIVE_SVCS.Count) {
            return $HTTP_ACTIVE_SVCS[[int]$sel - 1]
        }
        Write-Wrn "Seleccion invalida."
    }
}

# Verifica si un puerto esta ocupado
function _HTTP-PuertoEnUso {
    param([int]$Puerto)
    $conn = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conn)
}

# Verifica si el puerto esta en la lista negra
function _HTTP-PuertoReservado {
    param([int]$Puerto)
    return $HTTP_PUERTOS_RESERVADOS -contains $Puerto
}

# Validacion completa de puerto
function _HTTP-ValidarPuerto {
    param([int]$Puerto, [string]$SvcActual = "")
    if ($Puerto -lt 1 -or $Puerto -gt 65535) {
        Write-Wrn "Puerto invalido: debe estar entre 1 y 65535."
        return $false
    }
    if (_HTTP-PuertoReservado $Puerto) {
        Write-Wrn "Puerto $Puerto esta reservado para otro servicio del sistema."
        return $false
    }
    if (_HTTP-PuertoEnUso $Puerto) {
        # Permitir si es el mismo servicio activo
        if ($SvcActual -ne "") {
            $sd = _HTTP-NombreServicio $SvcActual
            $proc = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue |
                    Select-Object -First 1 |
                    ForEach-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name }
            if ($proc -match $sd) { return $true }
        }
        Write-Wrn "Puerto $Puerto ya esta en uso por otro proceso."
        return $false
    }
    return $true
}

# Solicita puerto con validacion
function _HTTP-PedirPuerto {
    param([string]$Default = "80", [string]$Svc = "")
    while ($true) {
        $inp = Read-Host "  Puerto de escucha [$Default]"
        if ([string]::IsNullOrWhiteSpace($inp)) { $inp = $Default }
        if ($inp -notmatch '^\d+$') { Write-Wrn "Ingresa solo numeros."; continue }
        if (_HTTP-ValidarPuerto ([int]$inp) $Svc) { return $inp }
    }
}

# Verifica si Chocolatey esta disponible, intenta instalarlo si no
function _HTTP-VerificarChoco {
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    Write-Inf "Chocolatey no encontrado. Instalando..."
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-OK "Chocolatey instalado correctamente"
            return $true
        }
    } catch {
        Write-Wrn "No se pudo instalar Chocolatey: $_"
    }
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# CONSULTA DINAMICA DE VERSIONES
# ─────────────────────────────────────────────────────────────────────────────

# Devuelve lista de versiones disponibles para un paquete via Chocolatey
function _HTTP-VersionesChoco {
    param([string]$Paquete)
    if (-not (_HTTP-VerificarChoco)) { return @() }
    # choco list en v2.x solo muestra paquetes locales; usar choco search para repositorio remoto
    $raw = choco search $Paquete --all-versions --exact --limit-output 2>$null |
           Where-Object { $_ -match "^$Paquete\|" } |
           ForEach-Object { ($_ -split '\|')[1] }
    if (-not $raw -or $raw.Count -eq 0) {
        # Fallback: busqueda sin --exact (puede devolver el paquete junto a otros)
        $raw = choco search $Paquete --limit-output 2>$null |
               Where-Object { $_ -match "^$Paquete\|" } |
               ForEach-Object { ($_ -split '\|')[1] }
    }
    return $raw | Sort-Object { [version]($_ -replace '[^0-9.]','') } -Descending -ErrorAction SilentlyContinue
}

# Devuelve version instalada de IIS
function _HTTP-VersionIIS {
    try {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction Stop).MajorVersion
        $mv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction Stop).MinorVersion
        return "$v.$mv"
    } catch { return "desconocida" }
}

# Menu de seleccion de version  -  devuelve la elegida
function _HTTP-SeleccionarVersion {
    param([string]$Svc)
    $versiones = @()

    Write-Inf "Consultando versiones disponibles de '$Svc'..."

    switch ($Svc) {
        "iis" {
            # IIS se instala via Windows Features  -  la version depende del SO
            $v = _HTTP-VersionIIS
            $versiones = @("$v (instalada en este servidor)")
        }
        "apache" {
            $versiones = @(_HTTP-VersionesChoco "apache-httpd")
            if ($versiones.Count -eq 0) {
                # Fallback: versiones conocidas estables (winget no disponible en Windows Server)
                Write-Inf "Choco no devolvio versiones remotas. Usando versiones conocidas..."
                $versiones = @("2.4.62", "2.4.59", "2.4.58")
            }
        }
        "nginx" {
            $versiones = @(_HTTP-VersionesChoco "nginx")
            if ($versiones.Count -eq 0) {
                Write-Inf "Choco no devolvio versiones remotas. Usando versiones conocidas..."
                $versiones = @("1.27.4", "1.26.3", "1.24.0")
            }
        }
    }

    if ($versiones.Count -eq 0) {
        Write-Wrn "No se encontraron versiones para '$Svc'."
        Write-Inf "Verifica la conexion a internet o que Chocolatey este disponible."
        return $null
    }

    Write-Host ""
    Write-Host "  Versiones disponibles para $Svc :"
    for ($i = 0; $i -lt $versiones.Count; $i++) {
        $etiqueta = ""
        if ($i -eq 0)                        { $etiqueta = "  <- LTS (estable)"     }
        if ($i -eq ($versiones.Count - 1))   { $etiqueta = "  <- Latest (desarrollo)" }
        Write-Host ("    {0,2}) {1}{2}" -f ($i+1), $versiones[$i], $etiqueta)
    }
    Write-Host ""

    while ($true) {
        $sel = Read-Host "  Seleccione version [1-$($versiones.Count)]"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $versiones.Count) {
            return $versiones[[int]$sel - 1]
        }
        Write-Wrn "Seleccion invalida."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────

function _HTTP-FwAbrir {
    param([string]$Puerto)
    $nombre = "HTTP-Custom-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $nombre -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $nombre `
            -Direction Inbound -Protocol TCP -LocalPort $Puerto `
            -Action Allow -Profile Any | Out-Null
        Write-OK "Firewall: regla '$nombre' creada (puerto $Puerto/TCP)"
    } else {
        Write-Inf "Firewall: regla para puerto $Puerto ya existe"
    }
}

function _HTTP-FwCerrar {
    param([string]$Puerto)
    $nombre = "HTTP-Custom-$Puerto"
    if (Get-NetFirewallRule -DisplayName $nombre -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $nombre
        Write-Inf "Firewall: regla '$nombre' eliminada (puerto $Puerto cerrado)"
    }
}

# Cierra puertos HTTP por defecto si no los usa el servicio activo
function _HTTP-FwCerrarDefaults {
    param([string]$PuertoActivo)
    foreach ($p in @("80", "8080")) {
        if ($p -ne $PuertoActivo) {
            _HTTP-FwCerrar $p
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURAR PUERTO EN CADA SERVICIO
# ─────────────────────────────────────────────────────────────────────────────

function _HTTP-AplicarPuertoIIS {
    param([string]$Puerto)
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $sitio = "Default Web Site"
        # Eliminar binding HTTP anterior y crear uno nuevo con el puerto elegido
        $oldBinding = Get-WebBinding -Name $sitio -Protocol "http" -ErrorAction SilentlyContinue
        if ($oldBinding) { Remove-WebBinding -Name $sitio -Protocol "http" -ErrorAction SilentlyContinue }
        New-WebBinding -Name $sitio -Protocol "http" -Port $Puerto -IPAddress "*" | Out-Null
        Write-OK "IIS: binding HTTP actualizado al puerto $Puerto"
    } catch {
        Write-Wrn "Error configurando binding IIS: $_"
    }
}

function _HTTP-AplicarPuertoApache {
    param([string]$Puerto)
    # Buscar httpd.conf en rutas conocidas de Chocolatey y rutas directas
    $confPath = $null
    foreach ($patron in @(
        "C:\Apache24\conf\httpd.conf",
        "C:\Apache*\conf\httpd.conf",
        "C:\ProgramData\chocolatey\lib\apache-httpd*\tools\Apache*\conf\httpd.conf",
        "C:\ProgramData\chocolatey\lib\apache-httpd\tools\Apache24\conf\httpd.conf"
    )) {
        $found = Get-Item $patron -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $confPath = $found.FullName; break }
    }
    if (-not $confPath) { Write-Wrn "No se encontro httpd.conf de Apache"; return }
    (Get-Content $confPath) -replace 'Listen \d+', "Listen $Puerto" |
        Set-Content $confPath -Encoding UTF8
    Write-OK "Apache: puerto actualizado a $Puerto en $confPath"
}

function _HTTP-AplicarPuertoNginx {
    param([string]$Puerto)
    $confPath = $null
    foreach ($patron in @(
        "C:\nginx\conf\nginx.conf",
        "C:\nginx*\conf\nginx.conf",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\conf\nginx.conf",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx\conf\nginx.conf"
    )) {
        $found = Get-Item $patron -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $confPath = $found.FullName; break }
    }
    if (-not $confPath) { Write-Wrn "No se encontro nginx.conf"; return }
    (Get-Content $confPath) -replace 'listen\s+\d+', "listen $Puerto" |
        Set-Content $confPath -Encoding UTF8
    Write-OK "Nginx: puerto actualizado a $Puerto en $confPath"
}

function _HTTP-AplicarPuerto {
    param([string]$Svc, [string]$Puerto)
    switch ($Svc) {
        "iis"    { _HTTP-AplicarPuertoIIS    $Puerto }
        "apache" { _HTTP-AplicarPuertoApache $Puerto }
        "nginx"  { _HTTP-AplicarPuertoNginx  $Puerto }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SEGURIDAD
# ─────────────────────────────────────────────────────────────────────────────

function _HTTP-SeguridadIIS {
    param([string]$Puerto)
    try {
        Import-Module WebAdministration -ErrorAction Stop

        # Eliminar cabecera X-Powered-By
        Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter "system.webServer/httpProtocol/customHeaders" `
            -Name "." -AtElement @{name='X-Powered-By'} -ErrorAction SilentlyContinue
        Write-OK "IIS: cabecera X-Powered-By eliminada"

        # Ocultar version del servidor via Request Filtering
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter "system.webServer/security/requestFiltering" `
            -Name "removeServerHeader" -Value $true -ErrorAction SilentlyContinue
        Write-OK "IIS: server header ocultado (removeServerHeader)"

        # Agregar security headers y deshabilitar metodos peligrosos via web.config
        $webroot = _HTTP-Webroot "iis"
        $webConfig = "$webroot\web.config"
        $contenido = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <add name="X-Frame-Options" value="SAMEORIGIN" />
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="X-XSS-Protection" value="1; mode=block" />
      </customHeaders>
      <redirectHeaders>
        <clear />
      </redirectHeaders>
    </httpProtocol>
    <security>
      <requestFiltering>
        <verbs allowUnlisted="false">
          <add verb="GET"  allowed="true" />
          <add verb="POST" allowed="true" />
          <add verb="HEAD" allowed="true" />
        </verbs>
      </requestFiltering>
    </security>
  </system.webServer>
</configuration>
'@
        Set-Content -Path $webConfig -Value $contenido -Encoding UTF8
        Write-OK "IIS: web.config con security headers y restriccion de metodos HTTP"
    } catch {
        Write-Wrn "Error aplicando seguridad IIS: $_"
    }
}

function _HTTP-SeguridadApache {
    param([string]$Puerto)
    $confDir = Get-Item "C:\Apache*\conf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $confDir) { Write-Wrn "No se encontro directorio conf de Apache"; return }

    # Editar httpd.conf: ServerTokens Prod + ServerSignature Off
    $httpd = "$($confDir.FullName)\httpd.conf"
    if (Test-Path $httpd) {
        $c = Get-Content $httpd
        $c = $c -replace '^ServerTokens.*',   'ServerTokens Prod'
        $c = $c -replace '^ServerSignature.*', 'ServerSignature Off'
        if ($c -notmatch 'ServerTokens')    { $c += "`nServerTokens Prod"    }
        if ($c -notmatch 'ServerSignature') { $c += "`nServerSignature Off"  }
        if ($c -notmatch 'TraceEnable')     { $c += "`nTraceEnable Off"      }
        Set-Content $httpd $c -Encoding UTF8
        Write-OK "Apache: ServerTokens Prod + ServerSignature Off + TraceEnable Off"
    }

    # .htaccess con security headers
    $webroot = _HTTP-Webroot "apache"
    if (Test-Path $webroot) {
        @'
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set X-XSS-Protection "1; mode=block"
<LimitExcept GET POST HEAD>
    Require all denied
</LimitExcept>
'@ | Set-Content "$webroot\.htaccess" -Encoding UTF8
        Write-OK "Apache: .htaccess con security headers configurado"
    }
}

function _HTTP-SeguridadNginx {
    param([string]$Puerto)

    # Detectar directorio conf de nginx (Chocolatey o instalacion directa)
    $confDir = $null
    foreach ($pat in @(
        "C:\nginx\conf",
        "C:\nginx*\conf",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx\conf",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\conf"
    )) {
        $confDir = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($confDir) { break }
    }
    if (-not $confDir) { Write-Wrn "No se encontro directorio conf de Nginx"; return }

    # Eliminar security-headers.conf con directivas sueltas fuera de server block
    # (causaban: "add_header directive is not allowed here" / crash al iniciar nginx)
    $secOld = "$($confDir.FullName)\security-headers.conf"
    if (Test-Path $secOld) {
        Rename-Item $secOld "$secOld.bak" -ErrorAction SilentlyContinue
        Write-Inf "Config antigua respaldada: $secOld.bak (directivas sueltas eliminadas)"
    }

    $conf = "$($confDir.FullName)\nginx.conf"
    if (-not (Test-Path $conf)) { Write-Wrn "No se encontro nginx.conf"; return }

    # Backup antes de modificar
    if (-not (Test-Path "$conf.orig")) { Copy-Item $conf "$conf.orig" }

    $c = Get-Content $conf -Raw

    # 1. server_tokens off en bloque http (ocultar version de nginx en header Server:)
    if ($c -notmatch 'server_tokens') {
        # Insertar despues de keepalive_timeout o sendfile si existen
        if ($c -match 'keepalive_timeout') {
            $c = $c -replace '(keepalive_timeout[^\n]+)', "`$1`n    server_tokens off;"
        } elseif ($c -match 'sendfile') {
            $c = $c -replace '(sendfile[^\n]+)', "`$1`n    server_tokens off;"
        } else {
            $c = $c -replace '(http\s*\{)', "`$1`n    server_tokens off;"
        }
        Write-OK "Nginx: server_tokens off aplicado"
    } else {
        # Asegurar que este 'off' y no 'on'
        $c = $c -replace 'server_tokens\s+on;', 'server_tokens off;'
        Write-Inf "Nginx: server_tokens ya estaba configurado"
    }

    # 2. Security headers dentro del bloque server (despues de server_name)
    $hdrs = "`n        add_header X-Frame-Options `"SAMEORIGIN`" always;" +
            "`n        add_header X-Content-Type-Options `"nosniff`" always;" +
            "`n        add_header X-XSS-Protection `"1; mode=block`" always;" +
            "`n        add_header Referrer-Policy `"strict-origin-when-cross-origin`" always;"
    if ($c -notmatch 'X-Frame-Options') {
        $c = $c -replace '(server_name\s+\S+;)', "`$1$hdrs"
        Write-OK "Nginx: 4 security headers agregados (X-Frame, X-Content-Type, X-XSS, Referrer-Policy)"
    } else {
        Write-Inf "Nginx: security headers ya presentes"
    }

    # 3. limit_except en location / (bloquear metodos no permitidos -> 403)
    if ($c -notmatch 'limit_except') {
        $c = $c -replace '(location\s*/\s*\{)', "`$1`n            limit_except GET POST HEAD {`n                deny all;`n            }"
        Write-OK "Nginx: limit_except GET|POST|HEAD agregado en location / (resto -> 403)"
    } else {
        Write-Inf "Nginx: limit_except ya presente"
    }

    Set-Content $conf $c -Encoding UTF8
}

function HTTP-AplicarSeguridad {
    param([string]$Svc, [string]$Puerto)
    Write-Inf "Aplicando seguridad para $Svc..."
    switch ($Svc) {
        "iis"    { _HTTP-SeguridadIIS    $Puerto }
        "apache" { _HTTP-SeguridadApache $Puerto }
        "nginx"  { _HTTP-SeguridadNginx  $Puerto }
        default  { Write-Wrn "Seguridad no implementada para: $Svc" }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# USUARIO DEDICADO CON PERMISOS LIMITADOS AL WEBROOT
# ─────────────────────────────────────────────────────────────────────────────
function _HTTP-UsuarioDedicado {
    param([string]$Svc, [string]$Webroot)

    $usuario = switch ($Svc) {
        "iis"    { "IIS AppPool\DefaultAppPool" }
        "apache" { "apache-svc" }
        "nginx"  { "nginx-svc"  }
        default  { "http-svc"   }
    }

    # Para IIS el AppPool ya existe; para Apache/Nginx crear usuario local
    if ($Svc -ne "iis") {
        if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
            $pass = ConvertTo-SecureString "Svc@$(Get-Random -Maximum 9999)!" -AsPlainText -Force
            New-LocalUser -Name $usuario -Password $pass `
                -Description "Usuario dedicado para $Svc HTTP" `
                -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
            # Sin acceso interactivo
            Add-LocalGroupMember -Group "Guests" -Member $usuario -ErrorAction SilentlyContinue
            Write-OK "Usuario dedicado '$usuario' creado"
        } else {
            Write-Inf "Usuario '$usuario' ya existe"
        }
    }

    # ACLs NTFS: solo lectura para el usuario de servicio en el webroot
    if (Test-Path $Webroot) {
        $acl  = Get-Acl $Webroot
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $usuario, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl $Webroot $acl -ErrorAction SilentlyContinue
        Write-OK "ACL NTFS: $usuario -> ReadAndExecute en $Webroot"
    }
    return $usuario
}

# ─────────────────────────────────────────────────────────────────────────────
# CREAR INDEX.HTML PERSONALIZADO
# ─────────────────────────────────────────────────────────────────────────────
function _HTTP-CrearIndex {
    param([string]$Svc, [string]$Version, [string]$Puerto, [string]$Webroot, [string]$Usuario)

    New-Item -ItemType Directory -Path $Webroot -Force | Out-Null
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>$Svc</title>
    <style>
        body { font-family: monospace; background: #1a1a2e; color: #eee;
               display: flex; justify-content: center; align-items: center;
               height: 100vh; margin: 0; }
        .box { border: 2px solid #00d4ff; padding: 2rem 3rem; text-align: center; }
        h1   { color: #00d4ff; margin: 0 0 1rem; }
        p    { margin: 0.3rem 0; }
    </style>
</head>
<body>
    <div class="box">
        <h1>Servidor HTTP - Windows Server</h1>
        <p>Servidor desplegado exitosamente</p>
        <p>Servidor : <strong>$Svc</strong></p>
        <p>Version  : <strong>$Version</strong></p>
        <p>Puerto   : <strong>$Puerto</strong></p>
        <p>Webroot  : <strong>$Webroot</strong></p>
        <p>Usuario  : <strong>$Usuario</strong></p>
    </div>
</body>
</html>
"@
    Set-Content -Path "$Webroot\index.html" -Value $html -Encoding UTF8
    Write-OK "index.html generado en: $Webroot"
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER INTERNO: instala y configura UN servicio Windows con version y puerto decididos
# ─────────────────────────────────────────────────────────────────────────────
function _HTTP-InstalarUno {
    param([string]$Svc, [string]$Version, [string]$Puerto)

    Write-Inf "Instalando $Svc $Version en puerto $Puerto..."

    switch ($Svc) {
        "iis" {
            $features = @(
                "Web-Server","Web-Common-Http","Web-Static-Content",
                "Web-Default-Doc","Web-Http-Errors","Web-Security",
                "Web-Filtering","Web-Stat-Compression","Web-Mgmt-Console"
            )
            foreach ($f in $features) {
                Install-WindowsFeature -Name $f -ErrorAction SilentlyContinue | Out-Null
            }
            Write-OK "IIS instalado/verificado"
            $iisDefault = "C:\inetpub\wwwroot\iisstart.htm"
            if (Test-Path $iisDefault) {
                Rename-Item $iisDefault "$iisDefault.bak" -ErrorAction SilentlyContinue
                Write-OK "IIS: pagina default deshabilitada (iisstart.htm -> .bak)"
            }
        }
        "apache" {
            if (_HTTP-VerificarChoco) {
                $verLimpia = ($Version -split ' ')[0]
                Write-Inf "Instalando Apache via Chocolatey (puede tardar)..."
                choco install apache-httpd --version=$verLimpia -y --no-progress 2>&1 | Out-Null
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                            [System.Environment]::GetEnvironmentVariable("Path","User")
                $svcYaExiste = $false
                foreach ($sn in @("Apache2.4","Apache24","Apache2","ApacheHTTPServer","httpd")) {
                    if (Get-Service $sn -ErrorAction SilentlyContinue) { $svcYaExiste = $true; break }
                }
                if ($svcYaExiste) {
                    Write-OK "Chocolatey registro el servicio Apache automaticamente"
                } else {
                    $httpdExe = $null
                    foreach ($pat in @(
                        "C:\Apache24\bin\httpd.exe",
                        "C:\Apache*\bin\httpd.exe",
                        "C:\ProgramData\chocolatey\lib\apache-httpd*\tools\Apache*\bin\httpd.exe"
                    )) {
                        $f = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($f) { $httpdExe = $f; break }
                    }
                    if ($httpdExe) {
                        Write-Inf "Registrando servicio Apache: $($httpdExe.FullName)"
                        & $httpdExe.FullName -k install -n "Apache2.4" 2>&1 | Out-Null
                        Write-OK "Apache: servicio 'Apache2.4' registrado"
                    } else {
                        Write-Wrn "No se encontro httpd.exe — puede haberse registrado con otro nombre"
                    }
                }
            }
        }
        "nginx" {
            if (_HTTP-VerificarChoco) {
                $verLimpia = ($Version -split ' ')[0]
                Write-Inf "Instalando Nginx via Chocolatey (puede tardar)..."
                choco install nginx --version=$verLimpia -y --no-progress 2>&1 | Out-Null
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                            [System.Environment]::GetEnvironmentVariable("Path","User")
                if (Get-Service "nginx" -ErrorAction SilentlyContinue) {
                    Write-OK "Chocolatey registro el servicio nginx automaticamente"
                } else {
                    $nginxExe = $null
                    foreach ($pat in @(
                        "C:\nginx\nginx.exe",
                        "C:\nginx*\nginx.exe",
                        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\nginx.exe",
                        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx\nginx.exe"
                    )) {
                        $f = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($f) { $nginxExe = $f; break }
                    }
                    if ($nginxExe) {
                        $nginxDir = Split-Path $nginxExe.FullName
                        Write-Inf "Registrando servicio Nginx desde: $nginxDir"
                        sc.exe create nginx binPath= "`"$($nginxExe.FullName)`"" `
                               start= auto DisplayName= "Nginx Web Server" 2>&1 | Out-Null
                        Write-OK "Nginx: servicio 'nginx' registrado"
                    } else {
                        Write-Wrn "No se encontro nginx.exe — puede haberse registrado con otro nombre"
                    }
                }
            }
        }
    }

    Write-Inf "Configurando puerto $Puerto ..."
    _HTTP-AplicarPuerto $Svc $Puerto

    $webroot = _HTTP-Webroot $Svc
    $usuario = _HTTP-UsuarioDedicado $Svc $webroot
    HTTP-AplicarSeguridad $Svc $Puerto
    _HTTP-CrearIndex $Svc $Version $Puerto $webroot $usuario
    _HTTP-FwAbrir $Puerto

    $sd = _HTTP-NombreServicio $Svc
    try {
        Start-Service $sd -ErrorAction Stop
        Set-Service   $sd -StartupType Automatic
        Write-OK "$Svc iniciado (servicio: $sd)"
    } catch {
        Write-Wrn "No se pudo iniciar el servicio '$sd': $_"
    }

    _HTTP-GuardarEstado $Svc $Puerto $Version

    Start-Sleep 2
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$Puerto" -Method Head -UseBasicParsing -TimeoutSec 5
        Write-OK "Respuesta HTTP: $($resp.StatusCode)"
    } catch {
        Write-Wrn "No se pudo verificar aun (el servicio puede tardar unos segundos)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. INSTALAR + CONFIGURAR SERVICIOS HTTP (multi-servicio)
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Instalar {
    Write-Host ""
    Write-Host "=== Instalar servidor(es) HTTP (Windows) ==="
    Write-Host ""
    Write-Host "  Servicios disponibles:"
    Write-Host "    1) IIS  (Internet Information Services)"
    Write-Host "    2) Apache Win64 (via Chocolatey)"
    Write-Host "    3) Nginx para Windows (via Chocolatey)"
    Write-Host ""
    Write-Host "  Puede instalar uno o varios (ejemplos: 1 / 2 3 / 1 2 3):"
    Write-Host ""

    $svcsInstalar = @()
    while ($true) {
        $sel = Read-Host "  Seleccion"
        $svcsInstalar = @()
        $ok = $true
        foreach ($n in ($sel -split '\s+' | Where-Object { $_ -ne '' })) {
            switch ($n) {
                "1" { $svcsInstalar += "iis"    }
                "2" { $svcsInstalar += "apache" }
                "3" { $svcsInstalar += "nginx"  }
                default { Write-Wrn "Opcion invalida: $n"; $ok = $false; break }
            }
        }
        if ($ok -and $svcsInstalar.Count -gt 0) { break }
    }

    _HTTP-LeerEstado

    # Detener servicios huerfanos (no gestionados y no en la lista a instalar)
    $targetSds = @()
    foreach ($s in $svcsInstalar) { $targetSds += _HTTP-NombreServicio $s }
    foreach ($s in $HTTP_ACTIVE_SVCS) { $targetSds += _HTTP-NombreServicio $s }
    foreach ($orphan in @("W3SVC","Apache2.4","Apache24","Apache2","ApacheHTTPServer","nginx")) {
        if ($targetSds -contains $orphan) { continue }
        $o = Get-Service $orphan -ErrorAction SilentlyContinue
        if ($o -and $o.Status -eq "Running") {
            Write-Inf "Servicio huerfano: $orphan — deteniendolo..."
            try { Stop-Service $orphan -Force; Set-Service $orphan -StartupType Disabled } catch {}
            Write-OK "$orphan detenido."
        }
    }

    # Recopilar version y puerto para cada servicio
    $versiones = @{}
    $puertos   = @{}
    $defaultPorts = @{ "iis" = "80"; "apache" = "8080"; "nginx" = "8081" }

    foreach ($svc in $svcsInstalar) {
        Write-Host ""
        Write-Host "  -- Configurando $svc --"
        if ($HTTP_SVCS_PUERTOS.ContainsKey($svc)) {
            Write-Wrn "$svc ya esta activo en puerto $($HTTP_SVCS_PUERTOS[$svc])."
            $rein = Read-Host "  Reinstalar? [s/N]"
            if ($rein -ne "s") { continue }
        }
        $ver = _HTTP-SeleccionarVersion $svc
        if (-not $ver) { Write-Wrn "Sin versiones para $svc — omitiendo"; continue }
        $versiones[$svc] = $ver
        Write-Host ""
        $pto = _HTTP-PedirPuerto $defaultPorts[$svc] $svc
        $puertos[$svc] = $pto
    }

    # Instalar cada servicio configurado
    foreach ($svc in $svcsInstalar) {
        if (-not $versiones.ContainsKey($svc)) { continue }
        Write-Host ""
        Write-Host "  ════════════════════════════════════════════"
        Write-Host "  Instalando $svc $($versiones[$svc]) en puerto $($puertos[$svc])"
        Write-Host "  ════════════════════════════════════════════"
        _HTTP-InstalarUno $svc $versiones[$svc] $puertos[$svc]
    }

    Write-Host ""
    Write-OK "============================================="
    foreach ($svc in $svcsInstalar) {
        if ($versiones.ContainsKey($svc)) {
            Write-OK " $svc $($versiones[$svc]) instalado en puerto $($puertos[$svc])"
        }
    }
    Write-OK "============================================="
    Write-Host ""
    foreach ($svc in $svcsInstalar) {
        if ($puertos.ContainsKey($svc)) {
            Write-Inf "  http://localhost:$($puertos[$svc])"
        }
    }
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. DESINSTALAR SERVICIO
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Desinstalar {
    param([string]$Svc = "")
    if ([string]::IsNullOrEmpty($Svc)) {
        $Svc = _HTTP-SeleccionarActivo
        if (-not $Svc) { Pausar; return }
    }

    Write-Inf "Desinstalando $Svc..."
    $sd = _HTTP-NombreServicio $Svc
    Stop-Service $sd -Force -ErrorAction SilentlyContinue

    switch ($Svc) {
        "iis" {
            Uninstall-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue | Out-Null
            Write-OK "IIS desinstalado"
        }
        "apache" {
            if (_HTTP-VerificarChoco) { choco uninstall apache-httpd -y 2>&1 | Out-Null }
            Write-OK "Apache desinstalado"
        }
        "nginx" {
            if (_HTTP-VerificarChoco) { choco uninstall nginx -y 2>&1 | Out-Null }
            Write-OK "Nginx desinstalado"
        }
    }

    $puerto = _HTTP-PuertoDeServicio $Svc
    if ($puerto) { _HTTP-FwCerrar $puerto }
    _HTTP-EliminarEstado $Svc
    Write-OK "$Svc desinstalado."
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CAMBIAR PUERTO (edge case)
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-CambiarPuerto {
    Write-Host ""
    Write-Host "=== Cambiar puerto del servicio HTTP ==="
    Write-Host ""

    $svc = _HTTP-SeleccionarActivo
    if (-not $svc) { Pausar; return }

    _HTTP-LeerEstado
    $puertoActual = $HTTP_SVCS_PUERTOS[$svc]
    $version      = $HTTP_SVCS_VERSIONES[$svc]

    Write-Inf "Servicio: $svc  |  Puerto actual: $puertoActual"
    Write-Host ""

    $nuevoPuerto = _HTTP-PedirPuerto $puertoActual $svc
    if ($nuevoPuerto -eq $puertoActual) {
        Write-Wrn "El nuevo puerto es igual al actual. Sin cambios."
        Pausar; return
    }

    Write-Host ""
    Write-Wrn "Esto cerrara el puerto $puertoActual y abrira el $nuevoPuerto."
    $confirm = Read-Host "  Confirmar cambio? [s/N]"
    if ($confirm -ne "s") { Write-Inf "Operacion cancelada."; Pausar; return }

    _HTTP-AplicarPuerto $svc $nuevoPuerto

    $webroot = _HTTP-Webroot $svc
    $usuario = _HTTP-UsuarioDedicado $svc $webroot
    _HTTP-CrearIndex $svc $version $nuevoPuerto $webroot $usuario

    _HTTP-FwCerrar $puertoActual
    _HTTP-FwAbrir  $nuevoPuerto

    $sd = _HTTP-NombreServicio $svc
    try {
        Restart-Service $sd -ErrorAction Stop
        Write-OK "$svc reiniciado"
    } catch {
        Write-Err "$svc NO pudo reiniciarse: $_"
    }

    _HTTP-GuardarEstado $svc $nuevoPuerto $version
    Write-OK "Puerto cambiado: $puertoActual -> $nuevoPuerto"
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CAMBIAR DE SERVICIO WEB
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-CambiarServicio {
    Write-Host ""
    Write-Host "=== Agregar o reemplazar servicio web ==="
    Write-Host ""
    _HTTP-LeerEstado

    if ($HTTP_ACTIVE_SVCS.Count -eq 0) {
        Write-Inf "No hay servicio activo. Redirigiendo a instalacion..."
        Start-Sleep 1; HTTP-Instalar; return
    }

    Write-Host "  Servicios activos: $($HTTP_ACTIVE_SVCS -join ', ')"
    Write-Host "  1) Agregar nuevo servicio (mantener los existentes)"
    Write-Host "  2) Reemplazar un servicio existente"
    Write-Host ""
    $opc = Read-Host "  Opcion [1/2]"
    if ($opc -eq "2") {
        $svc = _HTTP-SeleccionarActivo
        if (-not $svc) { Pausar; return }
        Write-Wrn "Esto desinstalara $svc completamente."
        $confirm = Read-Host "  Continuar? [s/N]"
        if ($confirm -ne "s") { Write-Inf "Cancelado."; Pausar; return }
        HTTP-Desinstalar $svc
        Start-Sleep 1
    }
    HTTP-Instalar
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. MONITOREO
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Monitoreo {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "----------------------------------------------"
        Write-Host "            MONITOREO HTTP (Windows)          "
        Write-Host "----------------------------------------------"
        Write-Host "  1. Estado de servicios HTTP"
        Write-Host "  2. Puertos en uso"
        Write-Host "  3. Puertos NO accesibles (cerrados)"
        Write-Host "  4. Logs / ultimos errores"
        Write-Host "  5. Configuracion y estatus actual"
        Write-Host "  6. Auditoria de seguridad (headers + metodos)"
        Write-Host "  0. Volver"
        Write-Host "----------------------------------------------"
        $opc = Read-Host "  Opcion"
        switch ($opc) {
            "1" { _HTTP-MonEstado     }
            "2" { _HTTP-MonPuertos    }
            "3" { _HTTP-MonCerrados   }
            "4" { _HTTP-MonLogs       }
            "5" { _HTTP-MonConfig     }
            "6" { _HTTP-MonAuditoria  }
            "0" { return }
            default { Write-Wrn "Opcion invalida."; Start-Sleep 1 }
        }
    }
}

function _HTTP-MonEstado {
    Write-Host ""
    Write-Host "=== Estado de servicios HTTP ==="
    Write-Host ""
    foreach ($sd in @("W3SVC", "Apache2.4", "nginx")) {
        $svc = Get-Service $sd -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq "Running") { Write-OK  "$sd : ACTIVO" }
            else                           { Write-Wrn "$sd : $($svc.Status)" }
        }
    }
    Write-Host ""
    _HTTP-LeerEstado
    if ($HTTP_SVC) {
        Write-Inf "Servicio gestionado: $HTTP_SVC  |  Puerto: $HTTP_PUERTO  |  Version: $HTTP_VERSION"
    }
    Pausar
}

function _HTTP-MonPuertos {
    Write-Host ""
    Write-Host "=== Puertos TCP en escucha ==="
    Write-Host ""
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in @(80,8080,8888,443,3000,5000) + (1024..65535 | Select-Object -First 0) } |
        Sort-Object LocalPort |
        ForEach-Object {
            $proc = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name
            Write-Host ("    Puerto {0,-6} PID {1,-6} Proceso: {2}" -f $_.LocalPort, $_.OwningProcess, $proc)
        }
    Pausar
}

function _HTTP-MonCerrados {
    Write-Host ""
    Write-Host "=== Puertos HTTP comunes ==="
    Write-Host ""
    foreach ($p in @(80, 8080, 8888, 443, 3000)) {
        if (_HTTP-PuertoEnUso $p) { Write-OK  "Puerto $p : ABIERTO (en uso)" }
        else                      { Write-Wrn "Puerto $p : CERRADO / no en uso" }
    }
    Pausar
}

function _HTTP-MonLogs {
    Write-Host ""
    Write-Host "=== Ultimos errores ==="
    Write-Host ""
    $svcLog = _HTTP-SeleccionarActivo
    if (-not $svcLog) { Pausar; return }
    switch ($svcLog) {
        "iis" {
            $logDir = "C:\inetpub\logs\LogFiles"
            $logFile = Get-ChildItem $logDir -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime | Select-Object -Last 1
            if ($logFile) {
                Write-Inf "Log IIS: $($logFile.FullName)"
                Get-Content $logFile.FullName -Tail 15 | ForEach-Object { Write-Host "    $_" }
            }
        }
        "apache" {
            $log = Get-Item "C:\Apache*\logs\error.log" -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if (-not $log) {
                $log = Get-ChildItem "C:\ProgramData\chocolatey\lib\apache-httpd*\tools\Apache*\logs\error.log" `
                       -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($log) { Get-Content $log.FullName -Tail 15 | ForEach-Object { Write-Host "    $_" } }
            else { Write-Wrn "No se encontro error.log de Apache" }
        }
        "nginx" {
            $log = Get-Item "C:\nginx*\logs\error.log" -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if (-not $log) {
                $log = Get-ChildItem "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\logs\error.log" `
                       -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($log) { Get-Content $log.FullName -Tail 15 | ForEach-Object { Write-Host "    $_" } }
            else { Write-Wrn "No se encontro error.log de Nginx" }
        }
        default { Write-Wrn "No hay servicio activo registrado." }
    }
    Pausar
}

function _HTTP-MonAuditoria {
    Write-Host ""
    Write-Host "=== Auditoria de Seguridad HTTP ==="
    Write-Host ""
    $svc = _HTTP-SeleccionarActivo
    if (-not $svc) { Pausar; return }
    _HTTP-LeerEstado
    $HTTP_SVC    = $svc
    $HTTP_PUERTO = $HTTP_SVCS_PUERTOS[$svc]

    $url = "http://localhost:$HTTP_PUERTO"
    Write-Inf "Servicio: $HTTP_SVC  |  Puerto: $HTTP_PUERTO"
    Write-Inf "Probando: Invoke-WebRequest -Method Head $url"
    Write-Host ""

    # Capturar headers
    $hdrs = $null
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 5
        $hdrs = $resp.Headers
    } catch {
        Write-Err "No se pudo conectar a $url  -  servicio inactivo?"
        Pausar; return
    }

    # Helper local
    $checkHdr = {
        param($nombre, $clave)
        if ($hdrs.ContainsKey($clave)) {
            Write-OK  ("  {0,-28} PRESENTE -> {1}" -f $nombre, $hdrs[$clave])
        } else {
            Write-Wrn ("  {0,-28} AUSENTE" -f $nombre)
        }
    }

    Write-Host "  -- Headers de respuesta --"
    & $checkHdr "X-Frame-Options"       "X-Frame-Options"
    & $checkHdr "X-Content-Type-Options" "X-Content-Type-Options"
    & $checkHdr "X-XSS-Protection"      "X-XSS-Protection"
    & $checkHdr "Referrer-Policy"        "Referrer-Policy"
    Write-Host ""

    # Verificar que Server no exponga version exacta
    if ($hdrs.ContainsKey("Server")) {
        $srv = $hdrs["Server"]
        if ($srv -match "Apache/[0-9]|nginx/[0-9]|Tomcat/[0-9]|Microsoft-IIS/[0-9]") {
            Write-Wrn "  Server expone version: $srv  [INSEGURO - expone version]"
        } else {
            Write-OK  "  Server no expone version exacta -> $srv"
        }
    } else {
        Write-OK "  Header Server ausente (muy bueno)"
    }
    Write-Host ""

    # Verificar metodos HTTP
    Write-Host "  -- Metodos HTTP --"
    foreach ($method in @("TRACE","DELETE","PUT","GET")) {
        try {
            $r = Invoke-WebRequest -Uri $url -Method $method -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $code = $r.StatusCode
        } catch {
            # PowerShell lanza excepcion en 4xx/5xx  -  extraer codigo
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        }
        if ($method -eq "GET") {
            if ($code -in @(200,301,302)) { Write-OK  "  GET    funciona  (HTTP $code)" }
            else                          { Write-Wrn "  GET    NO funciona: HTTP $code" }
        } else {
            if ($code -in @(405,403,501)) { Write-OK  "  $method bloqueado (HTTP $code)" }
            else                          { Write-Wrn "  $method NO bloqueado: HTTP $code  [INSEGURO - expone version]" }
        }
    }
    Write-Host ""

    # Verificar regla de firewall
    Write-Host "  -- Firewall --"
    $fwRule = Get-NetFirewallRule -DisplayName "HTTP-Custom-$HTTP_PUERTO" -ErrorAction SilentlyContinue
    if ($fwRule) { Write-OK  "  Regla HTTP-Custom-$HTTP_PUERTO activa en Windows Firewall" }
    else         { Write-Wrn "  No se encontro regla HTTP-Custom-$HTTP_PUERTO en Windows Firewall" }
    Write-Host ""

    Pausar
}

function _HTTP-MonConfig {
    Write-Host ""
    Write-Host "=== Configuracion y estatus actual ==="
    Write-Host ""
    $svc = _HTTP-SeleccionarActivo
    if (-not $svc) { Pausar; return }
    _HTTP-LeerEstado
    $HTTP_SVC     = $svc
    $HTTP_PUERTO  = $HTTP_SVCS_PUERTOS[$svc]
    $HTTP_VERSION = $HTTP_SVCS_VERSIONES[$svc]

    Write-Inf "Servicio  : $HTTP_SVC"
    Write-Inf "Version   : $HTTP_VERSION"
    Write-Inf "Puerto    : $HTTP_PUERTO"
    Write-Inf "Webroot   : $(_HTTP-Webroot $HTTP_SVC)"
    Write-Host ""
    Write-Host "  Headers de respuesta:"
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$HTTP_PUERTO" -Method Head `
                               -UseBasicParsing -TimeoutSec 5
        $r.Headers.GetEnumerator() | ForEach-Object {
            Write-Host "    $($_.Key): $($_.Value)" -ForegroundColor Gray
        }
    } catch { Write-Wrn "    No se pudo conectar al servicio" }
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. REINICIAR SERVICIO ACTIVO
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Reiniciar {
    $svc = _HTTP-SeleccionarActivo
    if (-not $svc) { Pausar; return }

    $sd = _HTTP-NombreServicio $svc
    $svcObj = Get-Service $sd -ErrorAction SilentlyContinue
    if (-not $svcObj) {
        Write-Err "No se encontro el servicio '$sd' en el sistema."
        Write-Inf "Revisa: Get-Service | Where-Object { `$_.Name -like '*$svc*' }"
        Pausar; return
    }
    Write-Inf "Reiniciando $svc ($sd)..."
    try {
        Restart-Service $sd -ErrorAction Stop
        $svcObj.Refresh()
        if ($svcObj.Status -eq "Running") {
            Write-OK "$svc reiniciado correctamente."
        } else {
            Write-Wrn "$svc estado tras reinicio: $($svcObj.Status)"
        }
    } catch {
        Write-Err "$svc NO pudo reiniciarse: $_"
        Write-Inf "Revisa: Get-EventLog -LogName System -Source 'Service Control Manager' -Newest 5"
    }
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. VERIFICAR ESTADO RAPIDO
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Verificar {
    Write-Host ""
    Write-Host "=== Estado de servicios HTTP ==="
    Write-Host ""
    _HTTP-LeerEstado

    if ($HTTP_ACTIVE_SVCS.Count -eq 0) {
        Write-Wrn "No hay ningun servicio HTTP gestionado."
        Pausar; return
    }

    foreach ($svc in $HTTP_ACTIVE_SVCS) {
        $puerto  = $HTTP_SVCS_PUERTOS[$svc]
        $version = $HTTP_SVCS_VERSIONES[$svc]
        $sd = _HTTP-NombreServicio $svc
        $svcObj = Get-Service $sd -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Inf "Servicio : $svc  |  Version: $version  |  Puerto: $puerto"
        if ($svcObj -and $svcObj.Status -eq "Running") { Write-OK "$sd esta ACTIVO" }
        else { Write-Wrn "$sd esta INACTIVO" }
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$puerto" -Method Head `
                                   -UseBasicParsing -TimeoutSec 5
            Write-OK "HTTP $($r.StatusCode) - Respondiendo"
            $r.Headers.GetEnumerator() | Select-Object -First 4 |
                ForEach-Object { Write-Host "    $($_.Key): $($_.Value)" -ForegroundColor Gray }
        } catch { Write-Wrn "    No se pudo conectar a http://localhost:$puerto" }
    }
    Write-Host ""
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU DEL MODULO HTTP
# ─────────────────────────────────────────────────────────────────────────────
function Menu-HTTP {
    while ($true) {
        Clear-Host
        _HTTP-LeerEstado
        $infoActivo = if ($HTTP_ACTIVE_SVCS.Count -gt 0) {
            ($HTTP_ACTIVE_SVCS | ForEach-Object { "$_`:$($HTTP_SVCS_PUERTOS[$_])" }) -join ', '
        } else { "(ninguno)" }
        Write-Host ""
        Write-Host "----------------------------------------------"
        Write-Host "       ADMINISTRACION SERVIDOR HTTP           "
        Write-Host "          IIS / Apache / Nginx                "
        Write-Host "----------------------------------------------"
        Write-Host "  Activo: $infoActivo"
        Write-Host "----------------------------------------------"
        Write-Host "  1. Verificar estado"
        Write-Host "  2. Instalar servicio web"
        Write-Host "  3. Cambiar puerto"
        Write-Host "  4. Cambiar a otro servicio"
        Write-Host "  5. Desinstalar servicio"
        Write-Host "  6. Reiniciar servicio"
        Write-Host "  7. Seguridad (aplicar/reforzar)"
        Write-Host "  8. Monitoreo"
        Write-Host "  0. Volver"
        Write-Host "----------------------------------------------"
        $opc = Read-Host "  Opcion"
        switch ($opc) {
            "1" { HTTP-Verificar      }
            "2" { HTTP-Instalar       }
            "3" { HTTP-CambiarPuerto  }
            "4" { HTTP-CambiarServicio }
            "5" { HTTP-Desinstalar    }
            "6" { HTTP-Reiniciar }
            "7" {
                $secSvc = _HTTP-SeleccionarActivo
                if ($secSvc) {
                    _HTTP-LeerEstado
                    $secPuerto = $HTTP_SVCS_PUERTOS[$secSvc]
                    HTTP-AplicarSeguridad $secSvc $secPuerto
                    $sd = _HTTP-NombreServicio $secSvc
                    try {
                        Restart-Service $sd -ErrorAction Stop
                        Write-OK "Seguridad aplicada y servicio reiniciado."
                    } catch {
                        Write-Err "Seguridad aplicada pero el servicio NO pudo reiniciarse: $_"
                    }
                }
                Pausar
            }
            "8" { HTTP-Monitoreo }
            "0" { return }
            default { Write-Wrn "Opcion invalida."; Start-Sleep 1 }
        }
    }
}
