<#
  Desinstalador Seguro con Limpieza Controlada.
  (Archivo solo ASCII a proposito.)

  Flujo:
    1) Lista los programas instalados (con filtro por texto).
    2) Intenta la desinstalacion normal (silenciosa si es posible).
    3) Si sigue instalado, muestra TODAS las rutas asociadas y pregunta
       una por una si quieres borrarlas.
    4) Al finalizar, ofrece limpieza opcional de: cache, accesos directos,
       carpetas vacias, entrada de desinstalacion.

  PROTECCIONES:
    - NUNCA toca Documentos, Escritorio, Descargas, Imagenes, Videos, Musica.
    - NUNCA borra archivos de usuario (.docx, .xlsx, .pdf, .jpg, .mp4, etc.)
    - NUNCA toca el registro de Windows (solo la entrada de desinstalacion).
    - NUNCA toca firewall, servicios, tareas programadas ni variables de entorno.

  Uso:
     - Doble clic en el .bat lanzador.
     - Parametros opcionales:
         -WhatIf : simulacion, muestra que borraria sin borrar nada.
#>
[CmdletBinding()]
param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# ---------- Auto-elevar a Administrador ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIf) {
    Write-Host "Reiniciando como Administrador..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$LogFile = Join-Path $env:TEMP ("Desinstalar-Seguro_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {}

# ============================================================
#  UTILIDADES BASE
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

# ============================================================
#  PROTECCION DE DATOS DE USUARIO
# ============================================================

# Carpetas de usuario que NUNCA se deben tocar (documentos personales)
function Get-ProtectedUserFolders {
    $folders = @(
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyVideos'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Pictures'),
        (Join-Path $env:USERPROFILE 'Music'),
        (Join-Path $env:USERPROFILE 'Videos'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'OneDrive'),
        (Join-Path $env:USERPROFILE 'Favorites'),
        (Join-Path $env:USERPROFILE 'Contacts'),
        (Join-Path $env:USERPROFILE 'Links'),
        (Join-Path $env:USERPROFILE 'Saved Games'),
        (Join-Path $env:USERPROFILE 'Searches')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { $_.TrimEnd('\') }
    $folders
}

# Extensiones de archivos de usuario que NUNCA se deben borrar
$script:ProtectedExtensions = @(
    '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.txt', '.rtf', '.odt', '.ods', '.odp',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.svg', '.heic', '.raw',
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a',
    '.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm',
    '.zip', '.rar', '.7z', '.tar', '.gz',
    '.psd', '.ai', '.indd', '.cdr',
    '.csv', '.json', '.xml', '.html', '.htm',
    '.eml', '.msg', '.pst', '.ost',
    '.db', '.sqlite', '.mdb', '.accdb',
    '.epub', '.mobi', '.azw', '.azw3'
)

function Test-ProtectedPath([string]$path) {
    try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $true }
    if ($full.Length -le 3) { return $true }

    # Rutas del sistema
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

    # Carpetas de documentos de usuario
    $userFolders = Get-ProtectedUserFolders
    foreach ($uf in $userFolders) {
        if ($full -eq $uf) { return $true }
        if ($full -like ($uf + '\*')) { return $true }
    }

    return $false
}

# Verifica si una carpeta contiene archivos de usuario protegidos
function Test-FolderContainsUserFiles([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return $false }
    $userFiles = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $script:ProtectedExtensions -contains $_.Extension.ToLower() }
    return ($userFiles.Count -gt 0)
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
#  BUSQUEDA DE RUTAS ASOCIADAS AL PROGRAMA
# ============================================================
function Get-AppAssociatedPaths($app) {
    $result = New-Object System.Collections.Generic.List[object]

    # 1) Ruta registrada de instalacion
    if ($app.InstallLocation) {
        $loc = $app.InstallLocation.Trim('"').TrimEnd('\')
        if ($loc -and (Test-Path -LiteralPath $loc)) {
            $result.Add([pscustomobject]@{
                Path = $loc; Tipo = 'Instalacion'; SizeMB = (Get-FolderSizeMB $loc)
            })
        }
    }

    # 2) Carpetas derivadas del ejecutable (DisplayIcon / UninstallString)
    foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)' -and (Test-Path -LiteralPath $dir)) {
                if (-not ($result | Where-Object { $_.Path -eq $dir })) {
                    $result.Add([pscustomobject]@{
                        Path = $dir; Tipo = 'Ejecutable'; SizeMB = (Get-FolderSizeMB $dir)
                    })
                }
            }
        }
    }

    # 3) Carpetas en Program Files / ProgramData que coincidan con el nombre
    $words = ($app.Name -split '\s+') | Where-Object { $_ -match '^[A-Za-z]{2,}' } | Select-Object -First 2
    if ($words) {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
            (Join-Path $env:LOCALAPPDATA 'Programs')) |
            Where-Object { $_ -and (Test-Path $_) }
        $pattern = '*' + ($words -join ' ') + '*'
        foreach ($r in $roots) {
            Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pattern } |
                ForEach-Object {
                    if (-not ($result | Where-Object { $_.Path -eq $_.FullName })) {
                        $result.Add([pscustomobject]@{
                            Path = $_.FullName; Tipo = 'Programa'; SizeMB = (Get-FolderSizeMB $_.FullName)
                        })
                    }
                }
        }
    }

    # 4) Carpetas de datos de usuario (APPDATA / LOCALAPPDATA) - SIN tocar Documents/Desktop
    $tokens = Get-NameTokens $app.Name $app.Publisher
    if ($tokens) {
        $dataRoots = @(
            @{ Root = $env:APPDATA; Kind = 'APPDATA' },
            @{ Root = $env:LOCALAPPDATA; Kind = 'LOCALAPPDATA' },
            @{ Root = (Join-Path $env:LOCALAPPDATA 'Programs'); Kind = 'LOCALAPPDATA\Programs' },
            @{ Root = $env:ProgramData; Kind = 'ProgramData' }
        ) | Where-Object { $_.Root -and (Test-Path $_.Root) }

        foreach ($r in $dataRoots) {
            foreach ($tok in $tokens) {
                $candidates = Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$tok*" }
                foreach ($c in $candidates) {
                    if (Test-ProtectedPath $c.FullName) { continue }
                    if (-not ($result | Where-Object { $_.Path -eq $c.FullName })) {
                        $result.Add([pscustomobject]@{
                            Path = $c.FullName; Tipo = $r.Kind; SizeMB = (Get-FolderSizeMB $c.FullName)
                        })
                    }
                }
            }
        }
    }

    # 5) Carpetas de cache (temporales, cache, logs) - se ofrecen al final
    if ($tokens) {
        $cachePatterns = @('*cache*', '*temp*', '*tmp*', '*log*')
        $cacheRoots = @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData) |
            Where-Object { $_ -and (Test-Path $_) }
        foreach ($root in $cacheRoots) {
            foreach ($tok in $tokens) {
                foreach ($pat in $cachePatterns) {
                    $candidates = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*$tok*" -and $_.Name -like $pat }
                    foreach ($c in $candidates) {
                        if (Test-ProtectedPath $c.FullName) { continue }
                        if (-not ($result | Where-Object { $_.Path -eq $c.FullName })) {
                            $result.Add([pscustomobject]@{
                                Path = $c.FullName; Tipo = 'Cache'; SizeMB = (Get-FolderSizeMB $c.FullName)
                            })
                        }
                    }
                }
            }
        }
    }

    $result | Sort-Object Path -Unique
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

# Accesos directos del programa (Escritorio, Menu Inicio, Taskbar)
function Get-Shortcuts($app) {
    $result = New-Object System.Collections.Generic.List[object]
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
                ForEach-Object {
                    $result.Add([pscustomobject]@{
                        Path = $_.FullName; Tipo = 'Acceso directo'
                    })
                }
        }
    }
    $result | Sort-Object Path -Unique
}

# ============================================================
#  BORRADO SEGURO (CON PROTECCIONES)
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

function Remove-FolderSafe([string]$folder) {
    if (Test-ProtectedPath $folder) {
        Write-Host "   RUTA PROTEGIDA (documentos de usuario), se omite: $folder" -ForegroundColor Red
        return
    }

    if (Test-FolderContainsUserFiles $folder) {
        Write-Host "   ADVERTENCIA: La carpeta contiene archivos de usuario (.docx, .xlsx, .pdf, etc.)" -ForegroundColor Red
        Write-Host "   Carpeta: $folder" -ForegroundColor Yellow
        $userFiles = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $script:ProtectedExtensions -contains $_.Extension.ToLower() } |
            Select-Object -First 10
        Write-Host "   Archivos de usuario encontrados (muestra):" -ForegroundColor Yellow
        $userFiles | ForEach-Object { Write-Host "      - $($_.FullName)" -ForegroundColor DarkGray }
        if (-not (Confirm-YesNo "   La carpeta contiene archivos de usuario. Borrar TODO de todas formas?")) {
            Write-Host "   Omitida." -ForegroundColor DarkGray
            return
        }
    }

    if ($WhatIf) { Write-Host "   [WhatIf] Se borraria carpeta: $folder" -ForegroundColor Cyan; return }

    Stop-ProcessesInFolder $folder
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $folder) {
        & icacls.exe $folder /setowner "*S-1-5-32-544" /t /c /q | Out-Null
        & icacls.exe $folder /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q | Out-Null
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $folder) {
        Write-Host "   No se pudo borrar todo: $folder" -ForegroundColor Red
    }
    else {
        Write-Host "   Eliminada: $folder" -ForegroundColor Green
    }
}

function Remove-FileSafe([string]$file) {
    if ($WhatIf) { Write-Host "   [WhatIf] Se borraria archivo: $file" -ForegroundColor Cyan; return }
    if (-not (Test-Path -LiteralPath $file)) { return }

    # Proteger archivos de usuario
    $ext = [IO.Path]::GetExtension($file).ToLower()
    if ($script:ProtectedExtensions -contains $ext) {
        Write-Host "   ARCHIVO DE USUARIO PROTEGIDO, se omite: $file" -ForegroundColor Red
        return
    }

    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $file) {
        & icacls.exe $file /setowner "*S-1-5-32-544" /c /q | Out-Null
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "   Eliminado: $file" -ForegroundColor Green
    }
    else {
        Write-Host "   No se pudo borrar: $file" -ForegroundColor Red
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
#  FLUJO PRINCIPAL DE LIMPIEZA
# ============================================================
function Invoke-ForcedRemoval($app) {
    Write-Host "`n=== ELIMINACION FORZADA: $($app.Name) ===" -ForegroundColor Red
    if ($WhatIf) { Write-Host "MODO SIMULACION (no se borrara nada)" -ForegroundColor Magenta }

    # ----- FASE 1: recolectar todas las rutas -----
    Write-Host "`n[1/3] Buscando TODAS las rutas asociadas al programa..." -ForegroundColor Cyan
    $paths = @(Get-AppAssociatedPaths $app)
    $shortcuts = @(Get-Shortcuts $app)

    # ----- FASE 2: mostrar resumen -----
    Write-Host "`n--- RUTAS ENCONTRADAS ---" -ForegroundColor Yellow
    if ($paths.Count -eq 0 -and $shortcuts.Count -eq 0) {
        Write-Host "No se encontraron rutas asociadas." -ForegroundColor Yellow
        return
    }

    $idx = 1
    foreach ($p in $paths) {
        Write-Host ("  {0,2}. [{1}] {2}  ({3} MB)" -f $idx, $p.Tipo, $p.Path, $p.SizeMB) -ForegroundColor Cyan
        $idx++
    }
    foreach ($s in $shortcuts) {
        Write-Host ("  {0,2}. [Acceso directo] {1}" -f $idx, $s.Path) -ForegroundColor Cyan
        $idx++
    }

    Write-Host "`nNOTA: Las carpetas de Documentos, Escritorio, Descargas, Imagenes, etc." -ForegroundColor Green
    Write-Host "      NUNCA se incluyen en esta lista (estan protegidas)." -ForegroundColor Green
    Write-Host "      Los archivos .docx, .xlsx, .pdf, .jpg, .mp4, etc. NUNCA se borran." -ForegroundColor Green

    # ----- FASE 3: preguntar una por una -----
    Write-Host "`n[2/3] Preguntando por cada ruta (una por una)..." -ForegroundColor Cyan
    if ((Read-Host "`nEscribe CONTINUAR para empezar a preguntar") -cne 'CONTINUAR') {
        Write-Host "Cancelado."; return
    }

    foreach ($p in $paths) {
        if (Confirm-YesNo "`nBorrar carpeta [$($p.Tipo)] '$($p.Path)' ($($p.SizeMB) MB)?") {
            Remove-FolderSafe $p.Path
        }
        else {
            Write-Host "   Omitida: $($p.Path)" -ForegroundColor DarkGray
        }
    }

    foreach ($s in $shortcuts) {
        if (Confirm-YesNo "`nBorrar acceso directo '$($s.Path)'?") {
            Remove-FileSafe $s.Path
        }
        else {
            Write-Host "   Omitido: $($s.Path)" -ForegroundColor DarkGray
        }
    }

    # ----- FASE 4: limpieza final opcional -----
    Write-Host "`n[3/3] Limpieza final opcional..." -ForegroundColor Cyan
    if (Confirm-YesNo "`nQuieres borrar la entrada de desinstalacion del registro (para que desaparezca de la lista de programas)?") {
        if ($WhatIf) {
            Write-Host "   [WhatIf] Se borraria clave: $($app.PSPath)" -ForegroundColor Cyan
        }
        else {
            try {
                $safeName = ($app.Key -replace '[\\/:*?"<>|]', '_')
                $backup = Join-Path $env:TEMP ("RegBackup_{0}_{1}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $safeName)
                $native = $app.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
                $native = $native -replace '^HKCU:\\?', 'HKEY_CURRENT_USER\' -replace '^HKLM:\\?', 'HKEY_LOCAL_MACHINE\'
                & reg.exe export $native $backup /y 2>&1 | Out-Null
                Remove-Item -LiteralPath $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   Entrada de desinstalacion eliminada (backup: $backup)" -ForegroundColor Green
            }
            catch {
                Write-Host "   No se pudo borrar la entrada: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "   Omitida. El programa seguira apareciendo en la lista." -ForegroundColor DarkGray
    }

    # Refrescar Explorer
    Refresh-Explorer

    Write-Host "`n=== LIMPIEZA COMPLETADA PARA: $($app.Name) ===" -ForegroundColor Green
}

# ============================================================
#  PROGRAMA PRINCIPAL
# ============================================================
Write-Host "Cargando programas instalados..." -ForegroundColor Cyan
if ($WhatIf) { Write-Host "MODO SIMULACION ACTIVADO (-WhatIf): no se borrara nada." -ForegroundColor Magenta }

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
        Write-Host "`nQuieres revisar si quedaron restos (carpetas, accesos directos)?" -ForegroundColor Yellow
        if (Confirm-YesNo "Revisar y limpiar restos opcionales?") {
            Invoke-ForcedRemoval $target
        }
        $all = Get-InstalledApps
        Read-Host "Enter para continuar" | Out-Null
        continue
    }

    # 3) Forzado
    Write-Host "`nEl programa sigue registrado como instalado." -ForegroundColor Red
    if (Confirm-YesNo "Intentar eliminacion forzada (mostrar rutas y preguntar una por una)?") {
        Invoke-ForcedRemoval $target
    }

    $all = Get-InstalledApps
    Read-Host "`nEnter para continuar" | Out-Null
}

Write-Host "`nLog guardado en: $LogFile" -ForegroundColor DarkGray
try { Stop-Transcript | Out-Null } catch {}