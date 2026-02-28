@echo off
echo Enviando scripts al servidor Linux...

set SRV=andre@192.168.92.128
set LOCAL=D:\Antigravity\herman\p5\AlmaLinux
set REMOTE=/home/andre

scp %LOCAL%\ftp-linux.sh             %SRV%:%REMOTE%/ftp-linux.sh

echo.
echo Ajustando permisos de ejecucion...
ssh %SRV% "chmod +x %REMOTE%/ftp-linux.sh"

echo Listo!
pause