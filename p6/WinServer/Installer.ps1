#
# Installer.ps1
#
# Equivalente a Installer.sh de la practica Linux.
# Flujo encadenado:
#   Seleccion -> Versiones (choco) -> Puerto -> Instalacion -> Config -> Firewall
#
# Servicios: IIS (DISM), Apache Win64 (choco), Nginx (choco), Tomcat (choco)
#
# Funciones publicas:
#   http_seleccionar_servicio()     - Menu de seleccion (4 servicios)
#   http_consultar_versiones()      - Versiones disponibles via choco
#   http_seleccionar_version()      - Muestra versiones y captura eleccion
#   http_seleccionar_puerto()       - Captura y valida puerto de escucha
#   http_crear_usuario_dedicado()   - Usuario local sin login interactivo
#   http_crear_index()              - index.html personalizado por servicio
#   http_instalar_iis()             - Instalacion via DISM + WebAdministration
#   http_instalar_apache()          - Instalacion via choco
#   http_instalar_nginx()           - Instalacion via choco
#   http_instalar_tomcat()          - Instalacion via choco + Java
#   http_menu_instalar()            - Orquestador del flujo completo
#
# Requiere: CoreHelpers.ps1, HTTPGlobals.ps1, InputGuard.ps1, StatusCheck.ps1
#

#Requires -Version 5.1

function _http_seleccionar_servicio_instalado {
    $servicios = @(
        @{ Nombre = "IIS"; Interno = "iis"; WinSvc = $Script:HTTP_WINSVC_IIS }
        @{ Nombre = "Apache (httpd)"; Interno = "apache"; WinSvc = $Script:HTTP_WINSVC_APACHE }
        @{ Nombre = "Nginx"; Interno = "nginx"; WinSvc = $Script:HTTP_WINSVC_NGINX }
        @{ Nombre = "Tomcat"; Interno = "tomcat"; WinSvc = $Script:HTTP_WINSVC_TOMCAT }
    )

    # Filtrar solo los instalados y activos
    $instalados = @()
    foreach ($svc in $servicios) {
        $winSvcObj = Get-Service -Name $svc.WinSvc -ErrorAction SilentlyContinue
        if ($null -ne $winSvcObj) {
            $puerto = if ($winSvcObj.Status -eq 'Running') {
                _http_obtener_puerto_activo $svc.WinSvc
            }
            else { 0 }
            $chocoInfo = if ($svc.Interno -ne "iis") {
                choco list --local $svc.Interno 2>$null |
                Where-Object { $_ -match "^$($svc.Interno)\s" } |
                ForEach-Object { ($_ -split '\s+')[1] }
            }
            else { "instalado" }
            $estado = $winSvcObj.Status
            $instalados += @{ Svc = $svc; Version = $chocoInfo; Puerto = $puerto; Estado = $estado }
        }
    }

    if ($instalados.Count -eq 0) {
        aputs_error "No hay servicios HTTP instalados y activos"
        aputs_info  "Use la opcion 2) del menu principal para instalar un servicio"
        return ""
    }

    aputs_info "Servicios HTTP instalados:"
    for ($i = 0; $i -lt $instalados.Count; $i++) {
        $item = $instalados[$i]
        $verStr = if ($item.Version -and $item.Version -ne "instalado") { "v$($item.Version)" } elseif ($item.Version -eq "instalado") { "(instalado)" } else { "" }
        $estadoStr = if ($item.Estado -eq 'Running') { "${GREEN}activo${NC}" } else { "${YELLOW}$($item.Estado)${NC}" }
        Write-Host ("  ${BLUE}{0})${NC} {1,-20} {2,-15} {3}" -f ($i + 1), $item.Svc.Nombre, $verStr, $estadoStr)
    }
    Write-Host ""

    $opcion = ""
    do {
        $opcion = agets "Seleccione el servicio [1-$($instalados.Count)]"
    } while (-not (http_validar_opcion_menu $opcion $instalados.Count))

    return $instalados[[int]$opcion - 1].Svc.Interno
}

function _http_obtener_version_local {
    param([string]$Servicio)

    if ($Servicio -eq "iis") {
        $v = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
              -ErrorAction SilentlyContinue).VersionString
        if ($v) { return $v } else { return "instalado" }
    }

    $ver = $null

    switch ($Servicio) {

        "nginx" {
            # Fuente 1: nombre del directorio - nginx-1.17.2 -> "1.17.2"
            # HTTP_CONF_NGINX ya tiene la ruta real detectada al arrancar
            $confNginx = $Script:HTTP_CONF_NGINX
            if ($confNginx -and (Test-Path -LiteralPath $confNginx)) {
                $nginxDir = Split-Path (Split-Path $confNginx)
                if ((Split-Path $nginxDir -Leaf) -imatch "nginx[\-_]([\d\.]+)") {
                    $ver = $Matches[1]
                }
            }
            # Fuente 2: directorios nginx-X.Y.Z en C:\tools
            if (-not $ver -and (Test-Path "C:\tools")) {
                $d = Get-ChildItem "C:\tools" -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -imatch "^nginx[\-_][\d]" } |
                    Sort-Object Name -Descending | Select-Object -First 1
                if ($d -and $d.Name -imatch "nginx[\-_]([\d\.]+)") { $ver = $Matches[1] }
            }
            # Fuente 3: ProgramData\chocolatey\lib\nginx\tools
            if (-not $ver) {
                $cnt = "$env:ProgramData\chocolatey\lib\nginx\tools"
                if (Test-Path $cnt) {
                    $d = Get-ChildItem $cnt -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -imatch "^nginx[\-_][\d]" } |
                        Sort-Object Name -Descending | Select-Object -First 1
                    if ($d -and $d.Name -imatch "nginx[\-_]([\d\.]+)") { $ver = $Matches[1] }
                }
            }
        }

        "tomcat" {
            # Fuente 1: directorio apache-tomcat-X.Y.Z en chocolatey\lib\tomcat\tools
            $ctTools = "$env:ProgramData\chocolatey\lib\tomcat\tools"
            if (Test-Path $ctTools) {
                $d = Get-ChildItem $ctTools -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -imatch "^apache-tomcat" } |
                    Sort-Object Name -Descending | Select-Object -First 1
                if ($d -and $d.Name -imatch "apache-tomcat-([\d\.]+)") { $ver = $Matches[1] }
            }
            # Fuente 2: MANIFEST.MF de catalina.jar (Implementation-Version)
            if (-not $ver) {
                $catFound = Get-ChildItem "$env:ProgramData\chocolatey\lib\tomcat" `
                    -Filter catalina.jar -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1 | ForEach-Object { $_.FullName }
                if (-not $catFound) {
                    foreach ($p in @("C:\ProgramData\Tomcat9\lib\catalina.jar","C:\ProgramData\Tomcat10\lib\catalina.jar")) {
                        if (Test-Path -LiteralPath $p) { $catFound = $p; break }
                    }
                }
                if ($catFound) {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                    try {
                        $zip   = [System.IO.Compression.ZipFile]::OpenRead($catFound)
                        $entry = $zip.Entries | Where-Object { $_.FullName -match "MANIFEST.MF" } | Select-Object -First 1
                        if ($entry) {
                            $reader = New-Object System.IO.StreamReader($entry.Open())
                            $mf = $reader.ReadToEnd(); $reader.Close()
                            if ($mf -match "Implementation-Version:\s*([\d\.]+)") { $ver = $Matches[1] }
                        }
                        $zip.Dispose()
                    } catch { }
                }
            }
            # Fuente 3: FileVersion del exe (algunas versiones si lo populan)
            if (-not $ver) {
                foreach ($exe in @("C:\ProgramData\Tomcat9\bin\tomcat9.exe","C:\ProgramData\Tomcat10\bin\tomcat10.exe")) {
                    if (Test-Path -LiteralPath $exe) {
                        $fv = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
                        if ($fv -and $fv.Trim()) { $ver = $fv.Trim(); break }
                    }
                }
            }
        }

        "apache" {
            foreach ($exe in @(
                "$env:USERPROFILE\AppData\Roaming\Apache24\bin\httpd.exe",
                "$env:USERPROFILE\AppData\Roaming\Apache2.4\bin\httpd.exe",
                "C:\Apache24\bin\httpd.exe",
                "C:\tools\httpd\bin\httpd.exe"
            )) {
                if (Test-Path -LiteralPath $exe) {
                    $fv = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
                    if ($fv -and $fv.Trim()) { $ver = $fv.Trim(); break }
                }
            }
        }
    }

    # Fallback final: choco list (usando ruta absoluta por si no esta en PATH)
    if (-not $ver) {
        $chocoExe = if (Get-Command choco -ErrorAction SilentlyContinue) { "choco" }
                    else { "$env:ProgramData\chocolatey\bin\choco.exe" }
        $paquete = http_nombre_paquete $Servicio
        $ver = & $chocoExe list --local-only $paquete 2>$null |
            Where-Object { $_ -imatch "^$([regex]::Escape($paquete))\s" } |
            ForEach-Object { ($_ -split "\s+")[1].Trim() } |
            Select-Object -First 1
        if (-not $ver) {
            $ver = & $chocoExe list --local-only 2>$null |
                Where-Object { $_ -imatch "^$([regex]::Escape($Servicio))\s" } |
                ForEach-Object { ($_ -split "\s+")[1].Trim() } |
                Select-Object -First 1
        }
    }

    if ($ver) { return $ver } else { return "instalado" }
}

function http_seleccionar_servicio {
    Clear-Host
    http_draw_servicio_header "Selector de Servicio" "Paso 1 de 4"

    aputs_info "Servicios HTTP disponibles en Windows Server 2022:"
    Write-Host ""
    Write-Host "  ${BLUE}1)${NC} IIS (Internet Information Services)"
    Write-Host "      Servidor web nativo de Windows. Administrado con WebAdministration."
    Write-Host "      Instalacion via DISM  |  Usuario: IUSR  |  Puerto default: 80"
    Write-Host ""
    Write-Host "  ${BLUE}2)${NC} Apache HTTP Server (httpd)"
    Write-Host "      Servidor web clasico. Instalado via Chocolatey."
    Write-Host "      Paquete choco: apache-httpd  |  Usuario: apacheuser  |  Puerto default: 80"
    Write-Host ""
    Write-Host "  ${BLUE}3)${NC} Nginx"
    Write-Host "      Servidor web / proxy inverso. Instalado via Chocolatey."
    Write-Host "      Paquete choco: nginx  |  Usuario: nginxuser  |  Puerto default: 80"
    Write-Host ""
    Write-Host "  ${BLUE}4)${NC} Tomcat"
    Write-Host "      Servidor de aplicaciones Java. Requiere JDK instalado."
    Write-Host "      Paquete choco: tomcat  |  Puerto default: 8080"
    Write-Host ""

    $opcion = ""
    do {
        $opcion = agets "Seleccione el servicio [1-4]"
        if (-not (http_validar_opcion_menu $opcion 4)) {
            Write-Host ""
            $opcion = ""
        }
    } while ([string]::IsNullOrEmpty($opcion))

    $nombreServicio = switch ($opcion) {
        "1" { "iis" }
        "2" { "apache" }
        "3" { "nginx" }
        "4" { "tomcat" }
    }

    # Edge case: ya instalado - ofrecer reinstalar o reconfigurar
    $winsvc = http_nombre_winsvc $nombreServicio
    if (check_service_active $winsvc) {
        $chocoVer = _http_obtener_version_local $nombreServicio

        Write-Host ""
        aputs_warning "El servicio '$nombreServicio' ya esta instalado (v${chocoVer})"
        Write-Host ""
        Write-Host "  Opciones:"
        Write-Host "    1) Reinstalar (desinstala primero y vuelve a instalar)"
        Write-Host "    2) Solo reconfigurar (omite instalacion)"
        Write-Host "    3) Cancelar"
        Write-Host ""

        $opReinstalar = agets "Seleccione [1-3]"
        switch ($opReinstalar) {
            "1" { return "reinstalar:$nombreServicio" }
            "2" { return "reconfigurar:$nombreServicio" }
            default { return "cancelar" }
        }
    }

    return $nombreServicio
}

function http_consultar_versiones {
    param([string]$Servicio)

    $paquete = http_nombre_paquete $Servicio
    # <------------------------------------------------------------
    if ($Servicio -eq "iis") {
        # IIS no tiene versiones seleccionables via choco - usa la del sistema
        $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
                  -ErrorAction SilentlyContinue).VersionString
        return @("sistema ($iisVer)")
    }

    aputs_info "Consultando versiones disponibles de $paquete en Chocolatey..."
    Write-Host ""

    #  choco search --exact --all-versions 
    # --exact  : solo el paquete con ese nombre, sin coincidencias parciales
    # --all-versions : lista TODAS las versiones del repo, no solo la latest
    # 2>$null  : suprimir warnings de choco (ej: certificados, deprecaciones)
    $salidaRaw = choco search $paquete --exact --all-versions 2>$null

    # Fallback: choco list (Chocolatey < 2.0 usaba list en lugar de search)
    if (-not $salidaRaw -or $salidaRaw.Count -eq 0) {
        $salidaRaw = choco list $paquete --exact --all-versions 2>$null
    }

    # Extraer solo lineas que empiecen con el nombre del paquete seguido de
    # un espacio y un digito (descarta headers, footers y paquetes parciales)
    $paqueteEsc = [regex]::Escape($paquete)
    $versiones = $salidaRaw |
        Where-Object { $_ -imatch "^${paqueteEsc}\s+\d" } |
        ForEach-Object { ($_ -split '\s+')[1].Trim() } |
        Where-Object { $_ -match '^\d' }

    #  Ordenar de forma robusta 
    $versiones = $versiones | Sort-Object -Descending {
        # Tomar solo la parte numerica antes de cualquier guion o letra
        $parteNum = ($_ -split '[^0-9.]')[0].TrimEnd('.')
        $segmentos = $parteNum -split '\.' | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
        }
        # Construir valor de comparacion: rellenar hasta 4 segmentos con 0
        while ($segmentos.Count -lt 4) { $segmentos = @($segmentos) + @(0) }
        # Numero de 16 digitos que preserva el orden semantico
        '{0:D5}{1:D5}{2:D5}{3:D5}' -f $segmentos[0], $segmentos[1], $segmentos[2], $segmentos[3]
    }

    if (-not $versiones -or @($versiones).Count -eq 0) {
        aputs_warning "No se encontraron versiones en el repositorio - usando 'latest'"
        aputs_info   "Verifique: choco search $paquete --exact --all-versions"
        return @("latest")
    }

    $verInstalada = choco list --local-only $paquete 2>$null |
        Where-Object { $_ -imatch "^${paqueteEsc}\s" } |
        ForEach-Object { ($_ -split '\s+')[1].Trim() } |
        Select-Object -First 1

    $versionesArr = @($versiones)
    if ($verInstalada -and $versionesArr -notcontains $verInstalada) {
        $versionesArr = @($verInstalada) + $versionesArr
    }

    aputs_success "Se encontraron $($versionesArr.Count) version(es) disponible(s)"
    return $versionesArr
}

function http_seleccionar_version {
    param([string]$Servicio, [string[]]$Versiones)

    http_draw_servicio_header $Servicio "Paso 2 de 4 - Seleccion de version"

    $total = $Versiones.Count

    aputs_info "Versiones disponibles para ${Servicio} (orden: mas reciente primero):"
    Write-Host ""
    Write-Host ("  {0,-5}  {1,-28}  {2}" -f "NUM", "VERSION", "ETIQUETA")
    Write-Host "  ==="

    for ($i = 0; $i -lt $total; $i++) {
        # Etiquetas equivalentes a http_seleccionar_version de Installer.sh
        $etiqueta = if ($total -eq 1) {
            "${GREEN}Latest${NC} / ${BLUE}Stable${NC}"
        } elseif ($i -eq 0) {
            "${GREEN}Latest${NC}   - mas reciente, desarrollo activo"
        } elseif ($i -eq 1 -and $total -ge 3) {
            "${CYAN}Reciente${NC}  - un ciclo anterior, probada"
        } elseif ($i -eq $total - 1) {
            "${BLUE}Stable${NC}   - mayor tiempo en produccion"
        } else {
            "${GRAY}Anterior${NC}  - $i version(es) atras"
        }
        Write-Host -NoNewline ("  {0,-5}  {1,-28}  " -f "$($i+1))", $Versiones[$i])
        Write-Host $etiqueta
    }
    Write-Host ""
    aputs_info "Latest  = version mas reciente disponible en repositorios"
    aputs_info "Reciente= un ciclo de release atras, ampliamente probada"
    aputs_info "Stable  = version mas antigua disponible, maxima estabilidad"
    Write-Host ""

    $idx = ""
    do {
        $idx = agets "Seleccione version [1-${total}] (Enter = 1 Latest)"
        if ([string]::IsNullOrWhiteSpace($idx)) { $idx = "1" }
    } while (-not (http_validar_indice_version $idx $total))

    $versionElegida = $Versiones[[int]$idx - 1]
    aputs_success "Version seleccionada: $versionElegida"
    return $versionElegida
}

function http_seleccionar_puerto {
    param([string]$Servicio)

    http_draw_servicio_header $Servicio "Paso 3 de 4 - Puerto de escucha"

    $puertoDefault = switch ($Servicio) {
        "iis" { $Script:HTTP_PUERTO_DEFAULT_IIS }
        "apache" { $Script:HTTP_PUERTO_DEFAULT_APACHE }
        "nginx" { $Script:HTTP_PUERTO_DEFAULT_NGINX }
        "tomcat" { $Script:HTTP_PUERTO_DEFAULT_TOMCAT }
        default { 8080 }
    }

    aputs_info "Puerto default para ${Servicio}: ${puertoDefault}/tcp"
    aputs_info "Se recomienda usar un puerto >= 1024 fuera del rango reservado"
    Write-Host ""

    $puerto = 0
    do {
        $entrada = agets "Puerto de escucha [Enter = $puertoDefault]"
        if ([string]::IsNullOrWhiteSpace($entrada)) { $entrada = "$puertoDefault" }
        if (http_validar_puerto $entrada) {
            $puerto = [int]$entrada
        }
        Write-Host ""
    } while ($puerto -eq 0)

    aputs_success "Puerto seleccionado: ${puerto}/tcp"
    return $puerto
}

function http_crear_usuario_dedicado {
    param([string]$Usuario, [string]$Webroot)

    aputs_info "Configurando usuario dedicado: $Usuario"
    Write-Host ""

    # IIS usa IUSR - cuenta gestionada por Windows
    if ($Usuario -eq "IUSR") {
        aputs_info  "IIS usa la cuenta integrada IUSR - no requiere creacion manual"
        aputs_success "Cuenta IUSR disponible automaticamente"
        return $true
    }

    # Verificar si ya existe
    $existe = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
    if ($null -ne $existe) {
        aputs_info "El usuario '$Usuario' ya existe"
    }
    else {
        # Crear usuario local sin contrasena interactiva
        # Crear usuario con contrasena compleja aleatoria (cumple politica de complejidad)
        # Luego se deshabilita la cuenta para que no pueda hacer login interactivo.
        # -NoPassword no esta disponible en todas las builds de PS 5.1.
        $chars = 'abcdefghijklmnopqrstuvwxyz'
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $bytes = [byte[]]::new(16)
        $rng.GetBytes($bytes)
        # Contrasena: 4 segmentos aseguran mayuscula + minuscula + digito + simbolo
        $passStr = 'Svc!' + [Convert]::ToBase64String($bytes).Substring(0, 12) + '9'
        $pass = ConvertTo-SecureString $passStr -AsPlainText -Force
        try {
            New-LocalUser -Name $Usuario `
                -Password $pass `
                -PasswordNeverExpires `
                -UserMayNotChangePassword `
                -Description "Usuario dedicado para servicio HTTP $Usuario" `
                -ErrorAction Stop | Out-Null
            # Deshabilitar la cuenta: no puede hacer login aunque tenga contrasena
            Disable-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
            aputs_success "Usuario '$Usuario' creado y deshabilitado (equivale a nologin)"
        }
        catch {
            aputs_error "Error al crear usuario: $($_.Exception.Message)"
            return $false
        }
    }

    # Denegar login interactivo via politica local
    # Equivalente a /sbin/nologin en Linux
    # Usamos secedit para denegar "Log on locally" a este usuario
    aputs_info "Restringiendo acceso interactivo para '$Usuario'..."
    $infContent = @"
[Unicode]
Unicode=yes
[Privilege Rights]
SeDenyInteractiveLogonRight = *$Usuario
SeDenyRemoteInteractiveLogonRight = *$Usuario
SeDenyNetworkLogonRight = *$Usuario
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
    $infPath = "$env:TEMP\restrict_$Usuario.inf"
    $infContent | Out-File -FilePath $infPath -Encoding Unicode
    secedit /configure /db secedit.sdb /cfg $infPath /quiet 2>$null
    Remove-Item $infPath -ErrorAction SilentlyContinue
    aputs_success "Login interactivo denegado para '$Usuario' (equivale a /sbin/nologin)"

    # Asignar permisos sobre el webroot
    if ([string]::IsNullOrWhiteSpace($Webroot)) { return $true }

    if (-not (Test-Path $Webroot -PathType Container)) {
        New-Item -ItemType Directory -Path $Webroot -Force | Out-Null
        aputs_success "Webroot creado: $Webroot"
    }

    # Dar permisos de lectura/ejecucion sobre el webroot
    $acl = Get-Acl $Webroot
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Usuario, "ReadAndExecute,ListDirectory",
        "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Webroot -AclObject $acl -ErrorAction SilentlyContinue
    aputs_success "Permisos ReadAndExecute asignados a '$Usuario' en $Webroot"
    return $true
}

function http_crear_index {
    param([string]$Servicio, [string]$Version, [int]$Puerto)

    $webroot = http_get_webroot $Servicio
    $usuario = http_get_usuario_servicio $Servicio
    $fecha = Get-Date -Format "yyyy-MM-dd HH:mm"

    $nombreDisplay = switch ($Servicio) {
        "iis"    { "IIS (Internet Information Services)" }
        "apache" { "Apache HTTP Server" }
        "nginx"  { "Nginx" }
        "tomcat" { "Apache Tomcat" }
        default  { $Servicio }
    }

    aputs_info "Generando index.html en $webroot..."

    if (-not (Test-Path $webroot -PathType Container)) {
        New-Item -ItemType Directory -Path $webroot -Force | Out-Null
    }

$html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$nombreDisplay</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            background-color: #0d1117;
            background-image: radial-gradient(ellipse at 50% 50%, #0f1f35 0%, #0d1117 70%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: 'Courier New', Courier, monospace;
        }

        .card {
            border: 1px solid #00bcd4;
            border-radius: 4px;
            padding: 36px 48px;
            text-align: center;
            min-width: 360px;
        }

        .card h1 {
            color: #00e5ff;
            font-size: 1.25rem;
            font-weight: bold;
            letter-spacing: 1px;
            margin-bottom: 24px;
        }

        .card table {
            margin: 0 auto;
            border-collapse: collapse;
        }

        .card td {
            color: #80deea;
            font-size: 0.88rem;
            padding: 3px 8px;
            text-align: center;
        }

        .card td.label {
            color: #4dd0e1;
            font-weight: bold;
        }

        .card td.sep {
            color: #00bcd4;
            padding: 0 4px;
        }

        .status {
            color: #80deea;
            font-size: 0.82rem;
            margin-bottom: 18px;
            letter-spacing: 0.5px;
        }
    </style>
</head>
<body>
    <div class="card">
        <h1>Servidor HTTP - Windows Server</h1>
        <p class="status">Servidor desplegado exitosamente</p>
        <table>
            <tr>
                <td class="label">Servidor</td>
                <td class="sep">:</td>
                <td>$nombreDisplay</td>
            </tr>
            <tr>
                <td class="label">Version</td>
                <td class="sep">:</td>
                <td>$Version</td>
            </tr>
            <tr>
                <td class="label">Puerto</td>
                <td class="sep">:</td>
                <td>${Puerto}</td>
            </tr>
            <tr>
                <td class="label">Webroot</td>
                <td class="sep">:</td>
                <td>$webroot</td>
            </tr>
            <tr>
                <td class="label">Usuario</td>
                <td class="sep">:</td>
                <td>$usuario</td>
            </tr>
        </table>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath "$webroot\index.html" -Encoding UTF8 -Force
    aputs_success "index.html generado en $webroot"
}

function _http_configurar_firewall_inicial {
    param([string]$Servicio, [int]$Puerto)

    aputs_info "Configurando Windows Firewall para puerto ${Puerto}/tcp..."
    Write-Host ""

    $nombreRegla = "HTTP_${Servicio}_${Puerto}"

    # Verificar si la regla ya existe
    $reglaExistente = Get-NetFirewallRule -DisplayName $nombreRegla `
        -ErrorAction SilentlyContinue
    if ($null -eq $reglaExistente) {
        New-NetFirewallRule -DisplayName $nombreRegla `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $Puerto `
            -Action Allow `
            -ErrorAction Stop | Out-Null
        aputs_success "Regla '$nombreRegla' creada - puerto ${Puerto}/tcp abierto"
    }
    else {
        aputs_info "Regla para puerto ${Puerto}/tcp ya existia"
    }

    # Cerrar el puerto default si se uso uno distinto
    $puertoDefault = switch ($Servicio) {
        "iis" { $Script:HTTP_PUERTO_DEFAULT_IIS }
        "apache" { $Script:HTTP_PUERTO_DEFAULT_APACHE }
        "nginx" { $Script:HTTP_PUERTO_DEFAULT_NGINX }
        "tomcat" { $Script:HTTP_PUERTO_DEFAULT_TOMCAT }
    }

    if ($Puerto -ne $puertoDefault) {
        $reglaDefault = Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' } |
        ForEach-Object {
            $pf = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            if ($pf -and $pf.LocalPort -eq "$puertoDefault") { $_ }
        } | Select-Object -First 1

        if ($reglaDefault) {
            Remove-NetFirewallRule -Name $reglaDefault.Name -ErrorAction SilentlyContinue
            aputs_success "Regla del puerto default ${puertoDefault}/tcp eliminada"
        }
    }

    return $true
}

function http_instalar_iis {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "IIS" "Paso 4 de 4 - Instalacion"

    # Paso 1: Instalar feature de Windows
    draw_line
    aputs_info "PASO 1/5 - Instalacion de IIS via DISM"
    draw_line
    Import-Module ServerManager -ErrorAction SilentlyContinue
    $features = @("Web-Server", "Web-Common-Http", "Web-Static-Content",
        "Web-Default-Doc", "Web-Http-Logging", "Web-Security",
        "Web-Filtering", "Web-Performance", "Web-Stat-Compression",
        "Web-Mgmt-Tools", "Web-Scripting-Tools")

    foreach ($feat in $features) {
        $result = Install-WindowsFeature -Name $feat -ErrorAction SilentlyContinue
        if ($result.Success) {
            Write-Host "  ${GREEN}[OK]${NC}  Feature instalada: $feat"
        }
    }

    # Paso 2: Usuario dedicado
    Write-Host ""
    draw_line
    aputs_info "PASO 2/5 - Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_IIS $Script:HTTP_DIR_IIS

    # Paso 3: Cargar modulo WebAdministration
    Write-Host ""
    draw_line
    aputs_info "PASO 3/5 - Configuracion del sitio web"
    draw_line
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Configurar el binding al puerto seleccionado
    $site = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($site) {
        Remove-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue
        New-WebBinding -Name "Default Web Site" -Protocol http -Port $Puerto | Out-Null
        aputs_success "Binding configurado: puerto $Puerto"
    }

    # Paso 4: Puerto (ya configurado en el binding)
    Write-Host ""
    draw_line
    aputs_info "PASO 4/5 - Puerto $Puerto configurado"
    draw_line
    aputs_info "Binding HTTP en puerto $Puerto ya establecido"

    # Paso 5: Iniciar servicio + firewall + index
    Write-Host ""
    draw_line
    aputs_info "PASO 5/5 - Activacion del servicio"
    draw_line
    Set-Service -Name $Script:HTTP_WINSVC_IIS -StartupType Automatic
    Start-Service -Name $Script:HTTP_WINSVC_IIS -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (check_service_active $Script:HTTP_WINSVC_IIS) {
        aputs_success "IIS iniciado y activo"
    }
    else {
        aputs_error "IIS no levanto - revise el Visor de Eventos"
        return $false
    }

    _http_configurar_firewall_inicial "iis" $Puerto
    Write-Host ""
    http_crear_index "iis" "sistema" $Puerto

    Write-Host ""
    $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
            -ErrorAction SilentlyContinue).VersionString
    http_draw_resumen "IIS" "$Puerto" "$iisVer"
    return $true
}

function http_instalar_apache {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Apache (httpd)" "Paso 4 de 4 - Instalacion"

    # Paso 1: Instalar via choco
    draw_line
    aputs_info "PASO 1/5 - Instalacion via Chocolatey"
    draw_line

    if ($Version -eq "latest") {
        & choco install apache-httpd -y
    }
    else {
        & choco install apache-httpd "--version=$Version" -y
    }

    # choco puede devolver exit code != 0 por warnings del script post-instalacion.
    # Verificamos que httpd.exe existe en disco como prueba real del exito.
    $httpdExeVerif = $null
    $candidatosExe = @(
        "$env:APPDATA\Apache24\bin\httpd.exe",
        "$env:APPDATA\Apache2.4\bin\httpd.exe",
        "C:\Apache24\bin\httpd.exe",
        "C:\tools\httpd\bin\httpd.exe"
    )
    foreach ($c in $candidatosExe) {
        if (Test-Path $c) { $httpdExeVerif = $c; break }
    }
    if (-not $httpdExeVerif) {
        $httpdItem = Get-ChildItem -Path $env:APPDATA -Recurse `
            -Filter httpd.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($httpdItem) { $httpdExeVerif = $httpdItem.FullName }
    }
    if (-not $httpdExeVerif) {
        aputs_error "Fallo choco install apache-httpd - httpd.exe no encontrado en disco"
        return $false
    }
    aputs_success "apache-httpd instalado - httpd.exe en: $httpdExeVerif"

    # choco instala Apache en AppData\Roaming, no en C:\tools\httpd.
    # -Depth no existe en PS 5.1 (PS 6+), por eso usamos rutas conocidas primero.
    Write-Host ""
    draw_line
    aputs_info "PASO 3/5 - Localizar httpd.conf y configurar puerto"
    draw_line
    # Rutas candidatas donde choco suele instalar apache-httpd
    $candidatos = @(
        $Script:HTTP_CONF_APACHE,
        "$env:APPDATA\Apache24\conf\httpd.conf",
        "$env:APPDATA\Apache2.4\conf\httpd.conf",
        "C:\Apache24\conf\httpd.conf",
        "C:\Apache2.4\conf\httpd.conf",
        "C:\tools\httpd\conf\httpd.conf"
    )
    $httpdConfReal = $null
    foreach ($c in $candidatos) {
        if (Test-Path $c) { $httpdConfReal = Get-Item $c; break }
    }
    # Fallback: buscar en AppData completo (PS5 compatible, sin -Depth)
    if (-not $httpdConfReal) {
        $httpdConfReal = Get-ChildItem -Path $env:APPDATA -Recurse `
            -Filter httpd.conf -ErrorAction SilentlyContinue |
        Select-Object -First 1
    }
    if ($httpdConfReal) {
        $Script:HTTP_CONF_APACHE = $httpdConfReal.FullName
        $apacheRoot = Split-Path (Split-Path $httpdConfReal.FullName)
        $htdocs = Join-Path $apacheRoot "htdocs"
        if (Test-Path $htdocs) { $Script:HTTP_DIR_APACHE = $htdocs }
        aputs_info "httpd.conf localizado: $($httpdConfReal.FullName)"
        http_crear_backup $Script:HTTP_CONF_APACHE

        # Corregir SRVROOT - choco instala en AppData pero httpd.conf apunta a c:/Apache24
        # Apache requiere barras hacia adelante en las rutas, nunca backslashes
        $srvrootCorrecta = $apacheRoot -replace '\\', '/'
        (Get-Content $Script:HTTP_CONF_APACHE) `
            -replace 'Define SRVROOT ".*"', "Define SRVROOT `"$srvrootCorrecta`"" |
        Set-Content $Script:HTTP_CONF_APACHE -Force
        aputs_success "SRVROOT corregida: $srvrootCorrecta"

        # Verificar sintaxis antes de continuar
        $httpdExe = Join-Path $apacheRoot "bin\httpd.exe"
        if (Test-Path $httpdExe) {
            $syntaxCheck = & $httpdExe -t 2>&1
            if ($syntaxCheck -match "Syntax OK") {
                aputs_success "httpd.conf: Syntax OK"
            }
            else {
                aputs_warning "httpd.conf tiene advertencias - verifique manualmente:"
                $syntaxCheck | ForEach-Object { Write-Host "    $_" }
            }
        }

        $bytesApache = [System.IO.File]::ReadAllBytes($Script:HTTP_CONF_APACHE)
        if ($bytesApache[0] -eq 0xEF -and $bytesApache[1] -eq 0xBB -and $bytesApache[2] -eq 0xBF) {
            $contenidoApache = [System.Text.Encoding]::UTF8.GetString($bytesApache, 3, $bytesApache.Length - 3)
        }
        else {
            $contenidoApache = [System.Text.Encoding]::UTF8.GetString($bytesApache)
        }
        $contenidoApache = $contenidoApache -replace 'Listen\s+\d+', "Listen $Puerto"
        $contenidoApache = $contenidoApache -replace 'ServerName\s+\S+:\d+', "ServerName localhost:$Puerto"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Script:HTTP_CONF_APACHE, $contenidoApache, $utf8NoBom)
        aputs_success "Puerto $Puerto configurado en httpd.conf"
    }
    else {
        aputs_warning "httpd.conf no encontrado - se continuara sin configurar puerto"
    }

    Write-Host ""
    draw_line
    aputs_info "PASO 2/5 - Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_APACHE $Script:HTTP_DIR_APACHE

    # choco registra el servicio como 'Apache' (no 'Apache2.4').
    # Si no hay servicio aun, localizamos httpd.exe y lo registramos.
    Write-Host ""
    draw_line
    aputs_info "PASO 4/5 - Registro como servicio de Windows"
    draw_line
    # Detectar el servicio Apache que choco pudo haber registrado
    $svcApache = Get-Service -ErrorAction SilentlyContinue | `
        Where-Object { $_.Name -match '^Apache' -or $_.Name -match '^httpd' } | `
        Select-Object -First 1
    if ($svcApache) {
        $Script:HTTP_WINSVC_APACHE = $svcApache.Name
        aputs_info "Servicio Apache detectado: '$($svcApache.Name)'"
        aputs_success "Servicio ya registrado por choco"
    }
    else {
        # No hay servicio: buscar httpd.exe en rutas conocidas y registrarlo
        $exeCandidatos = @(
            "$env:APPDATA\Apache24\bin\httpd.exe",
            "$env:APPDATA\Apache2.4\bin\httpd.exe",
            "C:\Apache24\bin\httpd.exe",
            "C:\tools\httpd\bin\httpd.exe"
        )
        $httpdExe = $null
        foreach ($e in $exeCandidatos) {
            if (Test-Path $e) { $httpdExe = $e; break }
        }
        if (-not $httpdExe) {
            # Ultimo recurso: buscar en AppData (PS5 sin -Depth, sin operador ?.)
            $httpdItem = Get-ChildItem -Path $env:APPDATA -Recurse `
                -Filter httpd.exe -ErrorAction SilentlyContinue |
            Select-Object -First 1
            if ($httpdItem) { $httpdExe = $httpdItem.FullName }
        }
        if ($httpdExe) {
            aputs_info "httpd.exe localizado: $httpdExe"
            & $httpdExe -k install -n "Apache2.4" 2>$null
            $Script:HTTP_WINSVC_APACHE = "Apache2.4"
            aputs_success "Servicio Apache2.4 registrado"
        }
        else {
            aputs_warning "httpd.exe no localizado - el servicio puede ya estar registrado"
        }
    }

    # Activar servicio + firewall + index
    Write-Host ""
    draw_line
    aputs_info "PASO 5/5 - Activacion del servicio"
    draw_line
    Set-Service -Name $Script:HTTP_WINSVC_APACHE -StartupType Automatic `
        -ErrorAction SilentlyContinue

    Stop-Service -Name $Script:HTTP_WINSVC_APACHE -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name $Script:HTTP_WINSVC_APACHE -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (check_service_active $Script:HTTP_WINSVC_APACHE) {
        aputs_success "Apache2.4 iniciado y activo"
    }
    else {
        aputs_error "Apache no levanto - revise el Visor de Eventos"
        return $false
    }

    _http_configurar_firewall_inicial "apache" $Puerto
    Write-Host ""
    http_crear_index "apache" $Version $Puerto

    Write-Host ""
    http_draw_resumen "Apache HTTP Server" "$Puerto" "$Version"
    return $true
}

function http_instalar_nginx {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Nginx" "Paso 4 de 4 - Instalacion"

    draw_line
    aputs_info "PASO 1/5 - Instalacion via Chocolatey"
    draw_line

    if ($Version -eq "latest") {
        & choco install nginx -y
    }
    else {
        & choco install nginx "--version=$Version" -y
    }

    # Verificar por existencia de nginx.exe, no por exit code
    $nginxExeVerif = $null
    $candidatosNginxVerif = @(
        "C:\tools\nginx\nginx.exe",
        "C:\tools\nginx-1.29.5\nginx.exe",
        "C:\tools\nginx-1.28.0\nginx.exe",
        "$env:ChocolateyInstall\lib\nginx\tools\nginx.exe",
        "$env:ProgramData\chocolatey\lib\nginx\tools\nginx.exe"
    )
    foreach ($c in $candidatosNginxVerif) {
        if (Test-Path $c) { $nginxExeVerif = $c; break }
    }
    if (-not $nginxExeVerif) {
        $nginxItem = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxItem) { $nginxExeVerif = $nginxItem.FullName }
    }
    if (-not $nginxExeVerif) {
        $chocoLibNginx2 = "$env:ProgramData\chocolatey\lib\nginx\tools"
        if (Test-Path $chocoLibNginx2) {
            $nginxItem = Get-ChildItem $chocoLibNginx2 -Recurse -Filter nginx.exe `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($nginxItem) { $nginxExeVerif = $nginxItem.FullName }
        }
    }
    if (-not $nginxExeVerif) {
        aputs_error "Fallo choco install nginx - nginx.exe no encontrado en disco"
        return $false
    }
    aputs_success "nginx instalado en: $nginxExeVerif"

    Write-Host ""
    draw_line
    aputs_info "PASO 2/5 - Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_NGINX $Script:HTTP_DIR_NGINX

    Write-Host ""
    draw_line
    aputs_info "PASO 3/5 - Configuracion de puerto en nginx.conf"
    draw_line

    # Actualizar ruta de nginx.conf ahora que nginx ya esta instalado.
    # choco puede instalar en:
    #   C:\tools\nginx-X.Y.Z\         (choco < 2.0, versiones recientes)
    #   C:\ProgramData\chocolatey\lib\nginx\tools\nginx-X.Y.Z\  (choco >= 2.0)
    if (-not (Test-Path $Script:HTTP_CONF_NGINX)) {
        # Buscar en C:\tools primero (instalaciones tipicas)
        $nginxConfReal = Get-ChildItem "C:\tools" -Recurse -Filter nginx.conf `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        # Fallback: ProgramData/chocolatey (choco >= 2.0 o versiones antiguas)
        if (-not $nginxConfReal) {
            $chocoLib = "$env:ProgramData\chocolatey\lib\nginx\tools"
            if (Test-Path $chocoLib) {
                $nginxConfReal = Get-ChildItem $chocoLib -Recurse -Filter nginx.conf `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
            }
        }
        if ($nginxConfReal) {
            $Script:HTTP_CONF_NGINX = $nginxConfReal.FullName
            $nginxHtmlReal = Join-Path (Split-Path (Split-Path $nginxConfReal.FullName)) "html"
            if (Test-Path $nginxHtmlReal) { $Script:HTTP_DIR_NGINX = $nginxHtmlReal }
            aputs_info "nginx.conf localizado: $($nginxConfReal.FullName)"
        }
    }

    if (Test-Path $Script:HTTP_CONF_NGINX) {
        http_crear_backup $Script:HTTP_CONF_NGINX
        $bytes = [System.IO.File]::ReadAllBytes($Script:HTTP_CONF_NGINX)
        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        }
        else {
            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        $contenidoNginx = $contenidoNginx -replace 'listen\s+\d+;', "listen $Puerto;"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $contenidoNginx, $utf8NoBom)
        aputs_success "Puerto $Puerto configurado en nginx.conf"
    }

    Write-Host ""
    draw_line
    aputs_info "PASO 4/5 - Registro como servicio de Windows (NSSM)"
    draw_line

    # Buscar nginx.exe en rutas conocidas de choco
    $nginxExePath = $null
    $candidatosNginx = @(
        "C:\tools\nginx\nginx.exe",
        "C:\tools\nginx-1.29.5\nginx.exe",
        "C:\tools\nginx-1.28.0\nginx.exe",
        "$env:ChocolateyInstall\lib\nginx\tools\nginx.exe",
        "$env:ProgramData\chocolatey\lib\nginx\tools\nginx.exe"
    )
    foreach ($c in $candidatosNginx) {
        if (Test-Path $c) { $nginxExePath = $c; break }
    }
    # Fallback dinamico: buscar en C:\tools Y en ProgramData\chocolatey\lib\nginx
    if (-not $nginxExePath) {
        $nginxItem = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxItem) { $nginxExePath = $nginxItem.FullName }
    }
    if (-not $nginxExePath) {
        $chocoLibNginx = "$env:ProgramData\chocolatey\lib\nginx\tools"
        if (Test-Path $chocoLibNginx) {
            $nginxItem = Get-ChildItem $chocoLibNginx -Recurse -Filter nginx.exe `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($nginxItem) { $nginxExePath = $nginxItem.FullName }
        }
    }

    if (-not $nginxExePath) {
        aputs_error "nginx.exe no encontrado tras la instalacion"
        return $false
    }

    aputs_info "nginx.exe localizado: $nginxExePath"

    # Instalar NSSM si no esta disponible - es obligatorio para registrar nginx como servicio
    $nssm = Get-Command nssm -ErrorAction SilentlyContinue
    if (-not $nssm) {
        aputs_info "NSSM no encontrado - instalando via Chocolatey..."
        & choco install nssm -y
        if ($LASTEXITCODE -ne 0) {
            aputs_error "No se pudo instalar NSSM - nginx no quedara como servicio de Windows"
            return $false
        }
    }

    # Verificar si el servicio ya existe antes de registrarlo
    $svcNginxExiste = Get-Service -Name "nginx" -ErrorAction SilentlyContinue
    if ($null -eq $svcNginxExiste) {
        Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        & nssm install nginx "$nginxExePath"
        & nssm set nginx AppDirectory (Split-Path $nginxExePath)
        aputs_success "Servicio nginx registrado via NSSM"
    }
    else {
        aputs_info "Servicio nginx ya registrado"
    }

    Write-Host ""
    draw_line
    aputs_info "PASO 5/5 - Activacion del servicio"
    draw_line
    Stop-Service -Name $Script:HTTP_WINSVC_NGINX -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name $Script:HTTP_WINSVC_NGINX -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (check_service_active $Script:HTTP_WINSVC_NGINX) {
        aputs_success "nginx iniciado y activo"
    }
    else {
        aputs_error "nginx no levanto - revise la configuracion"
        return $false
    }

    _http_configurar_firewall_inicial "nginx" $Puerto
    Write-Host ""
    http_crear_index "nginx" $Version $Puerto

    Write-Host ""
    http_draw_resumen "Nginx" "$Puerto" "$Version"
    return $true
}

function http_instalar_tomcat {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Tomcat" "Paso 4 de 4 - Instalacion"

    # Verificar Java
    draw_line
    aputs_info "PASO 1/5 - Verificar Java"
    draw_line

    $java = Get-Command java -ErrorAction SilentlyContinue
    if (-not $java) {
        aputs_warning "Java no encontrado - requerido para Tomcat"
        Write-Host ""
        $respJava = agets "Instalar Java 17 (Temurin) automaticamente ahora? [s/n]"
        $rcJava = http_validar_confirmacion $respJava
        if ($rcJava -ne 0) {
            aputs_info "Instale Java manualmente con: choco install temurin17 -y"
            aputs_info "Luego ejecute refreshenv o abra una nueva sesion y reintente"
            return $false
        }
        aputs_info "Instalando Java 17 (Temurin) via Chocolatey..."
        & choco install temurin17 -y
        if ($LASTEXITCODE -ne 0) {
            aputs_error "Fallo la instalacion de Java"
            return $false
        }
        # Refrescar PATH para que java sea visible en esta sesion
        $javaPath = "C:\Program Files\Eclipse Adoptium\jdk-17*\bin" |
        Resolve-Path -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($javaPath) { $env:PATH += ";$javaPath" }
        $java = Get-Command java -ErrorAction SilentlyContinue
        if (-not $java) {
            aputs_error "Java instalado pero no visible en PATH - ejecute refreshenv y reintente"
            return $false
        }
    }
    $jver = (java -version 2>&1 | Select-Object -First 1)
    aputs_success "Java disponible: $jver"

    Write-Host ""
    draw_line
    aputs_info "PASO 2/5 - Instalacion de Tomcat via Chocolatey"
    draw_line

    # Setear JAVA_HOME explicitamente - el instalador choco de tomcat
    # lanza procesos hijos que no heredan el PATH refrescado en esta sesion
    $javaHome = Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Directory `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javaHome) {
        $env:JAVA_HOME = $javaHome.FullName
        aputs_info "JAVA_HOME: $env:JAVA_HOME"
    }

    if ($Version -eq "latest") {
        & choco install tomcat -y
    }
    else {
        & choco install tomcat "--version=$Version" -y
    }

    # Verificar por existencia del servicio o del jar, no por exit code
    # choco instala tomcat en C:\ProgramData\chocolatey\lib\Tomcat\tools\
    $tomcatVerif = Get-Service -Name "Tomcat*" -ErrorAction SilentlyContinue |
    Select-Object -First 1
    if (-not $tomcatVerif) {
        # choco instalo los archivos pero no registro el servicio porque
        # JAVA_HOME no estaba disponible al momento de ejecutar el instalador.
        # Registrar manualmente con tomcat9.exe //IS//
        aputs_warning "Servicio Tomcat no registrado por choco - registrando manualmente..."
        $tomcat9Exe = Get-ChildItem "C:\ProgramData\Tomcat9\bin" -Filter "tomcat9.exe" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $tomcat9Exe) {
            $tomcat9Exe = Get-ChildItem "C:\ProgramData\chocolatey\lib\Tomcat" `
                -Recurse -Filter "tomcat9.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        }
        if ($tomcat9Exe) {
            $catalinaHome = Split-Path (Split-Path $tomcat9Exe.FullName)
            $catalinaBase = "C:\ProgramData\Tomcat9"
            $env:CATALINA_HOME = $catalinaHome
            $env:CATALINA_BASE = $catalinaBase

            # Instalar NSSM si no esta disponible
            $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
            if (-not $nssmCmd) {
                aputs_info "NSSM no encontrado - instalando via Chocolatey..."
                & choco install nssm -y | Out-Null
                $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
            }
            if (-not $nssmCmd) {
                aputs_error "No se pudo instalar NSSM - Tomcat no quedara como servicio"
                return $false
            }

            # catalina.bat run mantiene el proceso en foreground - NSSM lo gestiona
            $catalinaBat = Join-Path $catalinaHome "bin\catalina.bat"

            & nssm install Tomcat9 cmd /c "`"$catalinaBat`" run" | Out-Null
            & nssm set Tomcat9 DisplayName "Apache Tomcat 9.0" | Out-Null
            & nssm set Tomcat9 AppDirectory $catalinaBase | Out-Null
            & nssm set Tomcat9 AppEnvironmentExtra `
                "JAVA_HOME=$($env:JAVA_HOME)" `
                "CATALINA_HOME=$catalinaHome" `
                "CATALINA_BASE=$catalinaBase" `
                "JRE_HOME=$($env:JAVA_HOME)" | Out-Null
            & nssm set Tomcat9 AppStdout "$catalinaBase\logs\service-stdout.log" | Out-Null
            & nssm set Tomcat9 AppStderr "$catalinaBase\logs\service-stderr.log" | Out-Null
            & nssm set Tomcat9 Start SERVICE_AUTO_START | Out-Null

            Start-Sleep -Seconds 2
            $tomcatVerif = Get-Service -Name "Tomcat9" -ErrorAction SilentlyContinue
            if ($tomcatVerif) {
                aputs_success "Servicio Tomcat9 registrado via NSSM"
                $Script:HTTP_WINSVC_TOMCAT = "Tomcat9"
            }
            else {
                aputs_error "No se pudo registrar el servicio Tomcat via NSSM"
                return $false
            }
        }
        else {
            aputs_error "tomcat9.exe no encontrado - instalacion incompleta"
            return $false
        }
    }
    aputs_success "tomcat instalado"

    Write-Host ""
    draw_line
    aputs_info "PASO 3/5 - Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_TOMCAT $Script:HTTP_DIR_TOMCAT

    Write-Host ""
    draw_line
    aputs_info "PASO 4/5 - Configuracion de puerto en server.xml"
    draw_line
    if (Test-Path $Script:HTTP_CONF_TOMCAT) {
        http_crear_backup $Script:HTTP_CONF_TOMCAT
        [xml]$xml = Get-Content $Script:HTTP_CONF_TOMCAT
        $connector = $null
        foreach ($c in $xml.Server.Service.Connector) {
            if ($c.protocol -match 'HTTP') { $connector = $c; break }
        }
        if ($connector) {
            $connector.SetAttribute("port", "$Puerto")
            $xml.Save($Script:HTTP_CONF_TOMCAT)
            aputs_success "Puerto $Puerto configurado en server.xml"
        }
    }

    Write-Host ""
    draw_line
    aputs_info "PASO 5/5 - Activacion del servicio"
    draw_line
    Set-Service -Name $Script:HTTP_WINSVC_TOMCAT -StartupType Automatic `
        -ErrorAction SilentlyContinue
    Start-Service -Name $Script:HTTP_WINSVC_TOMCAT -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    if (check_service_active $Script:HTTP_WINSVC_TOMCAT) {
        aputs_success "Tomcat iniciado y activo"
    }
    else {
        aputs_error "Tomcat no levanto - verifique JAVA_HOME y logs"
        return $false
    }

    _http_configurar_firewall_inicial "tomcat" $Puerto
    Write-Host ""
    http_crear_index "tomcat" $Version $Puerto

    Write-Host ""
    http_draw_resumen "Apache Tomcat" "$Puerto" "$Version"
    return $true
}

function http_menu_instalar {
    #  Paso 1: Seleccion de servicio 
    $seleccion = http_seleccionar_servicio

    switch -Wildcard ($seleccion) {
        "cancelar" {
            aputs_info "Instalacion cancelada"
            Start-Sleep -Seconds 2
            return
        }
        "reinstalar:*" {
            $servicio = $seleccion -replace "reinstalar:", ""
            aputs_warning "Desinstalando $servicio..."
            choco uninstall (http_nombre_paquete $servicio) -y 2>$null
            aputs_success "Desinstalado. Continuando con instalacion limpia..."
            Start-Sleep -Seconds 2
        }
        "reconfigurar:*" {
            $servicio = $seleccion -replace "reconfigurar:", ""

            $verActual = _http_obtener_version_local $servicio

            $puertoNew = http_seleccionar_puerto $servicio

            #  Cambiar puerto segun el tipo de servicio 
            switch ($servicio) {
                "iis" {
                    # IIS no usa archivo de texto - el puerto se gestiona
                    # via WebAdministration con bindings del sitio web.
                    Import-Module WebAdministration -ErrorAction SilentlyContinue
                    $site = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
                    if ($site) {
                        Remove-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue
                        New-WebBinding -Name "Default Web Site" -Protocol http -Port $puertoNew | Out-Null
                        aputs_success "Binding IIS actualizado: puerto $puertoNew"
                    } else {
                        aputs_warning "Sitio 'Default Web Site' no encontrado en IIS"
                    }
                }
                "apache" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        $bytesApache = [System.IO.File]::ReadAllBytes($confFile)
                        if ($bytesApache[0] -eq 0xEF -and $bytesApache[1] -eq 0xBB -and $bytesApache[2] -eq 0xBF) {
                            $contenidoApache = [System.Text.Encoding]::UTF8.GetString($bytesApache, 3, $bytesApache.Length - 3)
                        } else {
                            $contenidoApache = [System.Text.Encoding]::UTF8.GetString($bytesApache)
                        }
                        $contenidoApache = $contenidoApache -replace 'Listen\s+\d+', "Listen $puertoNew"
                        $contenidoApache = $contenidoApache -replace 'ServerName\s+\S+:\d+', "ServerName localhost:$puertoNew"
                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                        [System.IO.File]::WriteAllText($confFile, $contenidoApache, $utf8NoBom)
                        aputs_success "Puerto $puertoNew configurado en httpd.conf"
                    } else {
                        aputs_warning "httpd.conf no encontrado - omitiendo cambio de puerto"
                    }
                }
                "nginx" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        $bytesNginx = [System.IO.File]::ReadAllBytes($confFile)
                        if ($bytesNginx[0] -eq 0xEF -and $bytesNginx[1] -eq 0xBB -and $bytesNginx[2] -eq 0xBF) {
                            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytesNginx, 3, $bytesNginx.Length - 3)
                        } else {
                            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytesNginx)
                        }
                        $contenidoNginx = $contenidoNginx -replace 'listen\s+\d+;', "listen $puertoNew;"
                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                        [System.IO.File]::WriteAllText($confFile, $contenidoNginx, $utf8NoBom)
                        aputs_success "Puerto $puertoNew configurado en nginx.conf"
                    } else {
                        aputs_warning "nginx.conf no encontrado - omitiendo cambio de puerto"
                    }
                }
                "tomcat" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        [xml]$xml = Get-Content $confFile
                        $connector = $null
                        foreach ($c in $xml.Server.Service.Connector) {
                            if ($c.protocol -match 'HTTP') { $connector = $c; break }
                        }
                        if ($connector) {
                            $connector.SetAttribute("port", "$puertoNew")
                            $xml.Save($confFile)
                            aputs_success "Puerto $puertoNew configurado en server.xml"
                        }
                    } else {
                        aputs_warning "server.xml no encontrado - omitiendo cambio de puerto"
                    }
                }
            }

            if (-not (http_reiniciar_servicio $servicio)) {
                aputs_error "El servicio no levanto - revise la configuracion"
                pause_menu
                return
            }

            _http_configurar_firewall_inicial $servicio $puertoNew
            http_crear_index $servicio $verActual $puertoNew
            http_draw_resumen $servicio $puertoNew $verActual
            pause_menu
            return
        }
        default { $servicio = $seleccion }
    }

    Write-Host ""

    #  Paso 2: Consultar versiones 
    $versiones = http_consultar_versiones $servicio
    if (-not $versiones -or $versiones.Count -eq 0) {
        aputs_error "No se pudieron obtener versiones. Verifique la conexion."
        pause_menu
        return
    }

    Write-Host ""

    #  Paso 3: Seleccion de version ===
    $version = http_seleccionar_version $servicio $versiones

    Write-Host ""
    pause_menu

    #  Paso 4: Seleccion de puerto 
    $puerto = http_seleccionar_puerto $servicio

    Write-Host ""

    #  Confirmacion final 
    draw_line
    aputs_info "Resumen de la instalacion a realizar:"
    Write-Host ""
    Write-Host ("    Servicio : $servicio")
    Write-Host ("    Version  : $version")
    Write-Host ("    Puerto   : ${puerto}/tcp")
    Write-Host ""

    $confirmado = $false
    do {
        $resp = agets "Confirmar instalacion? [s/n]"
        $r = http_validar_confirmacion $resp
        if ($r -eq 0) { $confirmado = $true; break }
        if ($r -eq 1) { aputs_info "Instalacion cancelada"; Start-Sleep 2; return }
        Write-Host ""
    } while ($true)

    draw_line
    Write-Host ""

    #  Paso 5: Ejecutar la instalacion ===
    switch ($servicio) {
        "iis" { http_instalar_iis    $version $puerto }
        "apache" { http_instalar_apache $version $puerto }
        "nginx" { http_instalar_nginx  $version $puerto }
        "tomcat" { http_instalar_tomcat $version $puerto }
    }

    Write-Host ""
    pause_menu
}