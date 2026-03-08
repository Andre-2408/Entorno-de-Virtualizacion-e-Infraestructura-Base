@echo off
echo Enviando scripts al servidor Linux...

set SRV=andre@192.168.92.128
set LOCAL_P4=D:\Antigravity\herman\p4\AlmaLinux
set LOCAL_P6=D:\Antigravity\herman\p6\AlmaLinux
set REMOTE=/home/andre

scp %LOCAL_P6%\http_functions.sh   %SRV%:%REMOTE%/http_functions.sh
scp %LOCAL_P4%\main.sh             %SRV%:%REMOTE%/main.sh

echo.
echo Ajustando permisos de ejecucion...
ssh %SRV% "chmod +x %REMOTE%/http_functions.sh %REMOTE%/main.sh"

echo Listo!
pause