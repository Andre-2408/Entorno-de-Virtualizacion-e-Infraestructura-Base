# lib/ssh_functions.ps1
# Depende de: common_functions.ps1

$SSH_SVC  = "sshd"
$SSH_CAP  = "OpenSSH.Server"
$SSH_PORT = 22

# ─────────────────────────────────────────
# VERIFICAR INSTALACION
# ─────────────────────────────────────────
function SSH-Verificar {
    Write-Host ""
    Write-Host "=== Verificando SSH ==="

    $cap = Get-WindowsCapability -Online | Where-Object Name -like "*OpenSSH.Server*"
    if ($cap -and $cap.State -eq "Installed") {
        Write-OK "OpenSSH Server instalado."
    } else {
        Write-Wrn "OpenSSH Server NO instalado."
    }

    $svc = Get-Service -Name $SSH_SVC -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-OK "Servicio: ACTIVO"
    } else {
        Write-Wrn "Servicio: INACTIVO"
    }

    Write-Host ""
    Write-Host "  IPs del servidor:"
    $ips = Get-NetIPAddress -AddressFamily IPv4 |
           Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -ne "0.0.0.0" } |
           Select-Object -ExpandProperty IPAddress
    foreach ($ip in $ips) { Write-Host "    ssh usuario@$ip" -ForegroundColor Cyan }

    Pausar
}

# ─────────────────────────────────────────
# INSTALAR
# ─────────────────────────────────────────
function SSH-Instalar {
    Write-Host ""
    Write-Host "=== Instalacion OpenSSH Server ==="

    $cap = Get-WindowsCapability -Online | Where-Object Name -like "*OpenSSH.Server*"
    if ($cap -and $cap.State -eq "Installed") {
        Write-Wrn "Ya instalado."
        $r = Read-Host "  ¿Continuar de todas formas? (s/n)"
        if ($r -notmatch "^[sS]$") { return }
    }

    Write-Inf "Instalando OpenSSH Server..."
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null

    $cap2 = Get-WindowsCapability -Online | Where-Object Name -like "*OpenSSH.Server*"
    if ($cap2.State -eq "Installed") {
        Write-OK "OpenSSH Server instalado."
    } else {
        Write-Err "Error en la instalacion."
        Pausar; return
    }

    Set-Service -Name $SSH_SVC -StartupType Automatic
    Start-Service -Name $SSH_SVC
    Start-Sleep -Seconds 2

    $svc = Get-Service -Name $SSH_SVC
    if ($svc.Status -eq "Running") {
        Write-OK "Servicio activo y configurado para inicio automatico."
    } else {
        Write-Err "El servicio no pudo iniciar."
    }

    $regla = "OpenSSH-Server-In-TCP"
    if (-not (Get-NetFirewallRule -Name $regla -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $regla -DisplayName "OpenSSH SSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $SSH_PORT | Out-Null
        Write-OK "Regla de Firewall creada (TCP/$SSH_PORT)."
    } else {
        Write-Wrn "Regla de Firewall ya existia."
    }
    Pausar
}

# ─────────────────────────────────────────
# REINICIAR
# ─────────────────────────────────────────
function SSH-Reiniciar {
    Write-Host ""
    Write-Host "Reiniciando SSH..."
    Restart-Service -Name $SSH_SVC -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name $SSH_SVC
    if ($svc.Status -eq "Running") { Write-OK "SSH activo." } else { Write-Err "Fallo al reiniciar." }
    Pausar
}