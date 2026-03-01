

. "$PSScriptRoot\common-functions.ps1"
. "$PSScriptRoot\ssh-functions.ps1"
. "C:\script\menu-dhcp.ps1"
. "C:\script\dns-Win.ps1"
. "$PSScriptRoot\..\..\p5\WinServer\ftp-win.ps1"

Verificar-Admin

# ─────────────────────────────────────────
# MENUS POR SERVICIO
# ─────────────────────────────────────────
function Menu-SSH {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "================================"
        Write-Host "   SSH Manager - Windows        "
        Write-Host "================================"
        Write-Host "1) Verificar instalacion"
        Write-Host "2) Instalar OpenSSH Server"
        Write-Host "3) Reiniciar servicio"
        Write-Host "0) Volver"
        Write-Host "--------------------------------"
        $opt = Read-Host "> "
        switch ($opt) {
            "1" { SSH-Verificar }
            "2" { SSH-Instalar  }
            "3" { SSH-Reiniciar }
            "0" { return }
            default { Write-Host "Opcion invalida"; Start-Sleep 1 }
        }
    }
}

function Menu-DHCP {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "================================"
        Write-Host "   DHCP Manager - Windows       "
        Write-Host "================================"
        Write-Host "1) Verificar instalacion"
        Write-Host "2) Instalar DHCP"
        Write-Host "3) Modificar configuracion"
        Write-Host "4) Monitor"
        Write-Host "5) Reiniciar servicio"
        Write-Host "0) Volver"
        Write-Host "--------------------------------"
        $opt = Read-Host "> "
        switch ($opt) {
            "1" { DHCP-Verificar }
            "2" { DHCP-Instalar  }
            "3" { DHCP-Modificar }
            "4" { DHCP-Monitor   }
            "5" { DHCP-Reiniciar }
            "0" { return }
            default { Write-Host "Opcion invalida"; Start-Sleep 1 }
        }
    }
}

function Menu-DNS {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "================================"
        Write-Host "   DNS Manager - Windows        "
        Write-Host "================================"
        Write-Host "1) Verificar instalacion"
        Write-Host "2) Instalar DNS"
        Write-Host "3) Configurar zona base"
        Write-Host "4) Reconfigurar"
        Write-Host "5) Administrar dominios (ABC)"
        Write-Host "6) Validar y probar resolucion"
        Write-Host "0) Volver"
        Write-Host "--------------------------------"
        $opt = Read-Host "> "
        switch ($opt) {
            "1" { DNS-Verificar    }
            "2" { DNS-Instalar     }
            "3" { DNS-Configurar   }
            "4" { DNS-Reconfigurar }
            "5" { DNS-Administrar  }
            "6" { DNS-Validar      }
            "0" { return }
            default { Write-Host "Opcion invalida"; Start-Sleep 1 }
        }
    }
}

# ─────────────────────────────────────────
# MENU PRINCIPAL
# ─────────────────────────────────────────
while ($true) {
    Clear-Host
    Write-Host ""
    Write-Host "================================"
    Write-Host "   Administrador de Servicios   "
    Write-Host "       Windows Server           "
    Write-Host "================================"
    Write-Host "1) SSH  - Acceso remoto"
    Write-Host "2) DHCP - Servidor DHCP"
    Write-Host "3) DNS  - Servidor DNS"
    Write-Host "4) FTP  - Servidor FTP"
    Write-Host "0) Salir"
    Write-Host "--------------------------------"
    $opt = Read-Host "> "
    switch ($opt) {
        "1" { Menu-SSH  }
        "2" { Menu-DHCP }
        "3" { Menu-DNS  }
        "4" { Menu-FTP  }
        "0" { Write-Host "Saliendo..."; exit 0 }
        default { Write-Host "Opcion invalida"; Start-Sleep 1 }
    }
}