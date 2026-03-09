@echo off
echo ═══════════════════════════════════════
echo  Transfiriendo scripts al servidor Linux
echo ═══════════════════════════════════════

set SRV=andre@192.168.92.128
set LOCAL_P4=D:\Antigravity\herman\p4\AlmaLinux
set LOCAL_P6=D:\Antigravity\herman\p6\AlmaLinux
set LOCAL_P6W=D:\Antigravity\herman\p6\WinServer
set REMOTE=/home/andre

echo [Linux] Enviando http_functions.sh y main.sh...
scp %LOCAL_P6%\http_functions.sh   %SRV%:%REMOTE%/http_functions.sh
scp %LOCAL_P4%\main.sh             %SRV%:%REMOTE%/main.sh

echo.
echo Ajustando permisos de ejecucion...
ssh %SRV% "chmod +x %REMOTE%/http_functions.sh %REMOTE%/main.sh"

echo.
echo [Windows] Copia http_functions.ps1 manualmente a C:\script\ en la VM Windows:
echo   Archivo fuente: %LOCAL_P6W%\http_functions.ps1
echo   Destino en VM:  C:\script\http_functions.ps1
echo.

echo Listo!
pause