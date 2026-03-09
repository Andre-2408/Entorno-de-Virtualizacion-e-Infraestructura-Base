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
function _HTTP-NombreServicio {
    param([string]$Svc)
    switch ($Svc) {
        "iis"     { return "W3SVC" }
        "apache"  { return "Apache2.4" }
        "nginx"   { return "nginx" }
        default   { return $Svc }
    }
}

# Webroot segun el servidor
function _HTTP-Webroot {
    param([string]$Svc)
    switch ($Svc) {
        "iis"    { return "C:\inetpub\wwwroot" }
        "apache" {
            $ap = Get-Item "C:\Apache*\htdocs" -ErrorAction SilentlyContinue | Select-Object -First 1
            return if ($ap) { $ap.FullName } else { "C:\Apache24\htdocs" }
        }
        "nginx"  {
            # Chocolatey instala nginx en ProgramData o directamente en C:\nginx
            $ng = Get-ChildItem "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\html" `
                                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ng) { return $ng.FullName }
            $ng = Get-Item "C:\nginx*\html" -ErrorAction SilentlyContinue | Select-Object -First 1
            return if ($ng) { $ng.FullName } else { "C:\nginx\html" }
        }
    }
}

# Guarda estado activo en archivo ps1 sourceable
function _HTTP-GuardarEstado {
    param([string]$Svc, [string]$Puerto, [string]$Version)
    New-Item -ItemType Directory -Path (Split-Path $HTTP_STATE_FILE) -Force | Out-Null
    @"
`$HTTP_SVC     = "$Svc"
`$HTTP_PUERTO  = "$Puerto"
`$HTTP_VERSION = "$Version"
"@ | Set-Content $HTTP_STATE_FILE -Encoding UTF8
}

# Carga estado guardado — escribe en $script: para que persistan al llamador
function _HTTP-LeerEstado {
    $script:HTTP_SVC     = ""
    $script:HTTP_PUERTO  = ""
    $script:HTTP_VERSION = ""
    if (Test-Path $HTTP_STATE_FILE) {
        Get-Content $HTTP_STATE_FILE | ForEach-Object {
            if ($_ -match '^\$HTTP_SVC\s*=\s*"(.*)"')     { $script:HTTP_SVC     = $Matches[1] }
            if ($_ -match '^\$HTTP_PUERTO\s*=\s*"(.*)"')  { $script:HTTP_PUERTO  = $Matches[1] }
            if ($_ -match '^\$HTTP_VERSION\s*=\s*"(.*)"') { $script:HTTP_VERSION = $Matches[1] }
        }
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
    $raw = choco list $Paquete --all-versions --exact 2>$null |
           Where-Object { $_ -match "^$Paquete\s" } |
           ForEach-Object { ($_ -split '\s+')[1] }
    return $raw | Sort-Object { [version]($_ -replace '[^0-9.]','') } -ErrorAction SilentlyContinue
}

# Devuelve version instalada de IIS
function _HTTP-VersionIIS {
    try {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction Stop).MajorVersion
        $mv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction Stop).MinorVersion
        return "$v.$mv"
    } catch { return "desconocida" }
}

# Menu de seleccion de version — devuelve la elegida
function _HTTP-SeleccionarVersion {
    param([string]$Svc)
    $versiones = @()

    Write-Inf "Consultando versiones disponibles de '$Svc'..."

    switch ($Svc) {
        "iis" {
            # IIS se instala via Windows Features — la version depende del SO
            $v = _HTTP-VersionIIS
            $versiones = @("$v (instalada en este servidor)")
        }
        "apache" {
            $versiones = @(_HTTP-VersionesChoco "apache-httpd")
            if ($versiones.Count -eq 0) {
                # Fallback: winget
                Write-Inf "Intentando con winget..."
                $versiones = @(
                    winget search "Apache HTTP Server" --source winget 2>$null |
                    Where-Object { $_ -match 'Apache' } |
                    ForEach-Object { ($_ -split '\s+') | Select-Object -Last 1 } |
                    Where-Object { $_ -match '^\d' }
                )
            }
        }
        "nginx" {
            $versiones = @(_HTTP-VersionesChoco "nginx")
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
    $conf = Get-Item "C:\Apache*\conf\httpd.conf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conf) { Write-Wrn "No se encontro httpd.conf de Apache"; return }
    (Get-Content $conf.FullName) -replace 'Listen \d+', "Listen $Puerto" |
        Set-Content $conf.FullName -Encoding UTF8
    Write-OK "Apache: puerto actualizado a $Puerto en $($conf.FullName)"
}

function _HTTP-AplicarPuertoNginx {
    param([string]$Puerto)
    $conf = Get-Item "C:\nginx*\conf\nginx.conf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conf) { Write-Wrn "No se encontro nginx.conf"; return }
    (Get-Content $conf.FullName) -replace 'listen\s+\d+', "listen $Puerto" |
        Set-Content $conf.FullName -Encoding UTF8
    Write-OK "Nginx: puerto actualizado a $Puerto en $($conf.FullName)"
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
    $confDir = Get-Item "C:\nginx*\conf" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $confDir) { Write-Wrn "No se encontro conf de Nginx"; return }
    $conf = "$($confDir.FullName)\nginx.conf"
    if (Test-Path $conf) {
        $c = Get-Content $conf -Raw
        if ($c -notmatch 'server_tokens') {
            $c = $c -replace 'http \{', "http {`n    server_tokens off;"
        }
        Set-Content $conf $c -Encoding UTF8
        Write-OK "Nginx: server_tokens off aplicado"
    }

    # Archivo de security headers
    $secFile = "$($confDir.FullName)\security-headers.conf"
    @'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
if ($request_method !~ ^(GET|POST|HEAD)$) { return 405; }
'@ | Set-Content $secFile -Encoding UTF8
    Write-OK "Nginx: security-headers.conf generado"
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
                -PasswordNeverExpires $true -UserMayNotChangePassword $true | Out-Null
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
# 1. INSTALAR + CONFIGURAR SERVICIO HTTP
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Instalar {
    Write-Host ""
    Write-Host "=== Instalar servidor HTTP (Windows) ==="
    Write-Host ""
    Write-Host "  Servicios disponibles:"
    Write-Host "    1) IIS  (Internet Information Services)"
    Write-Host "    2) Apache Win64 (via Chocolatey)"
    Write-Host "    3) Nginx para Windows (via Chocolatey)"
    Write-Host ""

    $svc = ""
    while ($true) {
        $opc = Read-Host "  Seleccione servicio [1-3]"
        switch ($opc) {
            "1" { $svc = "iis";    break }
            "2" { $svc = "apache"; break }
            "3" { $svc = "nginx";  break }
            default { Write-Wrn "Opcion invalida." }
        }
        if ($svc -ne "") { break }
    }

    # Avisar si ya hay un servicio activo diferente
    _HTTP-LeerEstado
    if ($HTTP_SVC -and $HTTP_SVC -ne $svc) {
        Write-Wrn "Ya hay un servicio activo: $HTTP_SVC (puerto $HTTP_PUERTO)"
        $confirm = Read-Host "  Desea reemplazarlo con $svc? [s/N]"
        if ($confirm -ne "s") { Write-Inf "Instalacion cancelada."; Pausar; return }
        HTTP-Desinstalar $HTTP_SVC
    }

    # Paso 2: Version
    $version = _HTTP-SeleccionarVersion $svc
    if (-not $version) { Pausar; return }

    # Paso 3: Puerto
    Write-Host ""
    $puerto = _HTTP-PedirPuerto "80" $svc

    # Paso 4: Instalar
    Write-Host ""
    Write-Inf "Instalando $svc $version ..."
    switch ($svc) {
        "iis" {
            $features = @(
                "Web-Server", "Web-Common-Http", "Web-Static-Content",
                "Web-Default-Doc", "Web-Http-Errors", "Web-Security",
                "Web-Filtering", "Web-Stat-Compression", "Web-Mgmt-Console"
            )
            foreach ($f in $features) {
                Install-WindowsFeature -Name $f -ErrorAction SilentlyContinue | Out-Null
            }
            Write-OK "IIS instalado/verificado"
        }
        "apache" {
            if (_HTTP-VerificarChoco) {
                $verLimpia = ($version -split ' ')[0]
                Write-Inf "Instalando Apache via Chocolatey (puede tardar)..."
                choco install apache-httpd --version=$verLimpia -y --no-progress 2>&1 | Out-Null
                # Chocolatey instala Apache pero NO registra el servicio automaticamente
                # Hay que buscarlo y ejecutar httpd.exe -k install
                $httpdExe = Get-ChildItem "C:\Apache*\bin\httpd.exe" -ErrorAction SilentlyContinue |
                            Select-Object -First 1
                if (-not $httpdExe) {
                    # Buscar en ruta de Chocolatey
                    $httpdExe = Get-ChildItem "C:\ProgramData\chocolatey\lib\apache-httpd*\tools\Apache*\bin\httpd.exe" `
                                -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if ($httpdExe) {
                    Write-Inf "Registrando servicio Apache: $($httpdExe.FullName)"
                    & $httpdExe.FullName -k install -n "Apache2.4" 2>&1 | Out-Null
                    Write-OK "Apache instalado y servicio 'Apache2.4' registrado"
                } else {
                    Write-Wrn "No se encontro httpd.exe — verifica la instalacion de Chocolatey"
                }
            }
        }
        "nginx" {
            if (_HTTP-VerificarChoco) {
                $verLimpia = ($version -split ' ')[0]
                Write-Inf "Instalando Nginx via Chocolatey (puede tardar)..."
                choco install nginx --version=$verLimpia -y --no-progress 2>&1 | Out-Null
                # Nginx en Windows no crea servicio via Chocolatey — crearlo con sc.exe
                $nginxExe = Get-ChildItem "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*\nginx.exe" `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $nginxExe) {
                    $nginxExe = Get-ChildItem "C:\nginx*\nginx.exe" -ErrorAction SilentlyContinue |
                                Select-Object -First 1
                }
                if ($nginxExe) {
                    $nginxDir = Split-Path $nginxExe.FullName
                    Write-Inf "Registrando servicio Nginx desde: $nginxDir"
                    $svcExist = Get-Service "nginx" -ErrorAction SilentlyContinue
                    if (-not $svcExist) {
                        sc.exe create nginx binPath= "`"$($nginxExe.FullName)`" -p `"$nginxDir`"" `
                               start= auto DisplayName= "Nginx Web Server" 2>&1 | Out-Null
                    }
                    Write-OK "Nginx instalado y servicio 'nginx' registrado"
                } else {
                    Write-Wrn "No se encontro nginx.exe — verifica la instalacion de Chocolatey"
                }
            }
        }
    }

    # Paso 4.5: Deshabilitar pagina default de IIS
    if ($svc -eq "iis") {
        $iisDefault = "C:\inetpub\wwwroot\iisstart.htm"
        if (Test-Path $iisDefault) {
            Rename-Item $iisDefault "$iisDefault.bak" -ErrorAction SilentlyContinue
            Write-OK "IIS: pagina default deshabilitada (iisstart.htm -> .bak)"
        }
    }

    # Paso 5: Puerto
    Write-Inf "Configurando puerto $puerto ..."
    _HTTP-AplicarPuerto $svc $puerto

    # Paso 6: Usuario dedicado + ACLs
    $webroot = _HTTP-Webroot $svc
    $usuario = _HTTP-UsuarioDedicado $svc $webroot

    # Paso 7: Seguridad
    HTTP-AplicarSeguridad $svc $puerto

    # Paso 8: index.html
    _HTTP-CrearIndex $svc $version $puerto $webroot $usuario

    # Paso 9: Firewall
    _HTTP-FwAbrir $puerto
    _HTTP-FwCerrarDefaults $puerto

    # Paso 10: Iniciar servicio
    $sd = _HTTP-NombreServicio $svc
    try {
        Start-Service $sd -ErrorAction Stop
        Set-Service  $sd -StartupType Automatic
        Write-OK "$svc iniciado (servicio: $sd)"
    } catch {
        Write-Wrn "No se pudo iniciar el servicio '$sd': $_"
    }

    # Guardar estado
    _HTTP-GuardarEstado $svc $puerto $version

    Write-Host ""
    Write-OK "============================================="
    Write-OK " $svc $version instalado en puerto $puerto"
    Write-OK "============================================="
    Write-Host ""
    Write-Inf "Verificacion con curl:"
    Write-Host "    curl -I http://localhost:$puerto"
    Write-Host ""
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$puerto" -Method Head -UseBasicParsing -TimeoutSec 5
        Write-OK "Respuesta HTTP: $($resp.StatusCode) $($resp.StatusDescription)"
        $resp.Headers.GetEnumerator() | Select-Object -First 8 |
            ForEach-Object { Write-Host "    $($_.Key): $($_.Value)" -ForegroundColor Gray }
    } catch {
        Write-Wrn "No se pudo verificar aun (el servicio puede tardar unos segundos)"
    }
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. DESINSTALAR SERVICIO
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Desinstalar {
    param([string]$Svc = "")
    if ([string]::IsNullOrEmpty($Svc)) {
        _HTTP-LeerEstado
        $Svc = $HTTP_SVC
    }
    if ([string]::IsNullOrEmpty($Svc)) { Write-Wrn "No hay servicio activo."; Pausar; return }

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

    _HTTP-LeerEstado
    if ($HTTP_PUERTO) { _HTTP-FwCerrar $HTTP_PUERTO }
    Remove-Item $HTTP_STATE_FILE -ErrorAction SilentlyContinue
    Write-OK "$Svc desinstalado."
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CAMBIAR PUERTO (edge case)
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-CambiarPuerto {
    Write-Host ""
    Write-Host "=== Cambiar puerto del servicio HTTP ==="
    Write-Host ""
    _HTTP-LeerEstado
    if (-not $HTTP_SVC) { Write-Wrn "No hay servicio HTTP activo."; Pausar; return }

    Write-Inf "Servicio activo: $HTTP_SVC  |  Puerto actual: $HTTP_PUERTO"
    Write-Host ""

    $nuevoPuerto = _HTTP-PedirPuerto $HTTP_PUERTO $HTTP_SVC
    if ($nuevoPuerto -eq $HTTP_PUERTO) {
        Write-Wrn "El nuevo puerto es igual al actual. Sin cambios."
        Pausar; return
    }

    Write-Host ""
    Write-Wrn "Esto cerrara el puerto $HTTP_PUERTO y abrira el $nuevoPuerto."
    $confirm = Read-Host "  Confirmar cambio? [s/N]"
    if ($confirm -ne "s") { Write-Inf "Operacion cancelada."; Pausar; return }

    _HTTP-AplicarPuerto $HTTP_SVC $nuevoPuerto

    $webroot = _HTTP-Webroot $HTTP_SVC
    $usuario = _HTTP-UsuarioDedicado $HTTP_SVC $webroot
    _HTTP-CrearIndex $HTTP_SVC $HTTP_VERSION $nuevoPuerto $webroot $usuario

    _HTTP-FwCerrar $HTTP_PUERTO
    _HTTP-FwAbrir  $nuevoPuerto

    $sd = _HTTP-NombreServicio $HTTP_SVC
    Restart-Service $sd -ErrorAction SilentlyContinue
    Write-OK "$HTTP_SVC reiniciado"

    _HTTP-GuardarEstado $HTTP_SVC $nuevoPuerto $HTTP_VERSION
    Write-OK "Puerto cambiado: $HTTP_PUERTO -> $nuevoPuerto"
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CAMBIAR DE SERVICIO WEB
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-CambiarServicio {
    Write-Host ""
    Write-Host "=== Cambiar servicio web ==="
    Write-Host ""
    _HTTP-LeerEstado
    if (-not $HTTP_SVC) {
        Write-Inf "No hay servicio activo. Redirigiendo a instalacion..."
        Start-Sleep 1; HTTP-Instalar; return
    }

    Write-Wrn "Servicio actual: $HTTP_SVC (puerto $HTTP_PUERTO)"
    Write-Wrn "Este proceso desinstalara $HTTP_SVC completamente."
    $confirm = Read-Host "  Continuar? [s/N]"
    if ($confirm -ne "s") { Write-Inf "Cancelado."; Pausar; return }

    HTTP-Desinstalar $HTTP_SVC
    Start-Sleep 1
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
        Write-Host "  0. Volver"
        Write-Host "----------------------------------------------"
        $opc = Read-Host "  Opcion"
        switch ($opc) {
            "1" { _HTTP-MonEstado   }
            "2" { _HTTP-MonPuertos  }
            "3" { _HTTP-MonCerrados }
            "4" { _HTTP-MonLogs     }
            "5" { _HTTP-MonConfig   }
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
    _HTTP-LeerEstado
    switch ($HTTP_SVC) {
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
            $log = Get-Item "C:\Apache*\logs\error.log" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($log) { Get-Content $log.FullName -Tail 15 | ForEach-Object { Write-Host "    $_" } }
        }
        "nginx" {
            $log = Get-Item "C:\nginx*\logs\error.log" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($log) { Get-Content $log.FullName -Tail 15 | ForEach-Object { Write-Host "    $_" } }
        }
        default { Write-Wrn "No hay servicio activo registrado." }
    }
    Pausar
}

function _HTTP-MonConfig {
    Write-Host ""
    Write-Host "=== Configuracion y estatus actual ==="
    Write-Host ""
    _HTTP-LeerEstado
    if (-not $HTTP_SVC) { Write-Wrn "No hay servicio HTTP gestionado."; Pausar; return }

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
# 6. VERIFICAR ESTADO RAPIDO
# ─────────────────────────────────────────────────────────────────────────────
function HTTP-Verificar {
    Write-Host ""
    Write-Host "=== Estado del servidor HTTP ==="
    Write-Host ""
    _HTTP-LeerEstado
    if (-not $HTTP_SVC) { Write-Wrn "No hay ningun servicio HTTP gestionado."; Pausar; return }

    $sd = _HTTP-NombreServicio $HTTP_SVC
    $svc = Get-Service $sd -ErrorAction SilentlyContinue
    Write-Inf "Servicio : $HTTP_SVC  |  Version: $HTTP_VERSION  |  Puerto: $HTTP_PUERTO"
    Write-Host ""
    if ($svc -and $svc.Status -eq "Running") { Write-OK "$sd esta ACTIVO" }
    else { Write-Wrn "$sd esta INACTIVO" }
    Write-Host ""
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$HTTP_PUERTO" -Method Head `
                               -UseBasicParsing -TimeoutSec 5
        Write-OK "HTTP $($r.StatusCode) - Servidor respondiendo"
        $r.Headers.GetEnumerator() | Select-Object -First 6 |
            ForEach-Object { Write-Host "    $($_.Key): $($_.Value)" -ForegroundColor Gray }
    } catch { Write-Wrn "No se pudo conectar a http://localhost:$HTTP_PUERTO" }
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU DEL MODULO HTTP
# ─────────────────────────────────────────────────────────────────────────────
function Menu-HTTP {
    while ($true) {
        Clear-Host
        _HTTP-LeerEstado
        $infoActivo = if ($HTTP_SVC) { "$HTTP_SVC v$HTTP_VERSION :$HTTP_PUERTO" } else { "(ninguno)" }
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
            "6" {
                _HTTP-LeerEstado
                if ($HTTP_SVC) {
                    $sd = _HTTP-NombreServicio $HTTP_SVC
                    Restart-Service $sd -ErrorAction SilentlyContinue
                    Write-OK "$HTTP_SVC reiniciado."
                } else { Write-Wrn "No hay servicio activo." }
                Pausar
            }
            "7" {
                _HTTP-LeerEstado
                if ($HTTP_SVC) {
                    HTTP-AplicarSeguridad $HTTP_SVC $HTTP_PUERTO
                    Restart-Service (_HTTP-NombreServicio $HTTP_SVC) -ErrorAction SilentlyContinue
                    Write-OK "Seguridad aplicada y servicio reiniciado."
                } else { Write-Wrn "No hay servicio activo." }
                Pausar
            }
            "8" { HTTP-Monitoreo }
            "0" { return }
            default { Write-Wrn "Opcion invalida."; Start-Sleep 1 }
        }
    }
}
