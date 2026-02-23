# lib/common_functions.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Write-OK   { param($m) Write-Host "  [OK] $m"    -ForegroundColor Green  }
function Write-Err  { param($m) Write-Host "  [ERROR] $m" -ForegroundColor Red    }
function Write-Inf  { param($m) Write-Host "  [INFO] $m"  -ForegroundColor Cyan   }
function Write-Wrn  { param($m) Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Pausar     { Write-Host ""; Read-Host "  Presiona ENTER para continuar" }

# ─────────────────────────────────────────
# VERIFICAR ADMINISTRADOR
# ─────────────────────────────────────────
function Verificar-Admin {
    $cur = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $cur.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "  Ejecuta como Administrador." -ForegroundColor Red
        exit 1
    }
}

# ─────────────────────────────────────────
# VALIDACION DE IP
# ─────────────────────────────────────────
function Validar-IP {
    param($ip)
    if ($ip -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        Write-Host "  Error: '$ip' no tiene formato IPv4 valido"
        return $false
    }
    $o = $ip.Split(".")
    foreach ($oct in $o) {
        if ([int]$oct -gt 255) {
            Write-Host "  Error: octeto '$oct' fuera de rango (0-255)"
            return $false
        }
    }
    if ($ip -eq "0.0.0.0")         { Write-Host "  Error: 0.0.0.0 no valida";         return $false }
    if ($ip -eq "255.255.255.255") { Write-Host "  Error: broadcast no valida";        return $false }
    if ($o[0] -eq "127")           { Write-Host "  Error: loopback no valida";         return $false }
    if ($o[3] -eq "0")             { Write-Host "  Error: $ip es direccion de red";    return $false }
    if ($o[3] -eq "255")           { Write-Host "  Error: $ip es broadcast";           return $false }
    return $true
}

function Pedir-IP {
    param($mensaje, $default)
    while ($true) {
        $ip = Read-Host "  $mensaje [$default]"
        if (!$ip) { $ip = $default }
        if (Validar-IP $ip) { return $ip }
    }
}

function IP-ToInt {
    param($ip)
    $o = $ip.Split(".")
    return ([int]$o[0] * 16777216) + ([int]$o[1] * 65536) + ([int]$o[2] * 256) + [int]$o[3]
}

function Calcular-Mascara {
    param([int]$prefix)
    $octetos = @(0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $prefix - ($i * 8)))
        $octetos[$i] = [int](256 - [Math]::Pow(2, 8 - $bits))
    }
    return "$($octetos[0]).$($octetos[1]).$($octetos[2]).$($octetos[3])"
}