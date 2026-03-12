#
# InputGuard.ps1
# Validaciones especificas para la gestion de servicios HTTP - Windows Server 2022
#
# Equivalente a InputGuard.sh de la practica Linux.
# Cada funcion devuelve $true (valido) o $false (invalido) e imprime
# mensajes de error con aputs_error / aputs_info.
#
# Uso: . "$PSScriptRoot\InputGuard.ps1"
# Requiere: CoreHelpers.ps1 y HTTPGlobals.ps1 cargados antes
#

#Requires -Version 5.1


function http_validar_puerto {
    param([string]$Puerto)

    # ====== Verificacion 1: Formato - debe ser un entero positivo ================================================
    if ($Puerto -notmatch '^\d+$') {
        aputs_error "El puerto debe ser un numero entero positivo"
        aputs_info  "Ejemplos validos: 80, 8080, 8888"
        return $false
    }

    $p = [int]$Puerto

    # ====== Verificacion 2: Puerto 0 reservado por el kernel ===============================================================
    if ($p -eq 0) {
        aputs_error "El puerto 0 esta reservado por el sistema operativo"
        return $false
    }

    # ====== Verificacion 3: Rango TCP valido ===============================================================================================================
    if ($p -lt 1 -or $p -gt 65535) {
        aputs_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return $false
    }

    # ====== Verificacion 4: Puertos privilegiados <1024 - advertencia ====================================
    if ($p -lt 1024) {
        aputs_warning "El puerto $p es un puerto privilegiado (requiere permisos elevados)"
        aputs_info    "Se recomienda usar puertos >= 1024 para servicios de prueba"
    }

    # ====== Verificacion 5: Puertos reservados para otros servicios ==========================================
    if ($Script:HTTP_PUERTOS_RESERVADOS -contains $p) {
        aputs_error "El puerto $p esta reservado para otro servicio del sistema"
        aputs_info  "Puertos reservados: $($Script:HTTP_PUERTOS_RESERVADOS -join ', ')"
        aputs_info  "Elija un puerto diferente"
        return $false
    }

    # ====== Verificacion 6: Puerto actualmente en uso =======================================================================================
    if (http_puerto_en_uso $p) {
        $proceso = http_quien_usa_puerto $p
        # Si el proceso es un servicio HTTP propio no es conflicto real
        if ($proceso -match '(httpd|nginx|tomcat|w3wp|iisexpress)') {
            aputs_warning "Puerto $p en uso por '$proceso' (servicio HTTP)"
            aputs_info    "Se aceptara - el instalador sobreescribira la configuracion"
            aputs_success "Puerto $p aceptado"
            return $true
        }
        aputs_error "El puerto $p ya esta en uso por: $proceso"
        aputs_info  "Use 'Get-NetTCPConnection -LocalPort $p' para ver detalles"
        aputs_info  "Elija un puerto diferente"
        return $false
    }

    aputs_success "Puerto $p disponible"
    return $true
}

function http_validar_puerto_cambio {
    param([string]$PuertoNuevo, [string]$PuertoActual)

    if ($PuertoNuevo -notmatch '^\d+$') {
        aputs_error "El puerto debe ser un numero entero positivo"
        return $false
    }

    $pn = [int]$PuertoNuevo
    $pa = [int]$PuertoActual

    if ($pn -eq 0) {
        aputs_error "El puerto 0 esta reservado por el sistema operativo"
        return $false
    }

    if ($pn -lt 1 -or $pn -gt 65535) {
        aputs_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return $false
    }

    # No tiene sentido cambiar al mismo puerto
    if ($pn -eq $pa) {
        aputs_warning "El puerto nuevo ($pn) es igual al actual"
        aputs_info    "Seleccione un puerto diferente al actual ($pa)"
        return $false
    }

    if ($Script:HTTP_PUERTOS_RESERVADOS -contains $pn) {
        aputs_error "El puerto $pn esta reservado para otro servicio"
        return $false
    }

    if (http_puerto_en_uso $pn) {
        $proceso = http_quien_usa_puerto $pn
        aputs_error "El puerto $pn ya esta en uso por: $proceso"
        return $false
    }

    aputs_success "Puerto $pn disponible para el cambio"
    return $true
}

function http_validar_servicio {
    param([string]$Entrada)

    if ([string]::IsNullOrWhiteSpace($Entrada)) {
        aputs_error "Debe seleccionar un servicio"
        aputs_info  "Opciones: 1) IIS  2) Apache (httpd)  3) Nginx  4) Tomcat"
        return $false
    }

    switch ($Entrada.ToLower()) {
        { $_ -in '1', 'iis' } { return $true }
        { $_ -in '2', 'apache', 'httpd' } { return $true }
        { $_ -in '3', 'nginx' } { return $true }
        { $_ -in '4', 'tomcat' } { return $true }
        default {
            aputs_error "Servicio no reconocido: '$Entrada'"
            aputs_info  "Servicios disponibles en Windows Server:"
            Write-Host  "    1) IIS     - servidor web nativo de Windows"
            Write-Host  "    2) Apache  - httpd para Windows (Chocolatey)"
            Write-Host  "    3) Nginx   - servidor web / proxy inverso"
            Write-Host  "    4) Tomcat  - servidor de aplicaciones Java"
            return $false
        }
    }
}

function http_validar_opcion_menu {
    param([string]$Opcion, [int]$MaxOpciones)

    if ($Opcion -notmatch '^\d+$') {
        aputs_error "Opcion invalida: '$Opcion'"
        aputs_info  "Ingrese un numero entre 1 y $MaxOpciones"
        return $false
    }

    $op = [int]$Opcion
    if ($op -lt 1 -or $op -gt $MaxOpciones) {
        aputs_error "Opcion fuera de rango: $op"
        aputs_info  "Rango valido: 1 a $MaxOpciones"
        return $false
    }

    return $true
}

function http_validar_version {
    param([string]$VersionElegida, [string[]]$VersionesDisponibles)

    if ([string]::IsNullOrWhiteSpace($VersionElegida)) {
        aputs_error "Debe especificar una version"
        return $false
    }

    if ($VersionesDisponibles -contains $VersionElegida) {
        return $true
    }

    aputs_error "La version '$VersionElegida' no esta disponible"
    aputs_info  "Versiones disponibles:"
    $VersionesDisponibles | ForEach-Object { Write-Host "    - $_" }
    return $false
}

function http_validar_indice_version {
    param([string]$Indice, [int]$TotalVersiones)

    if ($Indice -notmatch '^\d+$') {
        aputs_error "Debe ingresar el numero de la version deseada"
        return $false
    }

    $idx = [int]$Indice
    if ($idx -lt 1 -or $idx -gt $TotalVersiones) {
        aputs_error "Seleccion fuera de rango: $idx"
        aputs_info  "Seleccione un numero entre 1 y $TotalVersiones"
        return $false
    }

    return $true
}

function http_validar_metodo_http {
    param([string]$Metodo)

    if ([string]::IsNullOrWhiteSpace($Metodo)) {
        aputs_error "Debe especificar un metodo HTTP"
        aputs_info  "Metodos disponibles: TRACE, TRACK, DELETE, PUT, OPTIONS, PATCH"
        return $false
    }

    $m = $Metodo.ToUpper()

    switch ($m) {
        { $_ -in 'GET', 'POST' } {
            # Metodos esenciales - nunca deben restringirse
            aputs_error "El metodo $m es esencial y no debe restringirse"
            aputs_info  "Restriccion tipica: TRACE, TRACK, DELETE, PUT no son necesarios"
            return $false
        }
        { $_ -in 'TRACE', 'TRACK', 'DELETE', 'PUT', 'OPTIONS', 'PATCH', 'CONNECT', 'HEAD' } {
            return $true
        }
        default {
            aputs_error "Metodo HTTP no reconocido: '$Metodo'"
            aputs_info  "Metodos HTTP estandar: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT"
            return $false
        }
    }
}

function http_validar_directorio_web {
    param([string]$Directorio, [string]$UsuarioServicio)

    if (-not (Test-Path $Directorio -PathType Container)) {
        aputs_error "El directorio web no existe: $Directorio"
        aputs_info  "Se creara automaticamente durante la instalacion"
        return $false
    }

    # Verificar que el usuario del servicio existe
    if (-not (check_user_exists $UsuarioServicio)) {
        aputs_warning "El usuario del servicio '$UsuarioServicio' no existe aun"
        aputs_info    "Se creara durante la instalacion"
        return $true  # No es error critico en este punto
    }

    return $true
}

function http_validar_lineas_log {
    param([string]$Lineas)

    if ($Lineas -notmatch '^\d+$') {
        aputs_error "El numero de lineas debe ser un entero positivo"
        return $false
    }

    $n = [int]$Lineas
    if ($n -lt 10) {
        aputs_error "Minimo 10 lineas de log"
        return $false
    }

    if ($n -gt 500) {
        aputs_error "Maximo recomendado: 500 lineas (valor: $n)"
        aputs_info  "Para analisis extenso use Get-EventLog o el Visor de Eventos"
        return $false
    }

    return $true
}

function http_validar_confirmacion {
    param([string]$Respuesta)

    switch ($Respuesta.ToLower()) {
        { $_ -in 's', 'si', 'yes', 'y' } { return 0 }   # Confirmado
        { $_ -in 'n', 'no' } { return 1 }   # Negado - decision valida
        '' {
            aputs_error "Debe responder s (si) o n (no)"
            return 2
        }
        default {
            aputs_error "Respuesta no reconocida: '$Respuesta'"
            aputs_info  "Responda: s (si) o n (no)"
            return 2
        }
    }
}