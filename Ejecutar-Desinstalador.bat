@echo off
setlocal
title Desinstalador Forzado - Modo Administrador

REM ============================================================
REM  Lanzador para Desinstalar-Forzado.ps1 con privilegios admin
REM  Coloca este .bat en la misma carpeta que el .ps1
REM ============================================================

REM --- Detectar si ya somos administrador ---
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Solicitando permisos de Administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM --- Ruta del script PS1 (misma carpeta que este .bat) ---
set "PS1=%~dp0Desinstalar-Forzado.ps1"

REM --- Verificar que el PS1 existe ---
if not exist "%PS1%" (
    echo.
    echo [ERROR] No se encontro el script:
    echo         "%PS1%"
    echo.
    echo Asegurate de que este .bat este en la misma carpeta que Desinstalar-Forzado.ps1
    echo.
    pause
    exit /b 1
)

REM --- Ejecutar PowerShell con politica de ejecucion Bypass ---
echo Iniciando Desinstalador Forzado con privilegios elevados...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

echo.
echo ============================================
echo  El script ha finalizado.
echo ============================================
pause
endlocal