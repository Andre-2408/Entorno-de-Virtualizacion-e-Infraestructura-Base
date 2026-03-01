# ftp-windows.ps1
# Instalacion y configuracion de servidor FTP con IIS en Windows Server
# Sistema: Windows Server 2019 / 2022
# Depende de: common-functions.ps1 (si se usa desde main.ps1)
#             O se ejecuta de forma independiente.

# ─────────────────────────────────────────────────────────────────────────────
# FUNCIONES DE SALIDA (se definen solo si no existen, por compatibilidad)
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Get-Command Write-OK -ErrorAction SilentlyContinue)) {
    function Write-OK  { param($m) Write-Host "  [OK] $m"     -ForegroundColor Green  }
    function Write-Err { param($m) Write-Host "  [ERROR] $m"  -ForegroundColor Red; throw $m }
    function Write-Inf { param($m) Write-Host "  [INFO] $m"   -ForegroundColor Cyan   }
    function Write-Wrn { param($m) Write-Host "  [AVISO] $m"  -ForegroundColor Yellow }
    function Pausar    { Write-Host ""; Read-Host "  Presiona ENTER para continuar" | Out-Null }
}

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES GLOBALES
# ─────────────────────────────────────────────────────────────────────────────
$FTP_ROOT         = "C:\FTP"
$FTP_COMPARTIDO   = "$FTP_ROOT\compartido"   # directorios compartidos reales
$FTP_USUARIOS     = "$FTP_ROOT\LocalUser"    # raices FTP por usuario (IIS isolation)
$FTP_ANONIMO      = "$FTP_ROOT\LocalUser\Public"  # raiz para usuarios anonimos

$FTP_SITIO        = "FTP_Servidor"
$FTP_PUERTO       = 21

$GRP_REPROBADOS   = "reprobados"
$GRP_RECURSADORES = "recursadores"
$GRP_FTP          = "ftpusers"

$FTP_GROUPS_FILE      = "C:\FTP\ftp_groups.txt"   # grupos gestionables dinamicamente
$script:LISTEN_ADDRESS = ""

# ─────────────────────────────────────────────────────────────────────────────
# FUNCIONES AUXILIARES
# ─────────────────────────────────────────────────────────────────────────────

# Verificar que se ejecuta como Administrador
function _FTP-VerificarAdmin {
    $cur = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $cur.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "  Ejecuta este script como Administrador." -ForegroundColor Red
        exit 1
    }
}

# Crear directorio si no existe
function _FTP-NuevoDir {
    param([string]$Ruta)
    if (-not (Test-Path $Ruta)) {
        New-Item -ItemType Directory -Path $Ruta -Force | Out-Null
    }
}

# Crear una union NTFS (mklink /J) equivalente al bind mount de Linux.
# Las uniones son transparentes: el usuario FTP ve los contenidos del destino
# como si estuvieran en la ruta de la union.
function _FTP-NuevaJunction {
    param([string]$RutaJunction, [string]$RutaDestino)

    if (Test-Path $RutaJunction) {
        $item = Get-Item $RutaJunction -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Write-Wrn "La union '$RutaJunction' ya existe."
            return
        }
        # Existe como directorio normal; eliminarlo antes de crear la union
        Remove-Item $RutaJunction -Force -Recurse
    }

    cmd /c "mklink /J `"$RutaJunction`" `"$RutaDestino`"" | Out-Null
    Write-Inf "Union NTFS: $RutaJunction  ->  $RutaDestino"
}

# Seleccionar interfaz de red interna para IIS FTP.
# Escribe la IP elegida en $script:LISTEN_ADDRESS.
function _FTP-SeleccionarInterfaz {
    $adapters = @(Get-NetIPAddress -AddressFamily IPv4 |
                  Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
                  Select-Object InterfaceAlias, IPAddress)

    if ($adapters.Count -eq 0) {
        Write-Wrn "No se detectaron interfaces con IP. FTP escuchara en todas."
        $script:LISTEN_ADDRESS = ""
        return
    }

    Write-Host ""
    Write-Host "  Interfaces de red disponibles:"
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        Write-Host "    $($i+1)) $($adapters[$i].InterfaceAlias)  ->  $($adapters[$i].IPAddress)"
    }
    Write-Host "    0) Escuchar en TODAS las interfaces"
    Write-Host ""

    do {
        $sel = Read-Host "  Seleccione la interfaz de red interna para FTP"
        if ($sel -eq "0") {
            $script:LISTEN_ADDRESS = ""
            Write-Inf "FTP escuchara en todas las interfaces"
            break
        } elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $adapters.Count) {
            $script:LISTEN_ADDRESS = $adapters[[int]$sel - 1].IPAddress
            Write-OK "Interfaz seleccionada: $($adapters[[int]$sel - 1].InterfaceAlias)  ($($script:LISTEN_ADDRESS))"
            break
        } else {
            Write-Wrn "Seleccion invalida."
        }
    } while ($true)
}

# Leer grupos FTP registrados desde FTP_GROUPS_FILE.
function _FTP-GruposDisponibles {
    if (-not (Test-Path $FTP_GROUPS_FILE)) { return @() }
    @(Get-Content $FTP_GROUPS_FILE | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' })
}

# Eliminar una union NTFS sin borrar el contenido del directorio destino
function _FTP-EliminarJunction {
    param([string]$RutaJunction)
    if (Test-Path $RutaJunction) {
        $item = Get-Item $RutaJunction -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            # Remove-Item sobre una junction elimina el punto de enlace, no el contenido
            Remove-Item $RutaJunction -Force
            Write-Inf "Union NTFS eliminada: $RutaJunction"
        }
    }
}

# Asignar permiso NTFS a una identidad (usuario o grupo local)
function _FTP-AsignarPermiso {
    param(
        [string]$Ruta,
        [string]$Identidad,
        [string]$Derechos    = "Modify",
        [string]$Herencia    = "ContainerInherit,ObjectInherit",
        [string]$Tipo        = "Allow"
    )
    $acl        = Get-Acl $Ruta
    $derechoObj = [System.Security.AccessControl.FileSystemRights]$Derechos
    $herenciaObj= [System.Security.AccessControl.InheritanceFlags]$Herencia
    $propObj    = [System.Security.AccessControl.PropagationFlags]"None"
    $tipoObj    = [System.Security.AccessControl.AccessControlType]$Tipo

    $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identidad, $derechoObj, $herenciaObj, $propObj, $tipoObj
    )
    $acl.SetAccessRule($regla)
    Set-Acl -Path $Ruta -AclObject $acl
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. VERIFICAR ESTADO DEL SERVIDOR FTP
# ─────────────────────────────────────────────────────────────────────────────
function FTP-Verificar {
    Clear-Host
    Write-Host ""
    Write-Host "  === Verificando servidor FTP (IIS) ===" -ForegroundColor Cyan
    Write-Host ""

    # Caracteristica IIS FTP
    $feat = Get-WindowsFeature -Name "Web-Ftp-Server" -ErrorAction SilentlyContinue
    if ($feat -and $feat.Installed) {
        Write-OK "Caracteristica 'Web-Ftp-Server' instalada"
    } else {
        Write-Wrn "IIS FTP Server NO esta instalado"
    }

    # Servicio FTPSVC
    Write-Host ""
    $svc = Get-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host "  Servicio FTPSVC: " -NoNewline
        Write-Host $svc.Status -ForegroundColor $color
    } else {
        Write-Wrn "Servicio FTPSVC no encontrado"
    }

    # Sitio FTP en IIS
    Write-Host ""
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $sitio = Get-WebSite -Name $FTP_SITIO -ErrorAction SilentlyContinue
        if ($sitio) {
            Write-OK "Sitio '$FTP_SITIO'  Estado: $($sitio.State)  Puerto: $FTP_PUERTO"
            Write-Host "    Ruta fisica: $($sitio.PhysicalPath)" -ForegroundColor Gray
        } else {
            Write-Wrn "Sitio FTP '$FTP_SITIO' no configurado en IIS"
        }
    } catch {
        Write-Wrn "Modulo WebAdministration no disponible (IIS no instalado)"
    }

    # Grupos locales
    Write-Host ""
    Write-Host "  Grupos FTP:" -ForegroundColor White
    foreach ($grp in (@($GRP_FTP) + @(_FTP-GruposDisponibles))) {
        $g = Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue
        if ($g) {
            $miembros = (Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue) |
                        ForEach-Object { ($_.Name -split '\\')[-1] }
            Write-OK "$grp : $($miembros -join ', ')"
        } else {
            Write-Wrn "$grp : grupo no existe"
        }
    }

    # Estructura de directorios
    Write-Host ""
    Write-Host "  Estructura FTP ($FTP_ROOT):" -ForegroundColor White
    if (Test-Path $FTP_ROOT) {
        Get-ChildItem $FTP_ROOT -Recurse -Depth 2 |
            ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Gray }
    } else {
        Write-Wrn "Directorio FTP no configurado ($FTP_ROOT)"
    }

    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. INSTALAR IIS FTP (IDEMPOTENTE)
# ─────────────────────────────────────────────────────────────────────────────
function FTP-Instalar {
    Write-Host ""
    Write-Host "  === Instalacion de IIS FTP Server ===" -ForegroundColor Cyan
    Write-Host ""

    $caracteristicas = @(
        "Web-WebServer",
        "Web-Ftp-Server",
        "Web-Ftp-Service",
        "Web-Ftp-Extensibility",
        "Web-Mgmt-Tools",
        "Web-Mgmt-Console"
    )

    $porInstalar = @()
    foreach ($feat in $caracteristicas) {
        $info = Get-WindowsFeature -Name $feat -ErrorAction SilentlyContinue
        if ($info -and $info.Installed) {
            Write-Wrn "Caracteristica '$feat' ya instalada"
        } else {
            $porInstalar += $feat
        }
    }

    if ($porInstalar.Count -gt 0) {
        Write-Inf "Instalando: $($porInstalar -join ', ')"
        Install-WindowsFeature -Name $porInstalar -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-OK "Caracteristicas instaladas correctamente"
    } else {
        Write-OK "Todas las caracteristicas ya estaban instaladas"
    }

    # Asegurar que el servicio FTP arranque automaticamente
    Set-Service  -Name "FTPSVC" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Write-OK "Servicio FTPSVC configurado como automatico e iniciado"

    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CONFIGURAR SERVIDOR FTP
# Crea grupos, estructura de directorios, sitio IIS FTP y reglas de acceso.
# ─────────────────────────────────────────────────────────────────────────────
function FTP-Configurar {
    Write-Host ""
    Write-Host "  === Configuracion del servidor FTP ===" -ForegroundColor Cyan
    Write-Host ""

    Import-Module WebAdministration -ErrorAction Stop

    # ── 3.1 Inicializar lista de grupos FTP ──────────────────────────────────
    $dirGruposFile = Split-Path $FTP_GROUPS_FILE
    if (-not (Test-Path $dirGruposFile)) { New-Item -ItemType Directory -Path $dirGruposFile -Force | Out-Null }
    if (-not (Test-Path $FTP_GROUPS_FILE)) {
        Set-Content -Path $FTP_GROUPS_FILE -Value @($GRP_REPROBADOS, $GRP_RECURSADORES)
        Write-OK "Lista de grupos FTP inicializada: $GRP_REPROBADOS, $GRP_RECURSADORES"
    } else {
        Write-Wrn "Lista de grupos FTP ya existe ($FTP_GROUPS_FILE)"
    }

    # ── 3.2 Crear grupos locales ──────────────────────────────────────────────
    Write-Inf "Creando grupos locales..."
    foreach ($grp in (@($GRP_FTP) + @(_FTP-GruposDisponibles))) {
        $existe = Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue
        if ($existe) {
            Write-Wrn "Grupo '$grp' ya existe"
        } else {
            New-LocalGroup -Name $grp -Description "Grupo FTP: $grp" | Out-Null
            Write-OK "Grupo '$grp' creado"
        }
    }

    # ── 3.3 Crear estructura de directorios ───────────────────────────────────
    Write-Inf "Creando estructura de directorios FTP..."

    _FTP-NuevoDir "$FTP_COMPARTIDO\general"
    _FTP-NuevoDir $FTP_USUARIOS
    _FTP-NuevoDir $FTP_ANONIMO
    _FTP-NuevaJunction "$FTP_ANONIMO\general" "$FTP_COMPARTIDO\general"

    foreach ($grp in @(_FTP-GruposDisponibles)) {
        _FTP-NuevoDir "$FTP_COMPARTIDO\$grp"
    }

    # ── 3.4 Permisos NTFS en directorios compartidos ──────────────────────────
    Write-Inf "Configurando permisos NTFS..."

    _FTP-AsignarPermiso -Ruta "$FTP_COMPARTIDO\general" `
                        -Identidad $GRP_FTP -Derechos "Modify"

    foreach ($grp in @(_FTP-GruposDisponibles)) {
        _FTP-AsignarPermiso -Ruta "$FTP_COMPARTIDO\$grp" `
                            -Identidad $grp -Derechos "Modify"
    }

    Write-OK "Permisos NTFS configurados"

    # ── 3.5 Seleccionar interfaz de red ───────────────────────────────────────
    Write-Inf "Seleccionando interfaz de red para FTP..."
    _FTP-SeleccionarInterfaz

    # ── 3.6 Crear o verificar el sitio FTP en IIS ─────────────────────────────
    Write-Inf "Configurando sitio FTP en IIS..."

    $sitioExiste = Get-WebSite -Name $FTP_SITIO -ErrorAction SilentlyContinue
    if ($sitioExiste) {
        Write-Wrn "Sitio '$FTP_SITIO' ya existe; actualizando configuracion."
    } else {
        New-WebFtpSite -Name $FTP_SITIO -Port $FTP_PUERTO -PhysicalPath $FTP_ROOT -Force
        Write-OK "Sitio FTP '$FTP_SITIO' creado en puerto $FTP_PUERTO"
    }

    # Vincular a la interfaz interna seleccionada
    if ($script:LISTEN_ADDRESS) {
        try {
            Remove-WebBinding -Name $FTP_SITIO -Protocol "ftp" -IPAddress "*" `
                              -Port $FTP_PUERTO -ErrorAction SilentlyContinue
            $bindingExiste = Get-WebBinding -Name $FTP_SITIO -Protocol "ftp" `
                                            -IPAddress $script:LISTEN_ADDRESS -Port $FTP_PUERTO `
                                            -ErrorAction SilentlyContinue
            if (-not $bindingExiste) {
                New-WebBinding -Name $FTP_SITIO -Protocol "ftp" `
                               -Port $FTP_PUERTO -IPAddress $script:LISTEN_ADDRESS
            }
            Write-OK "FTP vinculado a la interfaz interna: $($script:LISTEN_ADDRESS):$FTP_PUERTO"
        } catch {
            Write-Wrn "No se pudo actualizar el binding IIS: $_"
        }
    }

    $sitioPath = "IIS:\Sites\$FTP_SITIO"

    # ── SSL desactivado (entorno de laboratorio) ──────────────────────────────
    Set-ItemProperty $sitioPath -Name "ftpServer.security.ssl.controlChannelPolicy" -Value 0
    Set-ItemProperty $sitioPath -Name "ftpServer.security.ssl.dataChannelPolicy"    -Value 0

    # ── Autenticacion ─────────────────────────────────────────────────────────
    # Anonima: habilitada (acceso sin credenciales a carpeta Public\)
    Set-ItemProperty $sitioPath `
        -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true

    # Basica: habilitada (usuarios locales de Windows)
    Set-ItemProperty $sitioPath `
        -Name "ftpServer.security.authentication.basicAuthentication.enabled" -Value $true

    # ── Aislamiento de usuarios (User Isolation) ──────────────────────────────
    # Modo 3 = IsolateAllDirectories:
    #   - Anonimos   -> LocalUser\Public\
    #   - Usuario X  -> LocalUser\X\
    # Cada usuario queda confinado en su directorio y ve exactamente:
    #   /general/  /grupo/  /nombreusuario/
    Set-ItemProperty $sitioPath -Name "ftpServer.userIsolation.mode" -Value 3

    # ── Reglas de autorizacion FTP ────────────────────────────────────────────
    Write-Inf "Configurando reglas de autorizacion FTP..."

    # Limpiar reglas existentes para evitar duplicados
    Clear-WebConfiguration "system.ftpServer/security/authorization" `
        -PSPath $sitioPath -ErrorAction SilentlyContinue

    # Regla 1: todos (incluyendo anonimos) -> solo lectura
    Add-WebConfiguration "system.ftpServer/security/authorization" `
        -PSPath $sitioPath `
        -Value @{
            accessType  = "Allow"
            users       = "*"
            roles       = ""
            permissions = 1        # 1 = Read
        }

    # Regla 2: grupo ftpusers (usuarios autenticados) -> lectura y escritura
    Add-WebConfiguration "system.ftpServer/security/authorization" `
        -PSPath $sitioPath `
        -Value @{
            accessType  = "Allow"
            users       = ""
            roles       = $GRP_FTP
            permissions = 3        # 3 = Read + Write
        }

    Write-OK "Reglas de autorizacion configuradas"

    # ── Modo pasivo ───────────────────────────────────────────────────────────
    Set-ItemProperty $sitioPath -Name "ftpServer.firewallSupport.pasvMinPort" -Value 10090
    Set-ItemProperty $sitioPath -Name "ftpServer.firewallSupport.pasvMaxPort" -Value 10100

    # ── Mensaje de bienvenida ─────────────────────────────────────────────────
    Set-ItemProperty $sitioPath `
        -Name "ftpServer.messages.bannerMessage" `
        -Value "Servidor FTP - Acceso restringido a usuarios autorizados"

    # ── 3.5 Reglas en Windows Firewall ───────────────────────────────────────
    Write-Inf "Configurando Firewall de Windows..."

    if (-not (Get-NetFirewallRule -DisplayName "FTP Server (TCP 21)" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName "FTP Server (TCP 21)" `
            -Direction Inbound -Protocol TCP -LocalPort 21 `
            -Action Allow -Profile Any | Out-Null
        Write-OK "Regla de firewall FTP (TCP/21) creada"
    }

    if (-not (Get-NetFirewallRule -DisplayName "FTP Pasivo (TCP 10090-10100)" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName "FTP Pasivo (TCP 10090-10100)" `
            -Direction Inbound -Protocol TCP -LocalPort "10090-10100" `
            -Action Allow -Profile Any | Out-Null
        Write-OK "Regla de firewall FTP pasivo creada"
    }

    # ── Iniciar sitio FTP ─────────────────────────────────────────────────────
    Start-WebSite -Name $FTP_SITIO -ErrorAction SilentlyContinue
    Restart-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Write-OK "Sitio FTP '$FTP_SITIO' activo en puerto $FTP_PUERTO"

    Write-Host ""
    Write-OK "Configuracion del servidor FTP completada."
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# CREAR UN USUARIO FTP (funcion interna)
# Estructura visible al conectarse (User Isolation modo 3):
#   /
#   ├── general\         <- junction a compartido\general       (escritura)
#   ├── reprobados\      <- junction a compartido\reprobados    (escritura de grupo)
#   │    O recursadores\
#   └── <username>\      <- directorio personal                 (escritura)
# ─────────────────────────────────────────────────────────────────────────────
function _FTP-CrearUsuario {
    param(
        [string]$Usuario,
        [string]$Password,
        [string]$Grupo
    )

    $raiz = "$FTP_USUARIOS\$Usuario"

    # Verificar que el grupo exista en Windows
    if (-not (Get-LocalGroup -Name $Grupo -ErrorAction SilentlyContinue)) {
        Write-Err "El grupo '$Grupo' no existe en Windows. Crealo desde 'Gestionar grupos'."
    }

    # Crear usuario local de Windows si no existe
    $usuarioExiste = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
    if ($usuarioExiste) {
        Write-Wrn "El usuario '$Usuario' ya existe en Windows, omitiendo creacion."
    } else {
        $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser `
            -Name              $Usuario `
            -Password          $secPass `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -Description       "Usuario FTP - $Grupo" | Out-Null
        Write-OK "Usuario Windows '$Usuario' creado"
    }

    # Agregar a grupos (ftpusers y el grupo especifico)
    foreach ($grp in @($GRP_FTP, $Grupo)) {
        try {
            Add-LocalGroupMember -Group $grp -Member $Usuario -ErrorAction SilentlyContinue
            Write-Inf "  '$Usuario' agregado al grupo '$grp'"
        } catch {
            Write-Wrn "  '$Usuario' ya pertenecia al grupo '$grp'"
        }
    }

    # ── Crear estructura de directorios ───────────────────────────────────────
    _FTP-NuevoDir $raiz
    _FTP-NuevoDir "$raiz\$Usuario"    # carpeta personal

    # Uniones NTFS: los directorios compartidos aparecen en el directorio del usuario
    _FTP-NuevaJunction "$raiz\general" "$FTP_COMPARTIDO\general"
    _FTP-NuevaJunction "$raiz\$Grupo"  "$FTP_COMPARTIDO\$Grupo"

    # ── Permisos NTFS ─────────────────────────────────────────────────────────
    # Raiz del usuario: puede navegar (ReadAndExecute)
    _FTP-AsignarPermiso -Ruta $raiz -Identidad $Usuario `
                        -Derechos "ReadAndExecute"

    # Carpeta personal: puede leer y escribir (Modify)
    _FTP-AsignarPermiso -Ruta "$raiz\$Usuario" -Identidad $Usuario `
                        -Derechos "Modify"

    Write-OK "Usuario FTP '$Usuario' configurado"
    Write-Host "    Estructura FTP al conectarse:" -ForegroundColor Gray
    Write-Host "      \general\         (escritura compartida con todos)" -ForegroundColor Gray
    Write-Host "      \$Grupo\    (escritura de grupo: $Grupo)" -ForegroundColor Gray
    Write-Host "      \$Usuario\   (carpeta personal)" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CREACION MASIVA DE USUARIOS FTP
# ─────────────────────────────────────────────────────────────────────────────
function FTP-GestionarUsuarios {
    Write-Host ""
    Write-Host "  === Creacion de usuarios FTP ===" -ForegroundColor Cyan
    Write-Host ""

    do {
        $nStr = Read-Host "  Cuantos usuarios desea crear?"
    } while (-not ($nStr -match '^\d+$') -or [int]$nStr -lt 1)

    $nUsuarios = [int]$nStr

    for ($i = 1; $i -le $nUsuarios; $i++) {
        Write-Host ""
        Write-Host "  ─── Usuario $i de $nUsuarios ─────────────────────" -ForegroundColor Cyan

        # Nombre de usuario
        do {
            $usuario = Read-Host "  Nombre de usuario"
        } while ([string]::IsNullOrWhiteSpace($usuario))

        # Contrasena (comparar dos lecturas)
        do {
            $pass1Sec = Read-Host "  Contrasena" -AsSecureString
            $pass2Sec = Read-Host "  Confirmar"  -AsSecureString
            $pass1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                         [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass1Sec))
            $pass2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                         [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass2Sec))

            if     ($pass1 -ne $pass2)     { Write-Wrn "Las contrasenas no coinciden." }
            elseif ($pass1.Length -lt 6)   { Write-Wrn "Minimo 6 caracteres." }
        } while ($pass1 -ne $pass2 -or $pass1.Length -lt 6)

        # Seleccion de grupo (dinamico desde FTP_GROUPS_FILE)
        $gruposFTP = @(_FTP-GruposDisponibles)
        if ($gruposFTP.Count -eq 0) {
            Write-Wrn "No hay grupos FTP configurados. Ve a 'Gestionar grupos' primero."
            Pausar; return
        }

        Write-Host "  Grupos disponibles:"
        for ($gi = 0; $gi -lt $gruposFTP.Count; $gi++) {
            Write-Host "    $($gi+1)) $($gruposFTP[$gi])"
        }
        do {
            $opcGrupo = Read-Host "  Seleccione grupo [1-$($gruposFTP.Count)]"
        } while (-not ($opcGrupo -match '^\d+$') -or [int]$opcGrupo -lt 1 -or [int]$opcGrupo -gt $gruposFTP.Count)

        $grupo = $gruposFTP[[int]$opcGrupo - 1]

        _FTP-CrearUsuario -Usuario $usuario -Password $pass1 -Grupo $grupo
    }

    # Reiniciar FTP para que los cambios de grupo surtan efecto
    Restart-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Write-OK "Proceso completado. Servicio FTP reiniciado."
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. CAMBIAR GRUPO DE UN USUARIO
# Actualiza membresia de grupo y reemplaza la junction del directorio de grupo
# en el directorio del usuario.
# ─────────────────────────────────────────────────────────────────────────────
function FTP-CambiarGrupo {
    Write-Host ""
    Write-Host "  === Cambiar grupo de usuario FTP ===" -ForegroundColor Cyan
    Write-Host ""

    $usuario = Read-Host "  Nombre de usuario"

    $usuarioExiste = Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue
    if (-not $usuarioExiste) {
        Write-Err "El usuario '$usuario' no existe en Windows."
    }

    $raiz = "$FTP_USUARIOS\$usuario"

    # Detectar grupo actual (dinamico)
    $grupoAnterior = ""
    foreach ($g in @(_FTP-GruposDisponibles)) {
        try {
            Get-LocalGroupMember -Group $g -Member $usuario -ErrorAction Stop | Out-Null
            $grupoAnterior = $g; break
        } catch {}
    }

    if (-not $grupoAnterior) {
        Write-Err "El usuario '$usuario' no pertenece a ningun grupo FTP registrado."
    }

    Write-Inf "Grupo actual de '$usuario': $grupoAnterior"

    # Solicitar nuevo grupo (dinamico)
    $gruposFTP = @(_FTP-GruposDisponibles)
    for ($gi = 0; $gi -lt $gruposFTP.Count; $gi++) {
        Write-Host "  $($gi+1)) $($gruposFTP[$gi])"
    }
    do {
        $opcGrupo = Read-Host "  Nuevo grupo [1-$($gruposFTP.Count)]"
    } while (-not ($opcGrupo -match '^\d+$') -or [int]$opcGrupo -lt 1 -or [int]$opcGrupo -gt $gruposFTP.Count)

    $nuevoGrupo = $gruposFTP[[int]$opcGrupo - 1]

    if ($grupoAnterior -eq $nuevoGrupo) {
        Write-Wrn "El usuario ya pertenece al grupo '$nuevoGrupo'. Sin cambios."
        Pausar; return
    }

    Write-Inf "Cambiando '$usuario': $grupoAnterior -> $nuevoGrupo ..."

    # 1. Eliminar la junction del grupo anterior
    _FTP-EliminarJunction "$raiz\$grupoAnterior"

    # 2. Crear la junction al nuevo grupo
    _FTP-NuevaJunction "$raiz\$nuevoGrupo" "$FTP_COMPARTIDO\$nuevoGrupo"

    # 3. Actualizar membresia de grupos Windows
    Remove-LocalGroupMember -Group $grupoAnterior -Member $usuario -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $nuevoGrupo    -Member $usuario -ErrorAction SilentlyContinue

    Write-OK "Usuario '$usuario' movido de '$grupoAnterior' a '$nuevoGrupo'."
    Write-Inf "Directorio de grupo accesible ahora: \$nuevoGrupo\"
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. LISTAR USUARIOS FTP
# ─────────────────────────────────────────────────────────────────────────────
function FTP-ListarUsuarios {
    Write-Host ""
    Write-Host "  === Usuarios FTP registrados ===" -ForegroundColor Cyan
    Write-Host ""

    $miembros = Get-LocalGroupMember -Group $GRP_FTP -ErrorAction SilentlyContinue
    if (-not $miembros) {
        Write-Wrn "No hay usuarios en el grupo '$GRP_FTP'."
        Pausar; return
    }

    $fmt = "  {0,-20} {1,-16} {2,-40}"
    Write-Host ($fmt -f "USUARIO", "GRUPO FTP", "DIRECTORIO RAIZ") -ForegroundColor White
    Write-Host ($fmt -f "────────────────────", "────────────────", "────────────────────────────────────────")

    foreach ($m in $miembros) {
        $usr = ($m.Name -split '\\')[-1]   # quitar prefijo de dominio si existe

        $grp = "(sin grupo)"
        foreach ($g in @(_FTP-GruposDisponibles)) {
            try {
                Get-LocalGroupMember -Group $g -Member $usr -ErrorAction Stop | Out-Null
                $grp = $g; break
            } catch {}
        }

        $raiz = "$FTP_USUARIOS\$usr"
        Write-Host ($fmt -f $usr, $grp, $raiz)
    }

    Write-Host ""
    Write-Host "  Acceso anonimo apunta a: $FTP_ANONIMO" -ForegroundColor Gray
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. REINICIAR SERVICIO FTP
# ─────────────────────────────────────────────────────────────────────────────
function FTP-Reiniciar {
    Write-Inf "Reiniciando servicio FTP (FTPSVC)..."
    Restart-Service -Name "FTPSVC" -ErrorAction Stop
    $svc = Get-Service -Name "FTPSVC"
    Write-OK "FTPSVC reiniciado. Estado: $($svc.Status)"
    Pausar
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. GESTION DE GRUPOS FTP
# Permite agregar o quitar grupos sin tocar el codigo.
# ─────────────────────────────────────────────────────────────────────────────
function _FTP-AgregarGrupoFTP {
    do {
        $nombre = Read-Host "  Nombre del nuevo grupo"
        if ([string]::IsNullOrWhiteSpace($nombre)) {
            Write-Wrn "El nombre no puede estar vacio."
        } elseif ($nombre -notmatch '^[a-z][a-z0-9_-]*$') {
            Write-Wrn "Solo minusculas, digitos, guion o guion_bajo."
        } elseif ((Get-Content $FTP_GROUPS_FILE -ErrorAction SilentlyContinue) -contains $nombre) {
            Write-Wrn "El grupo '$nombre' ya esta en la lista FTP."
        } else { break }
    } while ($true)

    if (-not (Get-LocalGroup -Name $nombre -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $nombre -Description "Grupo FTP: $nombre" | Out-Null
        Write-OK "Grupo '$nombre' creado en Windows"
    } else {
        Write-Wrn "Grupo '$nombre' ya existe en Windows"
    }

    $dirGrupo = "$FTP_COMPARTIDO\$nombre"
    _FTP-NuevoDir $dirGrupo
    _FTP-AsignarPermiso -Ruta $dirGrupo -Identidad $nombre -Derechos "Modify"
    Write-OK "Directorio compartido creado: $dirGrupo"

    $dirFile = Split-Path $FTP_GROUPS_FILE
    if (-not (Test-Path $dirFile)) { New-Item -ItemType Directory -Path $dirFile -Force | Out-Null }
    Add-Content -Path $FTP_GROUPS_FILE -Value $nombre
    Write-OK "Grupo '$nombre' registrado en la lista FTP"
    Pausar
}

function _FTP-QuitarGrupoFTP {
    $grupos = @(_FTP-GruposDisponibles)
    if ($grupos.Count -eq 0) {
        Write-Wrn "No hay grupos en la lista FTP."
        Pausar; return
    }

    Write-Host ""
    for ($i = 0; $i -lt $grupos.Count; $i++) {
        $miembros = (Get-LocalGroupMember -Group $grupos[$i] -ErrorAction SilentlyContinue) |
                    ForEach-Object { ($_.Name -split '\\')[-1] }
        Write-Host "    $($i+1)) $($grupos[$i])  [$($miembros -join ', ')]"
    }
    Write-Host ""

    do {
        $sel = Read-Host "  Seleccione el grupo a quitar de la lista [1-$($grupos.Count)]"
    } while (-not ($sel -match '^\d+$') -or [int]$sel -lt 1 -or [int]$sel -gt $grupos.Count)

    $grupo = $grupos[[int]$sel - 1]
    $nuevo = Get-Content $FTP_GROUPS_FILE | Where-Object { $_ -ne $grupo }
    Set-Content -Path $FTP_GROUPS_FILE -Value $nuevo
    Write-OK "Grupo '$grupo' eliminado de la lista FTP"
    Write-Inf "El grupo de Windows y sus miembros se mantienen intactos."
    Pausar
}

function FTP-GestionarGrupos {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  === Gestion de grupos FTP ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Grupos FTP registrados:"
        $grupos = @(_FTP-GruposDisponibles)
        if ($grupos.Count -eq 0) {
            Write-Host "    (ninguno)"
        } else {
            for ($i = 0; $i -lt $grupos.Count; $i++) {
                $miembros = (Get-LocalGroupMember -Group $grupos[$i] -ErrorAction SilentlyContinue) |
                            ForEach-Object { ($_.Name -split '\\')[-1] }
                Write-Host "    $($i+1)) $($grupos[$i])  [$($miembros -join ', ')]"
            }
        }
        Write-Host ""
        Write-Host "  1) Agregar grupo"
        Write-Host "  2) Quitar grupo de la lista"
        Write-Host "  0) Volver"
        Write-Host ""
        $opc = Read-Host "  Opcion"
        switch ($opc) {
            "1" { _FTP-AgregarGrupoFTP }
            "2" { _FTP-QuitarGrupoFTP  }
            "0" { return }
            default { Write-Wrn "Opcion invalida."; Start-Sleep 1 }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU DEL MODULO FTP
# ─────────────────────────────────────────────────────────────────────────────
function Menu-FTP {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Magenta
        Write-Host "  ║     ADMINISTRACION SERVIDOR FTP          ║" -ForegroundColor Magenta
        Write-Host "  ║     IIS FTP Service - Windows Server     ║" -ForegroundColor Magenta
        Write-Host "  ╠══════════════════════════════════════════╣" -ForegroundColor Magenta
        Write-Host "  ║  1. Verificar estado del servicio        ║" -ForegroundColor Magenta
        Write-Host "  ║  2. Instalar IIS FTP Server              ║" -ForegroundColor Magenta
        Write-Host "  ║  3. Configurar servidor FTP              ║" -ForegroundColor Magenta
        Write-Host "  ║  4. Crear usuarios FTP (masivo)          ║" -ForegroundColor Magenta
        Write-Host "  ║  5. Cambiar grupo de un usuario          ║" -ForegroundColor Magenta
        Write-Host "  ║  6. Listar usuarios FTP                  ║" -ForegroundColor Magenta
        Write-Host "  ║  7. Reiniciar servicio FTP               ║" -ForegroundColor Magenta
        Write-Host "  ║  8. Gestionar grupos FTP                 ║" -ForegroundColor Magenta
        Write-Host "  ║  0. Salir                                ║" -ForegroundColor Magenta
        Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Magenta
        Write-Host ""

        $opc = Read-Host "  Opcion"

        switch ($opc) {
            "1" { FTP-Verificar }
            "2" { FTP-Instalar }
            "3" { FTP-Configurar }
            "4" { FTP-GestionarUsuarios }
            "5" { FTP-CambiarGrupo }
            "6" { FTP-ListarUsuarios }
            "7" { FTP-Reiniciar }
            "8" { FTP-GestionarGrupos }
            "0" { Write-Inf "Saliendo..."; return }
            default { Write-Wrn "Opcion no valida." }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA
# Solo se ejecuta si el script se llama directamente (no si es incluido)
# ─────────────────────────────────────────────────────────────────────────────
if ($MyInvocation.ScriptName -eq $PSCommandPath) {
    _FTP-VerificarAdmin
    Menu-FTP
}
