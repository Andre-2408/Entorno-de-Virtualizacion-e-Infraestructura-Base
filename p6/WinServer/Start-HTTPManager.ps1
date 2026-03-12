#
# Start-HTTPManager.ps1
# Script principal - Gestor de Servicios HTTP en Windows Server 2022
#
# Estructura del proyecto:
#   Start-HTTPManager.ps1  <- este archivo (solo dot-source + llamadas)
#   CoreHelpers.ps1        <- utilidades base
#   HTTPGlobals.ps1        <- constantes globales y helpers HTTP
#   InputGuard.ps1         <- validaciones de entrada
#   StatusCheck.ps1        <- Grupo A: Verificacion de estado
#   Installer.ps1          <- Grupo B: Instalacion de servicios
#   ConfigManager.ps1      <- Grupo C: Configuracion y seguridad
#   VersionControl.ps1     <- Grupo D: Gestion de versiones
#   Monitor.ps1            <- Grupo E: Monitoreo
#

#Requires -Version 5.1
#Requires -RunAsAdministrator

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

. "$SCRIPT_DIR\CoreHelpers.ps1"
. "$SCRIPT_DIR\HTTPGlobals.ps1"
. "$SCRIPT_DIR\InputGuard.ps1"
. "$SCRIPT_DIR\StatusCheck.ps1"
. "$SCRIPT_DIR\Installer.ps1"
. "$SCRIPT_DIR\ConfigManager.ps1"
. "$SCRIPT_DIR\VersionControl.ps1"
. "$SCRIPT_DIR\Monitor.ps1"

function main_menu {
    while ($true) {
        Clear-Host
        $fecha = Get-Date -Format "dd/MM/yyyy HH:mm"

        Write-Host ""
        Write-Host "  ------------------------------------------------"
        Write-Host "         GESTOR DE SERVICIOS HTTP"
        Write-Host "         IIS  /  Apache  /  Nginx  /  Tomcat"
        Write-Host "         $fecha   |   192.168.100.20"
        Write-Host "  ------------------------------------------------"
        Write-Host ""
        Write-Host "  1. Verificar estado de servicios"
        Write-Host "  2. Instalar servicio HTTP"
        Write-Host "  3. Configurar servicio"
        Write-Host "  4. Monitoreo"
        Write-Host "  5. Salir"
        Write-Host ""
        Write-Host "  ------------------------------------------------"
        Write-Host ""

        $op = Read-Host "  Opcion"

        if (-not (http_validar_opcion_menu $op 5)) {
            Start-Sleep -Seconds 2
            continue
        }

        switch ($op) {
            "1" { http_menu_verificar  }
            "2" { http_menu_instalar   }
            "3" { http_menu_configurar }
            "4" { http_menu_monitoreo  }
            "5" {
                Clear-Host
                Write-Host ""
                Write-Host "  Saliendo del Gestor HTTP..."
                Write-Host ""
                exit 0
            }
        }

        Write-Host ""
        pause_menu
    }
}

if (-not (check_privileges)) {
    Write-Host ""
    aputs_error "Este script requiere permisos de Administrador."
    aputs_info  "Ejecute PowerShell como Administrador y reintente."
    Write-Host ""
    exit 1
}

if (-not (http_verificar_dependencias)) {
    Write-Host ""
    aputs_error "Dependencias faltantes. Resuelva los errores antes de continuar."
    aputs_info  "Chocolatey se instala automaticamente - verifique conectividad a Internet"
    Write-Host ""
    pause_menu
    exit 1
}

Write-Host ""
pause_menu

http_detectar_rutas_reales

main_menu
