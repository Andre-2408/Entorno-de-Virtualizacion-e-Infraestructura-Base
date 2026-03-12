#
# StatusCheck.ps1
# Grupo A - Verificacion de estado de servicios HTTP
#
# Funciones:
#   http_verificar_estado()            - Panel general de los cuatro servicios
#   http_verificar_puerto_disponible() - Diagnostico de un puerto especifico
#   http_verificar_usuario_servicio()  - Valida usuario dedicado y permisos
#   http_menu_verificar()              - Submenu interactivo del Grupo A
#
# Requiere: CoreHelpers.ps1, HTTPGlobals.ps1, InputGuard.ps1
#

#Requires -Version 5.1

function _http_obtener_puerto_activo {
    param([string]$NombreWinsvc)

    $svc = Get-Service -Name $NombreWinsvc -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.Status -ne 'Running') { return 0 }

    # IIS: usar WebAdministration - el puerto real esta en el binding
    if ($NombreWinsvc -eq $Script:HTTP_WINSVC_IIS -or $NombreWinsvc -eq "W3SVC") {
        try {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $binding = Get-WebBinding "Default Web Site" -ErrorAction SilentlyContinue |
            Select-Object -First 1
            if ($binding) {
                $puerto = ($binding.bindingInformation -split ':')[1]
                if ($puerto -match '^\d+$') { return [int]$puerto }
            }
        }
        catch { }
        return 0
    }

    # Apache, Nginx, Tomcat: buscar por nombre de ejecutable del proceso
    # El servicio puede tener un PID de wrapper (NSSM/procrun) que no escucha
    $nombreExe = switch -Regex ($NombreWinsvc) {
        '^Apache|^httpd' { 'httpd' }
        '^nginx' { 'nginx' }
        '^Tomcat' { 'tomcat9' }
        default { $null }
    }

    if ($nombreExe) {
        $pids = Get-Process -Name $nombreExe -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id

        if ($pids) {
            $conn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $pids -contains $_.OwningProcess } |
            # Excluir puertos de administracion internos 
            Where-Object { $_.LocalAddress -eq '0.0.0.0' -or $_.LocalAddress -eq '::' } |
            Select-Object -First 1
            if ($conn) { return $conn.LocalPort }
        }
    }

    # Fallback: PID directo del servicio (funciona para servicios nativos)
    $cimSvc = Get-CimInstance Win32_Service -Filter "Name='$NombreWinsvc'" `
        -ErrorAction SilentlyContinue
    if ($cimSvc -and $cimSvc.ProcessId -gt 0) {
        $conn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -eq $cimSvc.ProcessId } |
        Select-Object -First 1
        if ($conn) { return $conn.LocalPort }
    }

    return 0
}

function http_verificar_estado {
    Clear-Host
    draw_header "Verificacion de Servicios HTTP"

    $servicios = @(
        @{ Nombre = "IIS"; Interno = "iis"; WinSvc = $Script:HTTP_WINSVC_IIS }
        @{ Nombre = "Apache (httpd)"; Interno = "apache"; WinSvc = $Script:HTTP_WINSVC_APACHE }
        @{ Nombre = "Nginx"; Interno = "nginx"; WinSvc = $Script:HTTP_WINSVC_NGINX }
        @{ Nombre = "Tomcat"; Interno = "tomcat"; WinSvc = $Script:HTTP_WINSVC_TOMCAT }
    )

    foreach ($svc in $servicios) {
        Write-Host ""
        Write-Host "  ${CYAN} $($svc.Nombre)${NC}"
        Write-Host "  "

        #  1. Paquete / feature instalado 
        $instalado = $false
        $versionStr = "Desconocida"

        if ($svc.Interno -eq "iis") {
            # IIS se instala como feature de Windows, no via choco
            Import-Module ServerManager -ErrorAction SilentlyContinue
            $feat = Get-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue
            if ($feat -and $feat.Installed) {
                $instalado = $true
                $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
                        -ErrorAction SilentlyContinue).VersionString
                $versionStr = if ($iisVer) { $iisVer } else { "IIS instalado" }
            }
        }
        else {
            # Verificar por existencia del servicio Windows - mas fiable que choco en v2.6+
            $svcObj = Get-Service -Name $svc.WinSvc -ErrorAction SilentlyContinue
            if ($svcObj) {
                $instalado = $true
                $paqueteChoco = http_nombre_paquete $svc.Interno
                $chocoInfo = choco list $paqueteChoco 2>$null |
                Where-Object { $_ -match "^$paqueteChoco\s" }
                $versionStr = if ($chocoInfo) { ($chocoInfo -split '\s+')[1] } else { "instalado" }
            }
        }

        if ($instalado) {
            Write-Host ("  ${GREEN}[OK]${NC}  {0,-15}: {1}" -f "Instalado", $versionStr)
        }
        else {
            Write-Host ("  ${GRAY}[--]${NC}  {0,-15}: No instalado" -f "Instalado")
            Write-Host ""
            continue
        }

        #  2. Estado del servicio Windows 
        $winSvc = Get-Service -Name $svc.WinSvc -ErrorAction SilentlyContinue
        if ($null -ne $winSvc -and $winSvc.Status -eq 'Running') {
            $cimSvc2 = Get-CimInstance Win32_Service -Filter "Name='$($svc.WinSvc)'" `
                -ErrorAction SilentlyContinue
            $pidStr = if ($cimSvc2) { "PID: $($cimSvc2.ProcessId)" } else { "" }
            Write-Host ("  ${GREEN}[OK]${NC}  {0,-15}: ACTIVO ({1})" -f "Servicio", $pidStr)
        }
        elseif ($null -ne $winSvc) {
            Write-Host ("  ${RED}[!!]${NC}  {0,-15}: INACTIVO ({1})" -f "Servicio", $winSvc.Status)
        }
        else {
            Write-Host ("  ${RED}[!!]${NC}  {0,-15}: Servicio no encontrado" -f "Servicio")
        }

        #  3. Inicio automatico 
        if ($null -ne $winSvc) {
            if ($winSvc.StartType -eq 'Automatic') {
                Write-Host ("  ${GREEN}[OK]${NC}  {0,-15}: Automatico" -f "Inicio boot")
            }
            else {
                Write-Host ("  ${YELLOW}[!!]${NC}  {0,-15}: $($winSvc.StartType)" -f "Inicio boot")
            }
        }

        #  4. Puerto en escucha 
        $puerto = _http_obtener_puerto_activo $svc.WinSvc
        if ($puerto -gt 0) {
            Write-Host ("  ${GREEN}[OK]${NC}  {0,-15}: {1}/tcp en escucha" -f "Puerto", $puerto)
        }
        else {
            Write-Host ("  ${YELLOW}[--]${NC}  {0,-15}: Sin puerto en escucha" -f "Puerto")
        }

        #  5. Webroot 
        $webroot = http_get_webroot $svc.Interno
        if (Test-Path $webroot -PathType Container) {
            $archivos = (Get-ChildItem $webroot -File -ErrorAction SilentlyContinue).Count
            Write-Host ("  ${GREEN}[OK]${NC}  {0,-15}: {1} ({2} archivo(s))" -f "Webroot", $webroot, $archivos)
        }
        else {
            Write-Host ("  ${GRAY}[--]${NC}  {0,-15}: $webroot (no existe)" -f "Webroot")
        }

        Write-Host ""
    }

    draw_line
    aputs_info "Para instalar un servicio: opcion 2) del menu principal"
    aputs_info "Para iniciar un servicio:  Start-Service -Name <nombre>"
}

function http_verificar_puerto_disponible {
    Clear-Host
    draw_header "Verificar Disponibilidad de Puerto"
    Write-Host ""

    # Solicitar puerto con validacion de formato basico
    $puerto = 0
    do {
        $entrada = agets "Puerto a verificar (ej: 8080)"
        if ($entrada -notmatch '^\d+$') {
            aputs_error "Ingrese un numero de puerto valido"
            Write-Host ""
            continue
        }
        $puerto = [int]$entrada
        if ($puerto -lt 1 -or $puerto -gt 65535) {
            aputs_error "Puerto fuera de rango (1-65535)"
            $puerto = 0
        }
    } while ($puerto -eq 0)

    Write-Host ""
    draw_line
    aputs_info "Diagnostico del puerto ${puerto}/tcp:"
    Write-Host ""

    #  1. Estado de uso 
    if (http_puerto_en_uso $puerto) {
        $proceso = http_quien_usa_puerto $puerto
        Write-Host "  ${RED}[OCUPADO]${NC}  Puerto $puerto esta en uso por: $proceso"
        Write-Host ""
        aputs_info "Detalle de la conexion:"
        Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host ("    Estado: {0}  |  Direccion: {1}:{2}" -f $_.State, $_.LocalAddress, $_.LocalPort)
        }
    }
    else {
        Write-Host "  ${GREEN}[LIBRE]${NC}    Puerto $puerto esta disponible"
    }

    Write-Host ""

    #  2. Estado en el Firewall de Windows 
    aputs_info "Estado en Windows Firewall:"
    Write-Host ""
    $regla = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } |
    ForEach-Object {
        $portFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if ($portFilter -and $portFilter.LocalPort -contains "$puerto") {
            $_
        }
    } | Select-Object -First 1

    if ($regla) {
        Write-Host "  ${GREEN}[ABIERTO]${NC}  Puerto $puerto permitido - Regla: $($regla.DisplayName)"
    }
    else {
        Write-Host "  ${YELLOW}[CERRADO]${NC} Puerto $puerto sin regla de entrada en Windows Firewall"
        aputs_info  "  Para abrirlo: New-NetFirewallRule -DisplayName 'HTTP $puerto' -Direction Inbound -Protocol TCP -LocalPort $puerto -Action Allow"
    }

    Write-Host ""

    #  3. Clasificacion del puerto 
    aputs_info "Clasificacion:"
    Write-Host ""
    if ($puerto -lt 1024) {
        Write-Host "    Tipo      : Puerto privilegiado (sistema)"
    }
    elseif ($puerto -le 49151) {
        Write-Host "    Tipo      : Puerto registrado (aplicaciones)"
    }
    else {
        Write-Host "    Tipo      : Puerto dinamico/efimero"
    }

    if ($Script:HTTP_PUERTOS_RESERVADOS -contains $puerto) {
        Write-Host "    ${RED}Reservado${NC}  : Si - usado por otro servicio del sistema"
    }
    else {
        Write-Host "    Reservado : No - disponible para servicios HTTP"
    }
}

function http_verificar_usuario_servicio {
    Clear-Host
    draw_header "Verificar Usuario Dedicado de Servicio"
    Write-Host ""
    aputs_info "Servicios disponibles:"
    Write-Host "    1) IIS"
    Write-Host "    2) Apache (httpd)"
    Write-Host "    3) Nginx"
    Write-Host "    4) Tomcat"
    Write-Host ""

    $opcion = ""
    do {
        $opcion = agets "Servicio a verificar [1-4]"
    } while (-not (http_validar_opcion_menu $opcion 4))

    $servicio = switch ($opcion) {
        "1" { "iis" }
        "2" { "apache" }
        "3" { "nginx" }
        "4" { "tomcat" }
    }

    $usuario = http_get_usuario_servicio $servicio
    $webroot = http_get_webroot $servicio

    Write-Host ""
    draw_line
    Write-Host "  ${CYAN}Verificando usuario '$usuario' para $servicio${NC}"
    draw_line
    Write-Host ""

    #  1. Existencia del usuario 
    $userObj = Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue

    # IIS usa cuenta especial IUSR (no es local user regular)
    if ($servicio -eq "iis") {
        Write-Host "  ${CYAN}[INFO]${NC}  IIS usa la cuenta integrada IUSR (NT AUTHORITY\IUSR)"
        aputs_info  "         Esta cuenta es gestionada por Windows automaticamente"
        # Verificar que IUSR existe en el sistema
        $iusr = ([ADSI]"WinNT://./IUSR,user")
        if ($iusr.Name) {
            Write-Host ("  ${GREEN}[OK]${NC}  Usuario existe    : IUSR (cuenta del sistema)")
        }
    }
    elseif ($null -ne $userObj) {
        Write-Host ("  ${GREEN}[OK]${NC}  Usuario existe")
        Write-Host ("        SID      : {0}" -f $userObj.SID)
        Write-Host ("        Habilitado: {0}" -f $userObj.Enabled)
        Write-Host ("        Descripcion: {0}" -f $userObj.Description)
        Write-Host ""

        #  2. Verificar que el usuario no puede iniciar sesion interactiva 
        # En Windows esto se controla con "User cannot log on" o
        # politica de "Deny log on locally"
        if (-not $userObj.UserMayNotChangePassword -and $userObj.PasswordNeverExpires) {
            aputs_info "El usuario tiene contrasena que no expira (tipico en cuentas de servicio)"
        }

        # Verificar si el usuario tiene shell/logon restringido
        # En Windows la restriccion es via GPO o configuracion de cuenta
        # check_user_cannotlogin: PasswordLastSet == null indica cuenta de servicio
        $wmiUser = Get-CimInstance Win32_UserAccount -Filter "Name='$usuario'" `
            -ErrorAction SilentlyContinue
        if ($wmiUser -and -not $wmiUser.LocalAccount) {
            Write-Host "  ${YELLOW}[!!]${NC}  El usuario no es local - verificar manualmente"
        }
        else {
            Write-Host "  ${GREEN}[OK]${NC}  Usuario local - sin acceso de red por defecto"
        }
    }
    else {
        Write-Host "  ${YELLOW}[--]${NC}  Usuario '$usuario' no existe en el sistema"
        aputs_info  "         Se creara automaticamente al instalar el servicio (opcion 2)"
    }

    #  3. Propiedad del webroot 
    Write-Host ""
    if (Test-Path $webroot -PathType Container) {
        $acl = Get-Acl $webroot -ErrorAction SilentlyContinue
        $propietario = $acl.Owner
        Write-Host ("  ${GREEN}[OK]${NC}  Webroot         : $webroot")
        Write-Host ("        Propietario : $propietario")
        # Verificar que el usuario del servicio tiene permisos de lectura
        $acceso = $acl.Access | Where-Object {
            $_.IdentityReference -match $usuario -and
            $_.FileSystemRights -match "Read"
        }
        if ($acceso) {
            Write-Host "  ${GREEN}[OK]${NC}  Permisos lectura: El usuario tiene acceso al webroot"
        }
        else {
            Write-Host "  ${YELLOW}[!!]${NC}  El usuario '$usuario' puede no tener permisos en el webroot"
            aputs_info  "         Use icacls `"$webroot`" /grant `"${usuario}:(R)`""
        }
    }
    else {
        Write-Host "  ${YELLOW}[--]${NC}  Webroot no existe: $webroot"
    }

    #  4. Acceso a directorios sensibles 
    Write-Host ""
    aputs_info "Verificacion de acceso a directorios sensibles:"
    Write-Host ""
    $dirsSensibles = @("C:\Windows\System32", "C:\Users\Administrator", "C:\Windows\NTDS")
    foreach ($dir in $dirsSensibles) {
        if (Test-Path $dir) {
            $acl = Get-Acl $dir -ErrorAction SilentlyContinue
            $acceso = $acl.Access | Where-Object {
                $_.IdentityReference -match $usuario -and
                $_.AccessControlType -eq "Allow"
            }
            if ($acceso) {
                Write-Host ("  ${YELLOW}[!!]${NC}  {0,-35} accesible (revisar ACL)" -f $dir)
            }
            else {
                Write-Host ("  ${GREEN}[OK]${NC}  {0,-35} bloqueado correctamente" -f $dir)
            }
        }
    }

    Write-Host ""
    draw_line
}

function http_menu_verificar {
    while ($true) {
        Clear-Host
        draw_header "Verificacion de Servicios HTTP"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Panel general de servicios"
        Write-Host "  ${BLUE}2)${NC} Verificar disponibilidad de puerto"
        Write-Host "  ${BLUE}3)${NC} Verificar usuario dedicado de servicio"
        Write-Host "  ${BLUE}4)${NC} Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" {
                http_verificar_estado
                Write-Host ""
                pause_menu
            }
            "2" {
                http_verificar_puerto_disponible
                Write-Host ""
                pause_menu
            }
            "3" {
                http_verificar_usuario_servicio
                Write-Host ""
                pause_menu
            }
            "4" { return }
            default {
                aputs_error "Opcion invalida. Seleccione entre 1 y 4"
                Start-Sleep -Seconds 2
            }
        }
    }
}