<#
  Desinstalador Seguro (Solo Archivos y Carpetas).
  Elimina: Carpetas de programa, datos de usuario, accesos directos.
  NO elimina: Registro, Variables de Entorno, Firewall.
#>
[CmdletBinding()]
param(
    [switch]$WhatIf,
    [switch]$Aggressive
)

$ErrorActionPreference = 'Stop'

# ---------- Auto-elevar a Administrador ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIf) {
    Write-Host "Reiniciando como Administrador..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Aggressive) { $argList += '-Aggressive' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$LogFile = Join-Path $env:TEMP ("Desinstalar-Seguro_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {}

# ============================================================
#  UTILIDADES BASE (Solo lectura de registro para listar)
# ============================================================
function Get-InstalledApps {
    $keys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKLM-64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKLM-32' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKCU' }
    )
    $apps = foreach ($k in $keys) {
        if (-not (Test-Path $k.Path)) { continue }
        foreach ($item in Get-ChildItem $k.Path -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            if ($p.SystemComponent -eq 1) { continue }
            if ($p.ParentKeyName) { continue }
            if ($p.ReleaseType -in 'Update', 'Hotfix', 'Security Update') { continue }
            if ($p.DisplayName -match 'KB\d{6,}') { continue }
            [pscustomobject]@{
                Name                 = $p.DisplayName
                Version              = $p.DisplayVersion
                Publisher            = $p.Publisher
                InstallLocation      = $p.InstallLocation
                DisplayIcon          = $p.DisplayIcon
                UninstallString      = $p.UninstallString
                QuietUninstallString = $p.QuietUninstallString
                WindowsInstaller     = $p.WindowsInstaller
                Key                  = $item.PSChildName
                PSPath               = $item.PSPath
                Origen               = $k.Origen
            }
        }
    }
    @($apps | Sort-Object Name)
}

function Get-ExeFromString([string]$s) {
    if (-not $s) { return $null }
    if ($s -match '^\s*"?([A-Za-z]:\\[^"]*?\.(?:exe|ico|dll))') { return $matches[1] }
    return $null
}

function Test-Protected([string]$path) {
    try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $true }
    if ($full.Length -le 3) { return $true }
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { $pf86 = $env:ProgramFiles }
    $protected = @(
        $env:SystemDrive, $env:windir, $env:ProgramFiles, $pf86,
        $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA,
        (Join-Path $env:SystemDrive 'Users'),
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft'),
        (Join-Path $env:APPDATA 'Microsoft'),
        (Join-Path $env:ProgramData 'Microsoft'),
        (Join-Path $env:ProgramFiles 'Common Files'),
        (Join-Path $pf86 'Common Files'),
        (Join-Path $env:ProgramFiles 'WindowsApps')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if ($protected -contains $full) { return $true }
    if ($full -like ($env:windir.TrimEnd('\') + '*')) { return $true }
    if ($full -like (Join-Path $env:ProgramFiles 'Windows*')) { return $true }
    if ($full -like (Join-Path $pf86 'Windows*')) { return $true }
    return $false
}

function Confirm-YesNo([string]$msg) {
    (Read-Host "$msg [S/N]") -match '^(s|si|y|yes)$'
}

function Get-FolderSizeMB([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if (-not $sum) { return 0 }
    [math]::Round(($sum / 1MB), 1)
}

# ============================================================
#  BUSQUEDA DE CANDIDATOS (PROGRAMAS)
# ============================================================
function Get-CandidateFolders($app) {
    $c = New-Object System.Collections.Generic.List[string]

    if ($app.InstallLocation) { $c.Add($app.InstallLocation.Trim('"').TrimEnd('\')) }

    foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)') { $c.Add($dir) }
        }
    }

    $words = ($app.Name -split '\s+') | Where-Object { $_ -match '^[A-Za-z]{2,}' } | Select-Object -First 2
    if ($words) {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
            (Join-Path $env:LOCALAPPDATA 'Programs')) |
        Where-Object { $_ -and (Test-Path $_) }
        $pattern = '*' + ($words -join ' ') + '*'
        foreach ($r in $roots) {
            Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern } |
            ForEach-Object { $c.Add($_.FullName) }
        }
    }

    $c | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and -not (Test-Protected $_) } |
    ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique
}

function Get-NameTokens([string]$name, [string]$publisher) {
    $generic = @('microsoft', 'windows', 'google', 'adobe', 'apple', 'intel', 'nvidia', 'amd', 'oracle',
        'update', 'runtime', 'redistributable', 'visual', 'studio', 'driver', 'drivers', 'software',
        'system', 'service', 'services', 'common', 'shared', 'setup', 'install', 'installer', 'program',
        'programs', 'files', 'application', 'apps', 'data', 'tools', 'client', 'server', 'desktop',
        'professional', 'standard', 'enterprise', 'home', 'edition', 'plus', 'premium', 'ultimate',
        'community', 'free', 'language', 'pack')
    $tokens = @()
    if ($name) {
        $clean = $name -replace '\s*\(.*?\)', '' -replace '\s+(x64|x86|64-bit|32-bit|v?\d+(\.\d+)+).*$', ''
        $tokens = @($clean -split '\s+' | Where-Object {
                $_ -match '^[A-Za-z0-9][A-Za-z0-9\-\+\.]*$' -and
                $_.Length -ge 4 -and
                $_ -notmatch '^\d+$' -and
                ($generic -notcontains $_.ToLower())
            } | Select-Object -First 2)
    }
    $tokens | Sort-Object -Unique
}

# ============================================================
#  BUSQUEDA DE RESTOS (SOLO CARPETAS Y ACCESOS)
# ============================================================
function Get-LeftoverUserFolders($app) {
    $result = New-Object System.Collections.Generic.List[object]
    $tokens = Get-NameTokens $app.Name $app.Publisher
    if (-not $tokens) { return @() }
    $roots = @(
        @{ Root = $env:APPDATA; Kind = 'APPDATA' },
        @{ Root = $env:LOCALAPPDATA; Kind = 'LOCALAPPDATA' },
        @{ Root = (Join-Path $env:LOCALAPPDATA 'Programs'); Kind = 'LOCALAPPDATA\Programs' },
        @{ Root = $env:ProgramData; Kind = 'ProgramData' }
    ) | Where-Object { $_.Root -and (Test-Path $_.Root) }

    foreach ($r in $roots) {
        foreach ($tok in $tokens) {
            $candidates = Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$tok*" }
            foreach ($c in $candidates) {
                if (Test-Protected $c.FullName) { continue }
                $result.Add([pscustomobject]@{
                        Path   = $c.FullName
                        Kind   = $r.Kind
                        SizeMB = Get-FolderSizeMB $c.FullName
                    })
            }
        }
    }
    $result | Sort-Object Path -Unique
}

function Get-Shortcuts($app) {
    $result = New-Object System.Collections.Generic.List[string]
    $tokens = Get-NameTokens $app.Name $app.Publisher
    if (-not $tokens) { return $result }

    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $userDesktop = [Environment]::GetFolderPath('Desktop')
    $userStart = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $allUsersStart = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $quickLaunch = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'
    $taskbarPinned = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'

    $roots = @($publicDesktop, $userDesktop, $userStart, $allUsersStart, $quickLaunch, $taskbarPinned) |
    Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        foreach ($tok in $tokens) {
            Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$tok*" } |
            ForEach-Object { $result.Add($_.FullName) }
        }
    }
    $result | Sort-Object -Unique
}

# ============================================================
#  BORRADO SEGURO (Solo Archivos)
# ============================================================
function Stop-ProcessesInFolder([string]$folder) {
    $prefix = $folder.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object {
        Write-Host "   Cerrando proceso: $($_.Name) (PID $($_.ProcessId))" -ForegroundColor DarkYellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Register-DeleteOnReboot([string]$path) {
    if ($WhatIf) { return }
    try {
        if (-not ('NativeMethods' -as [type])) {
            $signature = @'
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    public const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;
}
'@
            Add-Type -TypeDefinition $signature -ErrorAction Stop | Out-Null
        }
        $flag = [NativeMethods]::MOVEFILE_DELAY_UNTIL_REBOOT
        $count = 0
        if (Test-Path -LiteralPath $path -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
                if ([NativeMethods]::MoveFileEx($f.FullName, $null, $flag)) { $count++ }
            }
            $dirs = @(Get-ChildItem -LiteralPath $path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending)
            foreach ($d in $dirs) { [void][NativeMethods]::MoveFileEx($d.FullName, $null, $flag) }
        }
        $ok = [NativeMethods]::MoveFileEx($path, $null, $flag)
        if ($ok) { Write-Host "   Programado para borrar al reiniciar: $path ($count archivo(s))" -ForegroundColor DarkYellow }
    }
    catch {
        Write-Host "   No se pudo programar borrado al reiniciar: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Remove-FolderForced([string]$folder) {
    if (Test-Protected $folder) { Write-Host "   Ruta protegida, se omite: $folder" -ForegroundColor Red; return }
    if ($WhatIf) { Write-Host "   [WhatIf] Se borraria carpeta: $folder" -ForegroundColor Cyan; return }

    Stop-ProcessesInFolder $folder
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $folder) {
        & icacls.exe $folder /setowner "*S-1-5-32-544" /t /c /q | Out-Null
        & icacls.exe $folder /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q | Out-Null
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $folder) {
        Write-Host "   No se pudo borrar todo. Se programara al reinicio: $folder" -ForegroundColor Red
        Register-DeleteOnReboot $folder
    }
    else {
        Write-Host "   Eliminada: $folder" -ForegroundColor Green
    }
}

function Remove-FileSafe([string]$file) {
    if ($WhatIf) { Write-Host "   [WhatIf] Se borraria archivo: $file" -ForegroundColor Cyan; return }
    if (-not (Test-Path -LiteralPath $file)) { return }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $file) {
        & icacls.exe $file /setowner "*S-1-5-32-544" /c /q | Out-Null
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "   Eliminado: $file" -ForegroundColor Green
    }
    else {
        Write-Host "   No se pudo borrar (en uso), se programara: $file" -ForegroundColor DarkYellow
        Register-DeleteOnReboot $file
    }
}

function Refresh-Explorer {
    if ($WhatIf) { return }
    try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue } catch {}
}

# ============================================================
#  DESINSTALACION NORMAL
# ============================================================
function Invoke-NormalUninstall($app, [int]$TimeoutMin = 15) {
    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')

    if ($isMsi) {
        $exe = 'msiexec.exe'
        $argLine = "/x $($app.Key) /qn /norestart"
        Write-Host "Metodo: MSI silencioso ($($app.Key))" -ForegroundColor Cyan
    }
    elseif ($app.QuietUninstallString) {
        $exe = 'cmd.exe'
        $argLine = "/c $($app.QuietUninstallString)"
        Write-Host "Metodo: QuietUninstallString" -ForegroundColor Cyan
    }
    elseif ($app.UninstallString) {
        $exe = 'cmd.exe'
        $argLine = "/c $($app.UninstallString)"
        Write-Host "Metodo: UninstallString (puede abrir ventanas)" -ForegroundColor Cyan
    }
    else {
        Write-Host "Este programa no tiene desinstalador registrado." -ForegroundColor Yellow
        return $null
    }

    if ($WhatIf) { Write-Host "   [WhatIf] Se ejecutaria: $exe $argLine" -ForegroundColor Cyan; return 0 }

    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
        if (-not $proc.WaitForExit($TimeoutMin * 60 * 1000)) {
            Write-Host "Tiempo agotado ($TimeoutMin min). Se cancela el desinstalador." -ForegroundColor Red
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            return -1
        }
        Write-Host "Codigo de salida: $($proc.ExitCode)"
        return $proc.ExitCode
    }
    catch {
        Write-Host "Error al ejecutar el desinstalador: $($_.Exception.Message)" -ForegroundColor Red
        return -1
    }
}

# ============================================================
#  ELIMINACION FORZADA (FLUJO SEGURO)
# ============================================================
function Invoke-ForcedRemoval($app) {
    Write-Host "`n=== ELIMINACION FORZADA (MODO SEGURO): $($app.Name) ===" -ForegroundColor Red
    if ($WhatIf) { Write-Host "MODO SIMULACION (no se borrara nada)" -ForegroundColor Magenta }

    $tk = Get-NameTokens $app.Name $app.Publisher
    if ($tk) { Write-Host "Palabras de busqueda: $($tk -join ' | ')" -ForegroundColor DarkCyan }
    else { Write-Host "Nombre muy corto/generico: solo se usaran las rutas registradas del programa." -ForegroundColor Yellow }

    # ----- FASE 1: recolectar -----
    Write-Host "`n[1/4] Buscando carpetas de programa..." -ForegroundColor Cyan
    $appFolders = @(Get-CandidateFolders $app)

    Write-Host "[2/4] Buscando carpetas de datos de usuario y accesos directos..." -ForegroundColor Cyan
    $userFolders = @(Get-LeftoverUserFolders $app)
    $shortcuts = @(Get-Shortcuts $app)

    # ----- FASE 2: resumen -----
    Write-Host "`n--- RESUMEN DE RESTOS ENCONTRADOS (SOLO ARCHIVOS) ---" -ForegroundColor Yellow
    if ($appFolders) {
        Write-Host "Carpetas de programa:" -ForegroundColor Cyan
        $appFolders | ForEach-Object { Write-Host ("  - {0}  ({1} MB)" -f $_, (Get-FolderSizeMB $_)) }
    }
    if ($userFolders) {
        Write-Host "Carpetas de datos de usuario:" -ForegroundColor Cyan
        $userFolders | ForEach-Object { Write-Host ("  - [{0}] {1}  ({2} MB)" -f $_.Kind, $_.Path, $_.SizeMB) }
    }
    if ($shortcuts) {
        Write-Host "Accesos directos:" -ForegroundColor Cyan
        $shortcuts | ForEach-Object { Write-Host "  - $_" }
    }

    $total = ($appFolders.Count + $userFolders.Count + $shortcuts.Count)
    if ($total -eq 0) {
        Write-Host "`nNo se encontraron restos adicionales." -ForegroundColor Yellow
    }

    # ----- FASE 3: confirmacion -----
    if (-not $Aggressive) {
        Write-Host "`nSe borraran SOLO los elementos que confirmes (NO se toca Registro, Firewall ni Variables de Entorno)." -ForegroundColor Yellow
        if ((Read-Host "Escribe FORZAR para continuar") -cne 'FORZAR') { Write-Host "Cancelado."; return }
    }
    else {
        Write-Host "`nModo agresivo: se borrara todo lo listado arriba. REVISA LA LISTA ANTES DE CONFIRMAR." -ForegroundColor Red
        if (-not (Confirm-YesNo "Confirmas la LIMPIEZA TOTAL de archivos?")) { return }
    }

    if (-not $WhatIf) {
        try {
            Checkpoint-Computer -Description "Antes de eliminar $($app.Name)" `
                -RestorePointType APPLICATION_UNINSTALL -ErrorAction Stop
            Write-Host "Punto de restauracion creado." -ForegroundColor Green
        }
        catch {
            Write-Host "No se pudo crear punto de restauracion (desactivado o limitado a 1/24h)." -ForegroundColor DarkYellow
        }
    }

    # ----- FASE 4: ejecutar -----
    Write-Host "`n[1/3] Borrando carpetas de programa..." -ForegroundColor Cyan
    foreach ($f in $appFolders) {
        if ($Aggressive -or (Confirm-YesNo "Borrar carpeta '$f' ?")) {
            Remove-FolderForced $f
        }
    }

    Write-Host "`n[2/3] Borrando carpetas de datos de usuario..." -ForegroundColor Cyan
    foreach ($f in $userFolders) {
        if ($Aggressive -or (Confirm-YesNo "Borrar carpeta '$($f.Path)' ($($f.Kind))?")) {
            Remove-FolderForced $f.Path
        }
    }

    Write-Host "`n[3/3] Borrando accesos directos..." -ForegroundColor Cyan
    foreach ($s in $shortcuts) {
        if ($Aggressive -or (Confirm-YesNo "Borrar acceso '$s' ?")) { Remove-FileSafe $s }
    }

    # Refrescar Explorer para que desaparezcan iconos de Menu Inicio/Escritorio
    Refresh-Explorer

    Write-Host "`n=== LIMPIEZA FORZADA COMPLETADA PARA: $($app.Name) ===" -ForegroundColor Green
}

# ============================================================
#  PROGRAMA PRINCIPAL
# ============================================================
Write-Host "Cargando programas instalados..." -ForegroundColor Cyan
if ($WhatIf) { Write-Host "MODO SIMULACION ACTIVADO (-WhatIf): no se borrara nada." -ForegroundColor Magenta }
if ($Aggressive) { Write-Host "MODO AGRESIVO ACTIVADO (-Aggressive): una sola confirmacion global." -ForegroundColor Magenta }

$all = Get-InstalledApps
$filter = ''

while ($true) {
    $view = @($all | Where-Object { -not $filter -or $_.Name -like "*$filter*" })
    Clear-Host
    Write-Host ("=== PROGRAMAS INSTALADOS ({0} de {1}) ===" -f $view.Count, $all.Count) -ForegroundColor Cyan
    if ($filter) { Write-Host "Filtro activo: '$filter'" -ForegroundColor DarkCyan }
    if ($WhatIf) { Write-Host "(Simulacion -WhatIf: nada se borrara)" -ForegroundColor Magenta }

    for ($i = 0; $i -lt $view.Count; $i++) {
        $a = $view[$i]
        Write-Host ("{0,3}. {1}  {2}  [{3}]" -f ($i + 1), $a.Name, $a.Version, $a.Publisher)
    }

    $in = Read-Host "`nNumero para desinstalar | texto para filtrar | vacio = quitar filtro | Q = salir"
    if ($in -match '^(q|salir)$') { break }
    if ([string]::IsNullOrWhiteSpace($in)) { $filter = ''; continue }
    if ($in -notmatch '^\d+$') { $filter = $in; continue }

    $n = [int]$in
    if ($n -lt 1 -or $n -gt $view.Count) {
        Write-Host "Numero fuera de rango." -ForegroundColor Red
        Start-Sleep 1
        continue
    }
    $target = $view[$n - 1]

    Write-Host "`nSeleccionado: $($target.Name) $($target.Version)" -ForegroundColor Yellow
    if ($target.InstallLocation) { Write-Host "Ruta registrada: $($target.InstallLocation)" }
    if (-not (Confirm-YesNo "Desinstalar este programa?")) { continue }

    # 1) Desinstalacion normal
    $null = Invoke-NormalUninstall $target

    # 2) Verificar si desaparecio del registro
    Start-Sleep -Seconds 2
    $still = Test-Path -LiteralPath $target.PSPath
    if (-not $still) {
        Write-Host "`nDesinstalado correctamente." -ForegroundColor Green

        if (Confirm-YesNo "Quieres revisar y limpiar restos de archivos que haya dejado (carpetas, accesos directos)?" ) {
            Invoke-ForcedRemoval $target
        }

        $all = Get-InstalledApps
        Read-Host "Enter para continuar" | Out-Null
        continue
    }

    # 3) Forzado
    Write-Host "`nEl programa sigue registrado como instalado (puede que el desinstalador oficial haya fallado)." -ForegroundColor Red
    if (Confirm-YesNo "Intentar eliminacion forzada de archivos + limpieza de restos?") { Invoke-ForcedRemoval $target }

    $all = Get-InstalledApps
    Read-Host "`nEnter para continuar" | Out-Null
}

Write-Host "`nLog guardado en: $LogFile" -ForegroundColor DarkGray
try { Stop-Transcript | Out-Null } catch {}