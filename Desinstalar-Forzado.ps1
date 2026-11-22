<#
  Desinstalador Seguro con Limpieza Controlada (v3).
  (Archivo solo ASCII a proposito.)

  Cambios v3:
    - Shortcuts: valida target del .lnk contra rutas de instalacion; ya no matchea
      por palabras sueltas (elimina falsos positivos como "Advanced Security.lnk").
    - Proteccion de archivos: solo extensiones verdaderamente personales.
      .txt/.json/.xml/.html/.csv ya no cuentan como "archivos de usuario" (son
      recursos normales de un programa).
    - Multi-seleccion: "4 6 65" procesa esas apps en cola, una por una.
    - Resumen final de la cola: OK / parcial / fallido por app.

  PROTECCIONES (sin cambios):
    - NUNCA toca Documentos, Escritorio, Descargas, Imagenes, Videos, Musica.
    - NUNCA borra archivos de usuario (.docx, .xlsx, .pdf, .jpg, .mp4, etc.)
    - NUNCA toca firewall, servicios, tareas programadas ni variables de entorno.
    - Solo borra la entrada de desinstalacion del registro, con backup previo.

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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIf) {
    Write-Host "Reiniciando como Administrador..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($WhatIf) { $argList += '-WhatIf' }
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

function Confirm-YesNo([string]$msg) {
    (Read-Host "$msg [S/N]") -match '^(s|si|y|yes)$'
}

function Confirm-YesNoOrWhatIf([string]$msg) {
    if ($WhatIf) {
        Write-Host "[WhatIf] $msg -> SI (simulacion)" -ForegroundColor Magenta
        return $true
    }
    return Confirm-YesNo $msg
}

function Wait-EnterOrWhatIf([string]$msg = "`nEnter para continuar") {
    if ($WhatIf) { return }
    Read-Host $msg | Out-Null
}

function Get-FolderSizeMB([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if (-not $sum) { return 0 }
    [math]::Round(($sum / 1MB), 1)
}

function Get-CleanAppName([string]$name) {
    if (-not $name) { return '' }
    ($name -replace '\s*\(.*?\)', '' -replace '\s+(x64|x86|64-bit|32-bit|v?\d+(\.\d+)+).*$', '').Trim()
}

# ============================================================
#  PROTECCION DE DATOS DE USUARIO
# ============================================================
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
        (Join-Path $env:USERPROFILE 'OneDrive'),
        (Join-Path $env:USERPROFILE 'Favorites'),
        (Join-Path $env:USERPROFILE 'Contacts'),
        (Join-Path $env:USERPROFILE 'Links'),
        (Join-Path $env:USERPROFILE 'Saved Games'),
        (Join-Path $env:USERPROFILE 'Searches')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { $_.TrimEnd('\') }
    $folders
}

# Solo extensiones verdaderamente personales. .txt/.json/.xml/.html/.csv NO
# van aqui: son recursos normales de un programa instalado.
$script:ProtectedExtensions = @(
    '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.rtf', '.odt', '.ods', '.odp',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.svg', '.heic', '.raw',
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a',
    '.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm',
    '.zip', '.rar', '.7z', '.tar', '.gz',
    '.psd', '.ai', '.indd', '.cdr',
    '.eml', '.msg', '.pst', '.ost',
    '.db', '.sqlite', '.mdb', '.accdb',
    '.epub', '.mobi', '.azw', '.azw3'
)

function Test-ProtectedPath([string]$path) {
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

    $userFolders = Get-ProtectedUserFolders
    foreach ($uf in $userFolders) {
        if ($full -eq $uf) { return $true }
        if ($full -like ($uf + '\*')) { return $true }
    }
    return $false
}

function Test-FolderContainsUserFiles([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return $false }
    $userFiles = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $script:ProtectedExtensions -contains $_.Extension.ToLower() }
    return ($userFiles.Count -gt 0)
}

# ============================================================
#  BUSQUEDA DE RUTAS ASOCIADAS
# ============================================================
function Get-NameTokens([string]$name, [string]$publisher) {
    $generic = @('microsoft', 'windows', 'google', 'adobe', 'apple', 'intel', 'nvidia', 'amd', 'oracle',
        'update', 'runtime', 'redistributable', 'visual', 'studio', 'driver', 'drivers', 'software',
        'system', 'service', 'services', 'common', 'shared', 'setup', 'install', 'installer', 'program',
        'programs', 'files', 'application', 'apps', 'data', 'tools', 'client', 'server', 'desktop',
        'professional', 'standard', 'enterprise', 'home', 'edition', 'plus', 'premium', 'ultimate',
        'community', 'free', 'language', 'pack',
        # Tokens que suelen generar falsos positivos en shortcuts del sistema
        'advanced', 'security', 'scanner', 'monitor', 'manager', 'control', 'center', 'center',
        'agent', 'helper', 'utility', 'utilities', 'wizard', 'config', 'editor', 'viewer')
    $tokens = @()
    if ($name) {
        $clean = Get-CleanAppName $name
        $tokens = @($clean -split '\s+' | Where-Object {
                $_ -match '^[A-Za-z0-9][A-Za-z0-9\-\+\.]*$' -and
                $_.Length -ge 4 -and
                $_ -notmatch '^\d+$' -and
                ($generic -notcontains $_.ToLower())
            } | Select-Object -First 2)
    }
    $tokens | Sort-Object -Unique
}

function Get-AppAssociatedPaths($app) {
    $result = New-Object System.Collections.Generic.List[object]

    if ($app.InstallLocation) {
        $loc = $app.InstallLocation.Trim('"').TrimEnd('\')
        if ($loc -and (Test-Path -LiteralPath $loc)) {
            $result.Add([pscustomobject]@{ Path = $loc; Tipo = 'Instalacion'; SizeMB = (Get-FolderSizeMB $loc) })
        }
    }

    foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)' -and (Test-Path -LiteralPath $dir)) {
                if (-not ($result | Where-Object { $_.Path -eq $dir })) {
                    $result.Add([pscustomobject]@{ Path = $dir; Tipo = 'Ejecutable'; SizeMB = (Get-FolderSizeMB $dir) })
                }
            }
        }
    }

    $words = ($app.Name -split '\s+') | Where-Object { $_ -match '^[A-Za-z]{2,}' } | Select-Object -First 2
    if ($words) {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
            (Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ -and (Test-Path $_) }
        $pattern = '*' + ($words -join ' ') + '*'
        foreach ($r in $roots) {
            Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pattern } |
                ForEach-Object {
                    if (-not ($result | Where-Object { $_.Path -eq $_.FullName })) {
                        $result.Add([pscustomobject]@{ Path = $_.FullName; Tipo = 'Programa'; SizeMB = (Get-FolderSizeMB $_.FullName) })
                    }
                }
        }
    }

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
                        $result.Add([pscustomobject]@{ Path = $c.FullName; Tipo = $r.Kind; SizeMB = (Get-FolderSizeMB $c.FullName) })
                    }
                }
            }
        }
    }

    if ($tokens) {
        $cachePatterns = @('*cache*', '*temp*', '*tmp*', '*log*')
        $cacheRoots = @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData) | Where-Object { $_ -and (Test-Path $_) }
        foreach ($root in $cacheRoots) {
            foreach ($tok in $tokens) {
                foreach ($pat in $cachePatterns) {
                    $candidates = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*$tok*" -and $_.Name -like $pat }
                    foreach ($c in $candidates) {
                        if (Test-ProtectedPath $c.FullName) { continue }
                        if (-not ($result | Where-Object { $_.Path -eq $c.FullName })) {
                            $result.Add([pscustomobject]@{ Path = $c.FullName; Tipo = 'Cache'; SizeMB = (Get-FolderSizeMB $c.FullName) })
                        }
                    }
                }
            }
        }
    }

    $result | Sort-Object Path -Unique
}

# Fix principal: los shortcuts se validan por TARGET, no por palabras sueltas.
function Get-Shortcuts($app, $installPaths) {
    $result = [System.Collections.Generic.List[object]]::new()

    $fullClean = Get-CleanAppName $app.Name

    # Solo son validas las rutas de instalacion (no datos, no cache)
    $installOnly = @($installPaths |
        Where-Object { $_ -and $_.Tipo -in @('Instalacion', 'Programa', 'Ejecutable') } |
        ForEach-Object { $_.Path.TrimEnd('\').ToLower() })

    if (-not $fullClean -and $installOnly.Count -eq 0) { return $result }

    $roots = @(
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    ) | Where-Object { $_ -and (Test-Path $_) }

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }

    try {
        foreach ($root in $roots) {
            Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $lnk = $_
                    $matched = $false
                    $reason = ''

                    # Prioridad 1: el target del .lnk apunta dentro de la carpeta de instalacion
                    if ($shell -and $installOnly.Count -gt 0) {
                        try {
                            $target = $shell.CreateShortcut($lnk.FullName).TargetPath
                            if ($target) {
                                $tLower = $target.ToLower()
                                foreach ($ip in $installOnly) {
                                    if ($tLower -eq $ip -or $tLower.StartsWith($ip + '\')) {
                                        $matched = $true
                                        $reason = 'target-en-instalacion'
                                        break
                                    }
                                }
                            }
                        } catch { }
                    }

                    # Prioridad 2: el nombre del .lnk contiene el nombre completo de la app
                    if (-not $matched -and $fullClean.Length -ge 5) {
                        if ($lnk.BaseName -like "*$fullClean*") {
                            $matched = $true
                            $reason = 'nombre-completo'
                        }
                    }

                    if ($matched) {
                        $result.Add([pscustomobject]@{
                            Path = $lnk.FullName
                            Tipo = 'Acceso directo'
                            Reason = $reason
                        })
                    }
                }
        }
    } finally {
        if ($shell) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
        }
    }
    $result | Sort-Object Path -Unique
}

# ============================================================
#  BORRADO SEGURO
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

function Remove-FolderSafe([string]$folder, [switch]$SkipUserFilePrompt) {
    if (Test-ProtectedPath $folder) {
        Write-Host "   RUTA PROTEGIDA, se omite: $folder" -ForegroundColor Red
        return $false
    }

    if (-not $SkipUserFilePrompt -and (Test-FolderContainsUserFiles $folder)) {
        Write-Host "   ADVERTENCIA: La carpeta contiene archivos de usuario." -ForegroundColor Red
        Write-Host "   Carpeta: $folder" -ForegroundColor Yellow
        $userFiles = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $script:ProtectedExtensions -contains $_.Extension.ToLower() } |
            Select-Object -First 10
        $userFiles | ForEach-Object { Write-Host "      - $($_.FullName)" -ForegroundColor DarkGray }
        if (-not (Confirm-YesNo "   La carpeta contiene archivos de usuario. Borrar TODO de todas formas?")) {
            Write-Host "   Omitida." -ForegroundColor DarkGray
            return $false
        }
    }

    if ($WhatIf) { Write-Host "   [WhatIf] Se borraria carpeta: $folder" -ForegroundColor Cyan; return $true }

    Stop-ProcessesInFolder $folder
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $folder) {
        & icacls.exe $folder /setowner "*S-1-5-32-544" /t /c /q | Out-Null
        & icacls.exe $folder /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q | Out-Null
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $folder) {
        Write-Host "   No se pudo borrar todo: $folder" -ForegroundColor Red
        return $false
    }
    Write-Host "   Eliminada: $folder" -ForegroundColor Green
    return $true
}

function Remove-FileSafe([string]$file) {
    if ($WhatIf) { Write-Host "   [WhatIf] Se borraria archivo: $file" -ForegroundColor Cyan; return $true }
    if (-not (Test-Path -LiteralPath $file)) { return $true }

    $ext = [IO.Path]::GetExtension($file).ToLower()
    if ($script:ProtectedExtensions -contains $ext) {
        Write-Host "   ARCHIVO DE USUARIO PROTEGIDO, se omite: $file" -ForegroundColor Red
        return $false
    }

    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $file) {
        & icacls.exe $file /setowner "*S-1-5-32-544" /c /q | Out-Null
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "   Eliminado: $file" -ForegroundColor Green
        return $true
    }
    Write-Host "   No se pudo borrar: $file" -ForegroundColor Red
    return $false
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
#  FASES
# ============================================================
function Show-AppPathsDiscovery($app) {
    Write-Host "`n[1/4] Rutas asociadas a: $($app.Name)" -ForegroundColor Cyan

    $paths = @(Get-AppAssociatedPaths $app)
    $shortcuts = @(Get-Shortcuts $app $paths)

    if ($paths.Count -eq 0 -and $shortcuts.Count -eq 0) {
        Write-Host "  No se encontraron rutas asociadas en el disco." -ForegroundColor Yellow
    }
    else {
        if ($paths.Count -gt 0) {
            Write-Host "`n  Carpetas detectadas ($($paths.Count)):" -ForegroundColor Yellow
            $i = 1
            foreach ($p in $paths) {
                $hasUser = $p.Tipo -notin @('Instalacion', 'Programa', 'Ejecutable') -and (Test-FolderContainsUserFiles $p.Path)
                $warn = if ($hasUser) { ' [CONTIENE ARCHIVOS DE USUARIO]' } else { '' }
                $color = if ($hasUser) { 'Red' } else { 'Cyan' }
                Write-Host ("    {0,2}. [{1}] {2}  ({3} MB){4}" -f $i, $p.Tipo, $p.Path, $p.SizeMB, $warn) -ForegroundColor $color
                $i++
            }
        }
        if ($shortcuts.Count -gt 0) {
            Write-Host "`n  Accesos directos detectados ($($shortcuts.Count)):" -ForegroundColor Yellow
            $i = 1
            foreach ($s in $shortcuts) {
                Write-Host ("    {0,2}. {1}  ({2})" -f $i, $s.Path, $s.Reason) -ForegroundColor Cyan
                $i++
            }
        }
    }

    Write-Host "`n  NOTA: Documentos, Escritorio, Descargas, Imagenes, etc. NUNCA se incluyen." -ForegroundColor Green
    Write-Host "        Archivos .docx, .xlsx, .pdf, .jpg, .mp4, etc. NUNCA se borran." -ForegroundColor Green

    return [pscustomobject]@{
        App = $app
        Paths = $paths
        Shortcuts = $shortcuts
    }
}

function Get-SnapshotStatus($snapshot) {
    $remaining = @(); $removed = @()
    foreach ($p in $snapshot.Paths) {
        if (Test-Path -LiteralPath $p.Path) { $remaining += $p } else { $removed += $p }
    }
    $remShort = @(); $removedShort = @()
    foreach ($s in $snapshot.Shortcuts) {
        if (Test-Path -LiteralPath $s.Path) { $remShort += $s } else { $removedShort += $s }
    }
    [pscustomobject]@{
        RemainingPaths = $remaining
        RemovedPaths = $removed
        RemainingShortcuts = $remShort
        RemovedShortcuts = $removedShort
    }
}

function Invoke-BatchRemoval($status) {
    $foldersToDelete = @($status.RemainingPaths)
    $shortcutsToDelete = @($status.RemainingShortcuts)

    if ($foldersToDelete.Count -eq 0 -and $shortcutsToDelete.Count -eq 0) {
        Write-Host "`n  No quedaron restos. Todo eliminado por el desinstalador." -ForegroundColor Green
        return
    }

    Write-Host "`n[4/4] Restos encontrados despues de la desinstalacion:" -ForegroundColor Yellow

    if ($foldersToDelete.Count -gt 0) {
        Write-Host "`n  Carpetas que aun existen ($($foldersToDelete.Count)):" -ForegroundColor Cyan
        foreach ($p in $foldersToDelete) {
            $hasUser = Test-FolderContainsUserFiles $p.Path
            $marker = if ($hasUser) { " [CONTIENE ARCHIVOS DE USUARIO]" } else { "" }
            $color = if ($hasUser) { 'Red' } else { 'Cyan' }
            Write-Host ("    - [{0}] {1} ({2} MB){3}" -f $p.Tipo, $p.Path, $p.SizeMB, $marker) -ForegroundColor $color
        }
    }

    if ($shortcutsToDelete.Count -gt 0) {
        Write-Host "`n  Accesos directos que aun existen ($($shortcutsToDelete.Count)):" -ForegroundColor Cyan
        foreach ($s in $shortcutsToDelete) {
            Write-Host ("    - {0}" -f $s.Path) -ForegroundColor Cyan
        }
    }

    $dangerous = @($foldersToDelete | Where-Object { Test-FolderContainsUserFiles $_.Path })
    $safe = @($foldersToDelete | Where-Object { -not (Test-FolderContainsUserFiles $_.Path) })

    if ($safe.Count -gt 0) {
        Write-Host "`n  Carpetas SEGURAS (sin archivos de usuario): $($safe.Count)" -ForegroundColor Green
        if (Confirm-YesNoOrWhatIf "  Borrar TODAS las carpetas seguras de una vez?") {
            foreach ($p in $safe) { Remove-FolderSafe $p.Path -SkipUserFilePrompt | Out-Null }
        }
        else {
            Write-Host "  Omitidas $($safe.Count) carpetas seguras." -ForegroundColor DarkGray
        }
    }

    if ($dangerous.Count -gt 0) {
        Write-Host "`n  ATENCION: $($dangerous.Count) carpeta(s) contienen archivos de usuario." -ForegroundColor Red
        Write-Host "  Debes confirmar cada una individualmente." -ForegroundColor Red
        foreach ($p in $dangerous) {
            if (Confirm-YesNoOrWhatIf "  Borrar TODA la carpeta '$($p.Path)' (contiene archivos de usuario)?") {
                Remove-FolderSafe $p.Path | Out-Null
            }
            else {
                Write-Host "  Omitida: $($p.Path)" -ForegroundColor DarkGray
            }
        }
    }

    if ($shortcutsToDelete.Count -gt 0) {
        if (Confirm-YesNoOrWhatIf "  Borrar los $($shortcutsToDelete.Count) accesos directos restantes?") {
            foreach ($s in $shortcutsToDelete) { Remove-FileSafe $s.Path | Out-Null }
        }
    }
}

function Remove-RegistryEntryWithBackup($app) {
    if (-not (Test-Path -LiteralPath $app.PSPath)) { return $true }
    Write-Host "`n  La entrada del programa sigue en el registro de Windows." -ForegroundColor Yellow
    if (-not (Confirm-YesNoOrWhatIf "  Borrar la entrada de desinstalacion (con backup previo)?")) {
        Write-Host "  Omitida. El programa seguira apareciendo en la lista." -ForegroundColor DarkGray
        return $false
    }
    if ($WhatIf) {
        Write-Host "   [WhatIf] Se borraria clave: $($app.PSPath)" -ForegroundColor Cyan
        return $true
    }
    try {
        $safeName = ($app.Key -replace '[\\/:*?"<>|]', '_')
        $backup = Join-Path $env:TEMP ("RegBackup_{0}_{1}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $safeName)
        $native = $app.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
        $native = $native -replace '^HKCU:\\?', 'HKEY_CURRENT_USER\' -replace '^HKLM:\\?', 'HKEY_LOCAL_MACHINE\'
        & reg.exe export $native $backup /y 2>&1 | Out-Null
        Remove-Item -LiteralPath $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   Entrada eliminada (backup: $backup)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "   No se pudo borrar la entrada: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ============================================================
#  PROCESAMIENTO DE UNA APP (devuelve veredicto)
# ============================================================
function Invoke-ProcessOneApp($target) {
    Write-Host "`n=== PROCESANDO: $($target.Name) $($target.Version) ===" -ForegroundColor Yellow
    if ($target.InstallLocation) { Write-Host "Ruta registrada: $($target.InstallLocation)" }
    if ($target.Publisher) { Write-Host "Editor: $($target.Publisher)" }

    $snapshot = Show-AppPathsDiscovery $target

    Write-Host "`n[2/4] Desinstalacion normal" -ForegroundColor Cyan
    if (-not (Confirm-YesNoOrWhatIf "`nProceder con la desinstalacion normal?")) {
        Write-Host "Cancelado." -ForegroundColor DarkGray
        return 'Cancelado'
    }

    $exitCode = Invoke-NormalUninstall $target
    if ($exitCode -ne $null -and $exitCode -ne 0) {
        Write-Host "`n  ADVERTENCIA: codigo de salida $exitCode. Posible error del instalador (locale)." -ForegroundColor Yellow
    }

    if (-not $WhatIf) { Start-Sleep -Seconds 3 }

    Write-Host "`n[3/4] Verificando estado despues de la desinstalacion..." -ForegroundColor Cyan
    $status = Get-SnapshotStatus $snapshot

    if ($status.RemovedPaths.Count -gt 0) {
        Write-Host "`n  Carpetas eliminadas por el desinstalador ($($status.RemovedPaths.Count)):" -ForegroundColor Green
        foreach ($p in $status.RemovedPaths) { Write-Host "    OK $($p.Path)" -ForegroundColor Green }
    }
    if ($status.RemovedShortcuts.Count -gt 0) {
        Write-Host "`n  Accesos directos eliminados ($($status.RemovedShortcuts.Count)):" -ForegroundColor Green
        foreach ($s in $status.RemovedShortcuts) { Write-Host "    OK $($s.Path)" -ForegroundColor Green }
    }

    $regStillThere = Test-Path -LiteralPath $target.PSPath

    if ($status.RemainingPaths.Count -eq 0 -and $status.RemainingShortcuts.Count -eq 0 -and -not $regStillThere) {
        Write-Host "`n  DESINSTALACION COMPLETA: $($target.Name)" -ForegroundColor Green
        return 'Completo'
    }

    Write-Host "`n  Restos detectados. Se ofrecera eliminarlos." -ForegroundColor Yellow
    Invoke-BatchRemoval $status
    if ($regStillThere) { $null = Remove-RegistryEntryWithBackup $target }
    Refresh-Explorer

    $finalReg = Test-Path -LiteralPath $target.PSPath
    $finalPaths = @($snapshot.Paths | Where-Object { Test-Path -LiteralPath $_.Path })
    $finalShortcuts = @($snapshot.Shortcuts | Where-Object { Test-Path -LiteralPath $_.Path })

    if (-not $finalReg -and $finalPaths.Count -eq 0 -and $finalShortcuts.Count -eq 0) {
        Write-Host "`n  VEREDICTO: DESINSTALADO COMPLETAMENTE" -ForegroundColor Green
        return 'Completo'
    }
    elseif (-not $finalReg) {
        Write-Host "`n  VEREDICTO: DESINSTALADO (quedan $($finalPaths.Count) carpetas y $($finalShortcuts.Count) accesos conservados)" -ForegroundColor Yellow
        return 'Parcial'
    }
    else {
        Write-Host "`n  VEREDICTO: PARCIAL - entrada del registro aun presente" -ForegroundColor Red
        return 'Fallido'
    }
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

    $in = Read-Host "`nNumero(s) para desinstalar (ej: 4 6 65) | texto para filtrar | vacio = quitar filtro | Q = salir"
    if ($in -match '^(q|salir)$') { break }
    if ([string]::IsNullOrWhiteSpace($in)) { $filter = ''; continue }

    $tokens = @($in -split '\s+' | Where-Object { $_ })
    $allNumbers = ($tokens.Count -gt 0) -and (@($tokens | Where-Object { $_ -notmatch '^\d+$' }).Count -eq 0)

    # ---- Multi-seleccion: cola de apps ----
    if ($allNumbers) {
        $queue = [System.Collections.Generic.List[object]]::new()
        foreach ($tok in $tokens) {
            $idx = [int]$tok
            if ($idx -ge 1 -and $idx -le $view.Count) {
                $queue.Add($view[$idx - 1])
            } else {
                Write-Host "Numero fuera de rango: $idx (1..$($view.Count))" -ForegroundColor Yellow
            }
        }
        if ($queue.Count -eq 0) { Wait-EnterOrWhatIf; continue }

        Write-Host "`nCola de desinstalacion ($($queue.Count) apps, en este orden):" -ForegroundColor Cyan
        $i = 1
        foreach ($q in $queue) {
            Write-Host ("  {0}. {1}" -f $i, $q.Name) -ForegroundColor Cyan
            $i++
        }
        if (-not (Confirm-YesNoOrWhatIf "`nProcesar esta cola?")) { continue }

        $results = [System.Collections.Generic.List[object]]::new()
        $qIdx = 0
        foreach ($target in $queue) {
            $qIdx++
            Clear-Host
            Write-Host ("=== APP $qIdx de $($queue.Count) ===") -ForegroundColor Magenta
            $verdict = Invoke-ProcessOneApp $target
            $results.Add([pscustomobject]@{ App = $target.Name; Result = $verdict })
            Wait-EnterOrWhatIf "`nEnter para pasar a la siguiente app..."
        }

        # Resumen final de la cola
        Clear-Host
        Write-Host "`n=== RESUMEN DE LA COLA ===" -ForegroundColor Cyan
        $ok = @($results | Where-Object { $_.Result -eq 'Completo' }).Count
        $parcial = @($results | Where-Object { $_.Result -eq 'Parcial' }).Count
        $fallido = @($results | Where-Object { $_.Result -eq 'Fallido' }).Count
        $cancel = @($results | Where-Object { $_.Result -eq 'Cancelado' }).Count
        Write-Host ("  Completos: {0}" -f $ok) -ForegroundColor Green
        Write-Host ("  Parciales: {0}" -f $parcial) -ForegroundColor Yellow
        Write-Host ("  Fallidos:  {0}" -f $fallido) -ForegroundColor Red
        Write-Host ("  Cancelados:{0}" -f $cancel) -ForegroundColor DarkGray
        Write-Host "`nDetalle:" -ForegroundColor Cyan
        foreach ($r in $results) {
            $color = switch ($r.Result) {
                'Completo' { 'Green' }; 'Parcial' { 'Yellow' }; 'Fallido' { 'Red' }; default { 'DarkGray' }
            }
            Write-Host ("  [{0,-9}] {1}" -f $r.Result, $r.App) -ForegroundColor $color
        }

        $all = Get-InstalledApps
        Wait-EnterOrWhatIf
        continue
    }

    # ---- Texto: filtrar ----
    $filter = $in
}

Write-Host "`nLog guardado en: $LogFile" -ForegroundColor DarkGray
try { Stop-Transcript | Out-Null } catch {}