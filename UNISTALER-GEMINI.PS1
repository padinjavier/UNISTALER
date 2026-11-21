<#
  UNISTALER GUI - Desinstalador Seguro con Limpieza Controlada y Consola en Vivo.
  (Archivo ASCII puro para ejecucion confiable via irm/iex o archivo .ps1.)

  Ejecucion recomendada:
    irm https://raw.githubusercontent.com/padinjavier/UNISTALER/main/UNISTALER-GUI.ps1 | iex

  Modo simulacion:
    $env:UNISTALER_WHATIF = '1'; irm https://raw.githubusercontent.com/padinjavier/UNISTALER/main/UNISTALER-GUI.ps1 | iex

  PROTECCIONES:
  - Nunca borra Documentos, Escritorio, Descargas, Imagenes, Videos, Musica, OneDrive, etc.
  - Nunca borra archivos de usuario (.docx, .xlsx, .pdf, .jpg, .mp4, .zip, etc.).
  - Nunca toca firewall, servicios, tareas programadas ni variables de entorno.
  - Respalda la clave de desinstalacion en %TEMP% antes de eliminarla si el usuario lo aprueba.
#>

param(
    [switch]$ConsoleHost
)

$ErrorActionPreference = 'Stop'
$ScriptUrl = 'https://raw.githubusercontent.com/padinjavier/UNISTALER/main/UNISTALER-GUI.ps1'
$WhatIf = ($env:UNISTALER_WHATIF -eq '1')

function Test-IsAdmin {
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
#  PASO 1: GARANTIZAR CONSOLA POWERSHELL ELEVADA + VENTANA UI
#  Si se ejecuta con 'irm ... | iex', $PSCommandPath esta vacio,
#  por lo que se descarga o guarda en %TEMP% y se relanza en una
#  consola PowerShell visible como Administrador con -ConsoleHost.
# ============================================================
if (-not $ConsoleHost) {
    $targetScript = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($targetScript) -or -not (Test-Path -LiteralPath $targetScript)) {
        $targetScript = Join-Path $env:TEMP ("UNISTALER_GUI_{0}.ps1" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        try {
            Invoke-WebRequest -Uri $ScriptUrl -OutFile $targetScript -UseBasicParsing
        }
        catch {
            Write-Host "[ERROR] No se pudo descargar el script desde $ScriptUrl : $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    $psArgs = @(
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$targetScript`"",
        '-ConsoleHost'
    )

    if (-not (Test-IsAdmin) -and -not $WhatIf) {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $psArgs | Out-Null
    }
    else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs | Out-Null
    }
    return
}

# ============================================================
#  PASO 2: DENTRO DE LA CONSOLA ANFITRIONA (LOG EN TIEMPO REAL)
# ============================================================
$Host.UI.RawUI.WindowTitle = "UNISTALER - Consola de Ejecucion y Log en Vivo"
$LogFile = Join-Path $env:TEMP ("Unistaler_Log_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$script:LogLock = New-Object System.Object

function Write-ConsoleLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'CMD', 'SIM')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'HH:mm:ss'
    $prefix = "[$ts][$Level] "
    $line = $prefix + $Message

    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'CMD'  { 'Cyan' }
        'SIM'  { 'Magenta' }
        default { 'Gray' }
    }

    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        Write-Host $line -ForegroundColor $color
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }
}

Write-ConsoleLog "Consola inicializada. Log guardado en: $LogFile" 'INFO'
Write-ConsoleLog ("Privilegios de Administrador: {0}" -f (Test-IsAdmin)) (if (Test-IsAdmin) { 'OK' } else { 'WARN' })
if ($WhatIf) {
    Write-ConsoleLog "MODO SIMULACION ACTIVO (UNISTALER_WHATIF=1). No se borrara nada." 'SIM'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
#  PASO 3: PROTECCIONES Y DETECCION DE APLICACIONES
# ============================================================
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

function Get-ProtectedUserFolders {
    @(
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyVideos'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('CommonDocuments'),
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
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { $_.TrimEnd('\').ToLower() } | Sort-Object -Unique
}

function Test-ProtectedPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $true }
    try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $true }
    if ($full.Length -le 3) { return $true }

    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { $pf86 = $env:ProgramFiles }

    $protectedRoots = @(
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
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

    $fullLower = $full.ToLower()
    if ($protectedRoots -contains $fullLower) { return $true }

    $winPrefix = ($env:windir.TrimEnd('\') + '\').ToLower()
    if ($fullLower.StartsWith($winPrefix)) { return $true }

    $pfWinPrefix = ((Join-Path $env:ProgramFiles 'Windows').TrimEnd('\')).ToLower()
    $pf86WinPrefix = ((Join-Path $pf86 'Windows').TrimEnd('\')).ToLower()
    if ($fullLower.StartsWith($pfWinPrefix) -or $fullLower.StartsWith($pf86WinPrefix)) { return $true }

    foreach ($uf in (Get-ProtectedUserFolders)) {
        if ($fullLower -eq $uf -or $fullLower.StartsWith($uf + '\')) { return $true }
    }

    return $false
}

function Test-FolderContainsUserFiles([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return $false }
    $found = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $script:ProtectedExtensions -contains $_.Extension.ToLower() } |
        Select-Object -First 1
    return ($null -ne $found)
}

function Get-FolderSizeMB([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0.0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if (-not $sum) { return 0.0 }
    return [math]::Round(($sum / 1MB), 1)
}

function Get-ExeFromString([string]$s) {
    if (-not $s) { return $null }
    if ($s -match '^\s*"?([A-Za-z]:\\[^"]*?\.(?:exe|ico|dll))') { return $matches[1] }
    return $null
}

function Get-NameTokens([string]$name, [string]$publisher) {
    $generic = @(
        'microsoft', 'windows', 'google', 'adobe', 'apple', 'intel', 'nvidia', 'amd', 'oracle',
        'update', 'runtime', 'redistributable', 'visual', 'studio', 'driver', 'drivers', 'software',
        'system', 'service', 'services', 'common', 'shared', 'setup', 'install', 'installer', 'program',
        'programs', 'files', 'application', 'apps', 'data', 'tools', 'client', 'server', 'desktop',
        'professional', 'standard', 'enterprise', 'home', 'edition', 'plus', 'premium', 'ultimate',
        'community', 'free', 'language', 'pack'
    )
    $tokens = @()
    if ($name) {
        $clean = $name -replace '\s*\(.*?\)', '' -replace '\s+(x64|x86|64-bit|32-bit|v?\d+(\.\d+)+).*$', ''
        $tokens = @(
            $clean -split '\s+' | Where-Object {
                $_ -match '^[A-Za-z0-9][A-Za-z0-9\-\+\.]*$' -and
                $_.Length -ge 4 -and
                $_ -notmatch '^\d+$' -and
                ($generic -notcontains $_.ToLower())
            } | Select-Object -First 2
        )
    }
    return @($tokens | Sort-Object -Unique)
}

function Get-AppIconBitmap([string]$iconPath) {
    if ([string]::IsNullOrWhiteSpace($iconPath)) { return $null }
    $cleanPath = $iconPath.Trim('"')
    if (-not (Test-Path -LiteralPath $cleanPath)) { return $null }
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($cleanPath)
        if ($ico) {
            $bmp = $ico.ToBitmap()
            $ico.Dispose()
            return $bmp
        }
    }
    catch {}
    return $null
}

function Get-InstalledApps {
    $keys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKLM-64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKLM-32' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKCU' }
    )

    $seen = @{}
    $list = New-Object System.Collections.Generic.List[object]

    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k.Path)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $k.Path -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            if ($p.SystemComponent -eq 1) { continue }
            if ($p.ParentKeyName) { continue }
            if ($p.ReleaseType -in 'Update', 'Hotfix', 'Security Update') { continue }
            if ($p.DisplayName -match 'KB\d{6,}') { continue }

            $dedupKey = "$($p.DisplayName.Trim().ToLower())|$($p.DisplayVersion)|$($k.Origen)"
            if ($seen.ContainsKey($dedupKey)) { continue }
            $seen[$dedupKey] = $true

            $iconPath = $null
            if ($p.DisplayIcon) {
                if ($p.DisplayIcon -match '^"([^"]+)"') { $iconPath = $matches[1] }
                elseif ($p.DisplayIcon -match '^([^,]+)') { $iconPath = $matches[1].Trim() }
            }
            if (-not $iconPath -and $p.InstallLocation) {
                $locClean = $p.InstallLocation.Trim('"')
                if (Test-Path -LiteralPath $locClean) {
                    $exe = Get-ChildItem -LiteralPath $locClean -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($exe) { $iconPath = $exe.FullName }
                }
            }

            $list.Add([pscustomobject]@{
                Name                 = [string]$p.DisplayName
                Version              = [string]$p.DisplayVersion
                Publisher            = [string]$p.Publisher
                InstallLocation      = [string]$p.InstallLocation
                DisplayIcon          = [string]$p.DisplayIcon
                IconPath             = $iconPath
                UninstallString      = [string]$p.UninstallString
                QuietUninstallString = [string]$p.QuietUninstallString
                WindowsInstaller     = $p.WindowsInstaller
                Key                  = [string]$item.PSChildName
                PSPath               = [string]$item.PSPath
                Origen               = [string]$k.Origen
            })
        }
    }

    return @($list | Sort-Object Name)
}

function Get-AppAssociatedPaths($app) {
    $result = New-Object System.Collections.Generic.List[object]
    $added = @{}

    function Add-PathEntry([string]$pPath, [string]$pTipo) {
        if ([string]::IsNullOrWhiteSpace($pPath)) { return }
        try { $norm = [IO.Path]::GetFullPath($pPath).TrimEnd('\') } catch { return }
        if (-not (Test-Path -LiteralPath $norm)) { return }
        $keyLower = $norm.ToLower()
        if ($added.ContainsKey($keyLower)) { return }
        $added[$keyLower] = $true
        $result.Add([pscustomobject]@{
            Path   = $norm
            Tipo   = $pTipo
            SizeMB = (Get-FolderSizeMB $norm)
        })
    }

    if ($app.InstallLocation) {
        Add-PathEntry $app.InstallLocation.Trim('"') 'Instalacion'
    }

    foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)') {
                Add-PathEntry $dir 'Ejecutable'
            }
        }
    }

    $words = @((($app.Name -split '\s+') | Where-Object { $_ -match '^[A-Za-z]{2,}' } | Select-Object -First 2))
    if ($words.Count -gt 0) {
        $pf86 = ${env:ProgramFiles(x86)}
        $roots = @($env:ProgramFiles, $pf86, $env:ProgramData, (Join-Path $env:LOCALAPPDATA 'Programs')) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        $pattern = '*' + ($words -join ' ') + '*'
        foreach ($r in $roots) {
            Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pattern } |
                ForEach-Object { Add-PathEntry $_.FullName 'Programa' }
        }
    }

    $tokens = Get-NameTokens $app.Name $app.Publisher
    if ($tokens.Count -gt 0) {
        $dataRoots = @(
            @{ Root = $env:APPDATA; Kind = 'APPDATA' },
            @{ Root = $env:LOCALAPPDATA; Kind = 'LOCALAPPDATA' },
            @{ Root = (Join-Path $env:LOCALAPPDATA 'Programs'); Kind = 'LOCALAPPDATA\Programs' },
            @{ Root = $env:ProgramData; Kind = 'ProgramData' }
        ) | Where-Object { $_.Root -and (Test-Path -LiteralPath $_.Root) }

        foreach ($r in $dataRoots) {
            foreach ($tok in $tokens) {
                Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$tok*" } |
                    ForEach-Object {
                        if (-not (Test-ProtectedPath $_.FullName)) {
                            Add-PathEntry $_.FullName $r.Kind
                        }
                    }
            }
        }

        $cachePatterns = @('*cache*', '*temp*', '*tmp*', '*log*')
        $cacheRoots = @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        foreach ($root in $cacheRoots) {
            foreach ($tok in $tokens) {
                foreach ($pat in $cachePatterns) {
                    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*$tok*" -and $_.Name -like $pat } |
                        ForEach-Object {
                            if (-not (Test-ProtectedPath $_.FullName)) {
                                Add-PathEntry $_.FullName 'Cache'
                            }
                        }
                }
            }
        }
    }

    return @($result)
}

function Get-AppShortcuts($app) {
    $result = New-Object System.Collections.Generic.List[object]
    $added = @{}
    $tokens = Get-NameTokens $app.Name $app.Publisher
    if ($tokens.Count -eq 0) { return @() }

    $roots = @(
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($root in $roots) {
        foreach ($tok in $tokens) {
            Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$tok*" } |
                ForEach-Object {
                    $k = $_.FullName.ToLower()
                    if (-not $added.ContainsKey($k)) {
                        $added[$k] = $true
                        $result.Add([pscustomobject]@{
                            Path = $_.FullName
                            Tipo = 'Acceso directo'
                        })
                    }
                }
        }
    }

    return @($result)
}

function Stop-ProcessesInFolder([string]$folder) {
    $prefix = $folder.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            Write-ConsoleLog "Cerrando proceso activo: $($_.Name) (PID $($_.ProcessId))" 'WARN'
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
}

function Remove-FolderSafe([string]$folder, [bool]$AllowUserFilesOverride = $false) {
    if (Test-ProtectedPath $folder) {
        Write-ConsoleLog "RUTA PROTEGIDA omitida: $folder" 'WARN'
        return $false
    }

    if ((Test-FolderContainsUserFiles $folder) -and -not $AllowUserFilesOverride) {
        Write-ConsoleLog "Carpeta contiene archivos de usuario (.docx, .xlsx, .pdf, etc.), se omite por seguridad: $folder" 'WARN'
        return $false
    }

    if ($WhatIf) {
        Write-ConsoleLog "[WhatIf] Se eliminaria carpeta: $folder" 'SIM'
        return $true
    }

    Stop-ProcessesInFolder $folder
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $folder) {
        & icacls.exe $folder /setowner "*S-1-5-32-544" /t /c /q 2>&1 | Out-Null
        & icacls.exe $folder /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $folder) {
        Write-ConsoleLog "No se pudo eliminar por completo la carpeta: $folder" 'ERR'
        return $false
    }

    Write-ConsoleLog "Carpeta eliminada: $folder" 'OK'
    return $true
}

function Remove-FileSafe([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $true }
    $ext = [IO.Path]::GetExtension($file).ToLower()
    if ($script:ProtectedExtensions -contains $ext) {
        Write-ConsoleLog "Archivo de usuario protegido, omitido: $file" 'WARN'
        return $false
    }

    if ($WhatIf) {
        Write-ConsoleLog "[WhatIf] Se eliminaria archivo: $file" 'SIM'
        return $true
    }

    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $file) {
        & icacls.exe $file /setowner "*S-1-5-32-544" /c /q 2>&1 | Out-Null
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $file) {
        Write-ConsoleLog "No se pudo eliminar el archivo: $file" 'ERR'
        return $false
    }

    Write-ConsoleLog "Archivo eliminado: $file" 'OK'
    return $true
}

function Invoke-NormalUninstallStep($app, [int]$TimeoutMin = 15) {
    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')

    if ($isMsi) {
        $exe = 'msiexec.exe'
        $argLine = "/x $($app.Key) /qn /norestart"
        Write-ConsoleLog "Ejecutando MSI silencioso: $exe $argLine" 'CMD'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($app.QuietUninstallString)) {
        $exe = 'cmd.exe'
        $argLine = "/c $($app.QuietUninstallString)"
        Write-ConsoleLog "Ejecutando desinstalador silencioso: $exe $argLine" 'CMD'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($app.UninstallString)) {
        $exe = 'cmd.exe'
        $argLine = "/c $($app.UninstallString)"
        Write-ConsoleLog "Ejecutando desinstalador estandar: $exe $argLine" 'CMD'
    }
    else {
        Write-ConsoleLog "No existe comando de desinstalacion registrado para '$($app.Name)'." 'WARN'
        return $null
    }

    if ($WhatIf) {
        Write-ConsoleLog "[WhatIf] Comando simulado: $exe $argLine" 'SIM'
        return 0
    }

    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
        if (-not $proc.WaitForExit($TimeoutMin * 60 * 1000)) {
            Write-ConsoleLog "Tiempo de espera agotado ($TimeoutMin min). Deteniendo proceso PID $($proc.Id)." 'ERR'
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            return -1
        }
        Write-ConsoleLog "Desinstalador finalizado con codigo de salida: $($proc.ExitCode)" (if ($proc.ExitCode -eq 0) { 'OK' } else { 'WARN' })
        return $proc.ExitCode
    }
    catch {
        Write-ConsoleLog "Error al ejecutar desinstalador para '$($app.Name)': $($_.Exception.Message)" 'ERR'
        return -1
    }
}

# ============================================================
#  PASO 4: INTERFAZ GRAFICA MODERNA (WINFORMS) + RUNSPACE
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "UNISTALER - Gestor Seguro de Desinstalacion"
$form.Size = New-Object System.Drawing.Size(980, 640)
$form.MinimumSize = New-Object System.Drawing.Size(820, 500)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 27, 33)
$form.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 248)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

# Panel superior (encabezado + busqueda)
$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlTop.Height = 96
$pnlTop.BackColor = [System.Drawing.Color]::FromArgb(32, 37, 45)
$pnlTop.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 10)
$form.Controls.Add($pnlTop)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "UNISTALER SEGURO"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(99, 179, 237)
$lblTitle.Location = New-Object System.Drawing.Point(16, 10)
$lblTitle.AutoSize = $true
$pnlTop.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = if ($WhatIf) { "MODO SIMULACION ACTIVO - El log en vivo aparece en la consola PowerShell abierta." } else { "Selecciona una o mas aplicaciones. El log de comandos en vivo se muestra en la consola PowerShell." }
$lblSubtitle.ForeColor = if ($WhatIf) { [System.Drawing.Color]::FromArgb(246, 173, 85) } else { [System.Drawing.Color]::FromArgb(160, 174, 192) }
$lblSubtitle.Location = New-Object System.Drawing.Point(18, 35)
$lblSubtitle.Size = New-Object System.Drawing.Size(760, 20)
$pnlTop.Controls.Add($lblSubtitle)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Buscar:"
$lblSearch.Location = New-Object System.Drawing.Point(18, 63)
$lblSearch.Size = New-Object System.Drawing.Size(55, 22)
$pnlTop.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(78, 60)
$txtSearch.Size = New-Object System.Drawing.Size(340, 26)
$txtSearch.BackColor = [System.Drawing.Color]::FromArgb(45, 52, 63)
$txtSearch.ForeColor = [System.Drawing.Color]::White
$txtSearch.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$pnlTop.Controls.Add($txtSearch)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Actualizar lista"
$btnRefresh.Location = New-Object System.Drawing.Point(430, 59)
$btnRefresh.Size = New-Object System.Drawing.Size(125, 28)
$btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnRefresh.ForeColor = [System.Drawing.Color]::White
$pnlTop.Controls.Add($btnRefresh)

$chkCleanLeftovers = New-Object System.Windows.Forms.CheckBox
$chkCleanLeftovers.Text = "Limpiar carpetas y accesos directos residuales"
$chkCleanLeftovers.Checked = $true
$chkCleanLeftovers.Location = New-Object System.Drawing.Point(570, 62)
$chkCleanLeftovers.Size = New-Object System.Drawing.Size(360, 24)
$pnlTop.Controls.Add($chkCleanLeftovers)

# Lista de programas con iconos
$imageList = New-Object System.Windows.Forms.ImageList
$imageList.ImageSize = New-Object System.Drawing.Size(24, 24)
$imageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

$defaultIconBmp = New-Object System.Drawing.Bitmap(24, 24)
$gDef = [System.Drawing.Graphics]::FromImage($defaultIconBmp)
$gDef.Clear([System.Drawing.Color]::FromArgb(74, 85, 104))
$gDef.DrawString("APP", (New-Object System.Drawing.Font("Segoe UI", 6.5, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 2, 7)
$gDef.Dispose()
$imageList.Images.Add("default", $defaultIconBmp) | Out-Null

$listView = New-Object System.Windows.Forms.ListView
$listView.Dock = [System.Windows.Forms.DockStyle]::Fill
$listView.View = [System.Windows.Forms.View]::Details
$listView.FullRowSelect = $true
$listView.CheckBoxes = $true
$listView.GridLines = $false
$listView.SmallImageList = $imageList
$listView.BackColor = [System.Drawing.Color]::FromArgb(24, 27, 33)
$listView.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 248)
$listView.BorderStyle = [System.Windows.Forms.BorderStyle]::None

$colApp = New-Object System.Windows.Forms.ColumnHeader
$colApp.Text = "Aplicacion"
$colApp.Width = 420

$colVer = New-Object System.Windows.Forms.ColumnHeader
$colVer.Text = "Version"
$colVer.Width = 130

$colPub = New-Object System.Windows.Forms.ColumnHeader
$colPub.Text = "Fabricante"
$colPub.Width = 240

$colSrc = New-Object System.Windows.Forms.ColumnHeader
$colSrc.Text = "Origen"
$colSrc.Width = 120

$listView.Columns.AddRange(@($colApp, $colVer, $colPub, $colSrc)) | Out-Null
$form.Controls.Add($listView)

# Panel inferior (acciones + estado)
$pnlBottom = New-Object System.Windows.Forms.Panel
$pnlBottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlBottom.Height = 84
$pnlBottom.BackColor = [System.Drawing.Color]::FromArgb(32, 37, 45)
$pnlBottom.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 10)
$form.Controls.Add($pnlBottom)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Listo."
$lblStatus.Location = New-Object System.Drawing.Point(16, 12)
$lblStatus.Size = New-Object System.Drawing.Size(620, 22)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(160, 174, 192)
$pnlBottom.Controls.Add($lblStatus)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(16, 42)
$progressBar.Size = New-Object System.Drawing.Size(440, 22)
$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$pnlBottom.Controls.Add($progressBar)

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = "Desinstalar seleccionados"
$btnUninstall.Location = New-Object System.Drawing.Point(475, 38)
$btnUninstall.Size = New-Object System.Drawing.Size(180, 30)
$btnUninstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnUninstall.BackColor = [System.Drawing.Color]::FromArgb(229, 62, 62)
$btnUninstall.ForeColor = [System.Drawing.Color]::White
$pnlBottom.Controls.Add($btnUninstall)

$btnForceClean = New-Object System.Windows.Forms.Button
$btnForceClean.Text = "Limpiar restos / Forzar"
$btnForceClean.Location = New-Object System.Drawing.Point(665, 38)
$btnForceClean.Size = New-Object System.Drawing.Size(165, 30)
$btnForceClean.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnForceClean.BackColor = [System.Drawing.Color]::FromArgb(214, 158, 46)
$btnForceClean.ForeColor = [System.Drawing.Color]::Black
$pnlBottom.Controls.Add($btnForceClean)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Salir"
$btnClose.Location = New-Object System.Drawing.Point(840, 38)
$btnClose.Size = New-Object System.Drawing.Size(105, 30)
$btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnClose.ForeColor = [System.Drawing.Color]::White
$pnlBottom.Controls.Add($btnClose)

# Asegurar orden Z correcto con DockStyle.Fill
$listView.BringToFront()

$script:AllApps = @()
$script:IsBusy = $false
$script:ActiveRunspace = $null
$script:ActivePowerShell = $null
$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = 200
$script:AsyncResult = $null
$script:SharedState = [hashtable]::Synchronized(@{
    StatusText    = ""
    ProgressValue = 0
    ProgressMax   = 100
    Completed     = $false
    ErrorText     = $null
})

function Populate-ListView([string]$filterText) {
    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        $q = if ($filterText) { $filterText.Trim().ToLower() } else { "" }

        $filtered = if ($q) {
            @($script:AllApps | Where-Object {
                $_.Name.ToLower().Contains($q) -or
                ($_.Publisher -and $_.Publisher.ToLower().Contains($q)) -or
                ($_.Version -and $_.Version.ToLower().Contains($q))
            })
        }
        else {
            @($script:AllApps)
        }

        foreach ($app in $filtered) {
            $imgKey = "default"
            if ($app.IconPath) {
                $safeKey = $app.IconPath.ToLower()
                if (-not $imageList.Images.ContainsKey($safeKey)) {
                    $bmp = Get-AppIconBitmap $app.IconPath
                    if ($bmp) {
                        $imageList.Images.Add($safeKey, $bmp) | Out-Null
                        $imgKey = $safeKey
                    }
                }
                else {
                    $imgKey = $safeKey
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($app.Name, $imgKey)
            $item.SubItems.Add($(if ($app.Version) { $app.Version } else { "-" })) | Out-Null
            $item.SubItems.Add($(if ($app.Publisher) { $app.Publisher } else { "-" })) | Out-Null
            $item.SubItems.Add($app.Origen) | Out-Null
            $item.Tag = $app
            $listView.Items.Add($item) | Out-Null
        }

        $lblStatus.Text = "Mostrando $($filtered.Count) de $($script:AllApps.Count) aplicaciones instaladas."
    }
    finally {
        $listView.EndUpdate()
    }
}

function Set-UiBusy([bool]$busy) {
    $script:IsBusy = $busy
    $btnUninstall.Enabled = -not $busy
    $btnForceClean.Enabled = -not $busy
    $btnRefresh.Enabled = -not $busy
    $txtSearch.Enabled = -not $busy
    $listView.Enabled = -not $busy
    $chkCleanLeftovers.Enabled = -not $busy
}

function Start-BackgroundJob {
    param(
        [Parameter(Mandatory = $true)][object[]]$SelectedApps,
        [Parameter(Mandatory = $true)][bool]$RunNormalUninstall,
        [Parameter(Mandatory = $true)][bool]$CleanLeftovers
    )

    if ($script:IsBusy) {
        Write-ConsoleLog "Ya hay una operacion en curso. Espera a que termine." 'WARN'
        return
    }

    Set-UiBusy $true
    $progressBar.Value = 0
    $progressBar.Maximum = [Math]::Max(1, $SelectedApps.Count)

    $script:SharedState.StatusText = "Iniciando tarea..."
    $script:SharedState.ProgressValue = 0
    $script:SharedState.ProgressMax = $progressBar.Maximum
    $script:SharedState.Completed = $false
    $script:SharedState.ErrorText = $null

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()

    # Compartir funciones y estado sin crear otra ventana de consola
    $rs.SessionStateProxy.SetVariable('SelectedApps', $SelectedApps)
    $rs.SessionStateProxy.SetVariable('RunNormalUninstall', $RunNormalUninstall)
    $rs.SessionStateProxy.SetVariable('CleanLeftovers', $CleanLeftovers)
    $rs.SessionStateProxy.SetVariable('SharedState', $script:SharedState)
    $rs.SessionStateProxy.SetVariable('LogFile', $LogFile)
    $rs.SessionStateProxy.SetVariable('LogLock', $script:LogLock)
    $rs.SessionStateProxy.SetVariable('WhatIf', $WhatIf)
    $rs.SessionStateProxy.SetVariable('ProtectedExtensions', $script:ProtectedExtensions)

    $workerScript = {
        function Log-Worker([string]$Msg, [string]$Lvl = 'INFO') {
            $ts = Get-Date -Format 'HH:mm:ss'
            $line = "[$ts][$Lvl] $Msg"
            $color = switch ($Lvl) {
                'OK'   { 'Green' }
                'WARN' { 'Yellow' }
                'ERR'  { 'Red' }
                'CMD'  { 'Cyan' }
                'SIM'  { 'Magenta' }
                default { 'Gray' }
            }
            [System.Threading.Monitor]::Enter($LogLock)
            try {
                Write-Host $line -ForegroundColor $color
                Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            finally {
                [System.Threading.Monitor]::Exit($LogLock)
            }
        }

        function Test-ProtectedWorker([string]$p) {
            if ([string]::IsNullOrWhiteSpace($p)) { return $true }
            try { $full = [IO.Path]::GetFullPath($p).TrimEnd('\').ToLower() } catch { return $true }
            if ($full.Length -le 3) { return $true }
            $pf86 = ${env:ProgramFiles(x86)}
            if (-not $pf86) { $pf86 = $env:ProgramFiles }
            $roots = @(
                $env:SystemDrive, $env:windir, $env:ProgramFiles, $pf86,
                $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA,
                (Join-Path $env:SystemDrive 'Users'),
                (Join-Path $env:LOCALAPPDATA 'Programs'),
                (Join-Path $env:LOCALAPPDATA 'Microsoft'),
                (Join-Path $env:APPDATA 'Microsoft'),
                (Join-Path $env:ProgramData 'Microsoft'),
                (Join-Path $env:ProgramFiles 'Common Files'),
                (Join-Path $pf86 'Common Files'),
                (Join-Path $env:ProgramFiles 'WindowsApps'),
                [Environment]::GetFolderPath('MyDocuments'),
                [Environment]::GetFolderPath('Desktop'),
                [Environment]::GetFolderPath('MyPictures'),
                [Environment]::GetFolderPath('MyMusic'),
                [Environment]::GetFolderPath('MyVideos'),
                (Join-Path $env:USERPROFILE 'Downloads'),
                (Join-Path $env:USERPROFILE 'OneDrive')
            ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() } | Sort-Object -Unique

            if ($roots -contains $full) { return $true }
            foreach ($r in $roots) {
                if ($r.Length -gt 3 -and $full.StartsWith($r + '\')) { return $true }
            }
            return $false
        }

        function Get-FolderSizeMBWorker([string]$path) {
            if (-not (Test-Path -LiteralPath $path)) { return 0.0 }
            $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
            if (-not $sum) { return 0.0 }
            return [math]::Round(($sum / 1MB), 1)
        }

        function Get-ExeWorker([string]$s) {
            if (-not $s) { return $null }
            if ($s -match '^\s*"?([A-Za-z]:\\[^"]*?\.(?:exe|ico|dll))') { return $matches[1] }
            return $null
        }

        function Get-TokensWorker([string]$name) {
            $generic = @(
                'microsoft', 'windows', 'google', 'adobe', 'apple', 'intel', 'nvidia', 'amd', 'oracle',
                'update', 'runtime', 'redistributable', 'visual', 'studio', 'driver', 'drivers', 'software',
                'system', 'service', 'services', 'common', 'shared', 'setup', 'install', 'installer', 'program',
                'programs', 'files', 'application', 'apps', 'data', 'tools', 'client', 'server', 'desktop',
                'professional', 'standard', 'enterprise', 'home', 'edition', 'plus', 'premium', 'ultimate',
                'community', 'free', 'language', 'pack'
            )
            if (-not $name) { return @() }
            $clean = $name -replace '\s*\(.*?\)', '' -replace '\s+(x64|x86|64-bit|32-bit|v?\d+(\.\d+)+).*$', ''
            $toks = @(
                $clean -split '\s+' | Where-Object {
                    $_ -match '^[A-Za-z0-9][A-Za-z0-9\-\+\.]*$' -and
                    $_.Length -ge 4 -and
                    $_ -notmatch '^\d+$' -and
                    ($generic -notcontains $_.ToLower())
                } | Select-Object -First 2
            )
            return @($toks | Sort-Object -Unique)
        }

        function Get-PathsWorker($app) {
            $list = New-Object System.Collections.Generic.List[object]
            $seen = @{}
            function Add-Entry([string]$p, [string]$t) {
                if ([string]::IsNullOrWhiteSpace($p)) { return }
                try { $full = [IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return }
                if (-not (Test-Path -LiteralPath $full)) { return }
                $k = $full.ToLower()
                if ($seen.ContainsKey($k)) { return }
                $seen[$k] = $true
                $list.Add([pscustomobject]@{ Path = $full; Tipo = $t; SizeMB = (Get-FolderSizeMBWorker $full) })
            }

            if ($app.InstallLocation) { Add-Entry $app.InstallLocation.Trim('"') 'Instalacion' }
            foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
                $exe = Get-ExeWorker $s
                if ($exe) {
                    $dir = Split-Path $exe -Parent
                    if ($dir -and $dir -notmatch '\\Windows(\\|$)') { Add-Entry $dir 'Ejecutable' }
                }
            }

            $words = @((($app.Name -split '\s+') | Where-Object { $_ -match '^[A-Za-z]{2,}' } | Select-Object -First 2))
            if ($words.Count -gt 0) {
                $pf86 = ${env:ProgramFiles(x86)}
                $roots = @($env:ProgramFiles, $pf86, $env:ProgramData, (Join-Path $env:LOCALAPPDATA 'Programs')) |
                    Where-Object { $_ -and (Test-Path -LiteralPath $_) }
                $pat = '*' + ($words -join ' ') + '*'
                foreach ($r in $roots) {
                    Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like $pat } |
                        ForEach-Object { Add-Entry $_.FullName 'Programa' }
                }
            }

            $tokens = Get-TokensWorker $app.Name
            if ($tokens.Count -gt 0) {
                $dataRoots = @(
                    @{ Root = $env:APPDATA; Kind = 'APPDATA' },
                    @{ Root = $env:LOCALAPPDATA; Kind = 'LOCALAPPDATA' },
                    @{ Root = (Join-Path $env:LOCALAPPDATA 'Programs'); Kind = 'LOCALAPPDATA\Programs' },
                    @{ Root = $env:ProgramData; Kind = 'ProgramData' }
                ) | Where-Object { $_.Root -and (Test-Path -LiteralPath $_.Root) }
                foreach ($r in $dataRoots) {
                    foreach ($t in $tokens) {
                        Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -like "*$t*" } |
                            ForEach-Object {
                                if (-not (Test-ProtectedWorker $_.FullName)) { Add-Entry $_.FullName $r.Kind }
                            }
                    }
                }
            }
            return @($list)
        }

        function Get-ShortcutsWorker($app) {
            $list = New-Object System.Collections.Generic.List[object]
            $seen = @{}
            $tokens = Get-TokensWorker $app.Name
            if ($tokens.Count -eq 0) { return @() }
            $roots = @(
                [Environment]::GetFolderPath('CommonDesktopDirectory'),
                [Environment]::GetFolderPath('Desktop'),
                (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

            foreach ($r in $roots) {
                foreach ($t in $tokens) {
                    Get-ChildItem -LiteralPath $r -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*$t*" } |
                        ForEach-Object {
                            $k = $_.FullName.ToLower()
                            if (-not $seen.ContainsKey($k)) {
                                $seen[$k] = $true
                                $list.Add([pscustomobject]@{ Path = $_.FullName; Tipo = 'Acceso directo' })
                            }
                        }
                }
            }
            return @($list)
        }

        try {
            $idx = 0
            foreach ($app in $SelectedApps) {
                $idx++
                $SharedState.StatusText = "Procesando ($idx/$($SelectedApps.Count)): $($app.Name)"
                $SharedState.ProgressValue = $idx - 1

                Log-Worker "============================================================" 'INFO'
                Log-Worker "Aplicacion [$idx/$($SelectedApps.Count)]: $($app.Name) (v$($app.Version))" 'INFO'

                if ($RunNormalUninstall) {
                    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
                    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')
                    $exe = $null; $argLine = $null

                    if ($isMsi) {
                        $exe = 'msiexec.exe'
                        $argLine = "/x $($app.Key) /qn /norestart"
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($app.QuietUninstallString)) {
                        $exe = 'cmd.exe'
                        $argLine = "/c $($app.QuietUninstallString)"
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($app.UninstallString)) {
                        $exe = 'cmd.exe'
                        $argLine = "/c $($app.UninstallString)"
                    }

                    if ($exe) {
                        Log-Worker "Comando de desinstalacion: $exe $argLine" 'CMD'
                        if ($WhatIf) {
                            Log-Worker "[WhatIf] Se ejecutaria: $exe $argLine" 'SIM'
                        }
                        else {
                            $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
                            if (-not $proc.WaitForExit(900000)) {
                                Log-Worker "Tiempo agotado desinstalando '$($app.Name)'. Matando PID $($proc.Id)." 'ERR'
                                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            }
                            else {
                                $lvl = if ($proc.ExitCode -eq 0) { 'OK' } else { 'WARN' }
                                Log-Worker "Salida del desinstalador para '$($app.Name)': ExitCode=$($proc.ExitCode)" $lvl
                            }
                        }
                    }
                    else {
                        Log-Worker "Sin desinstalador registrado para '$($app.Name)'." 'WARN'
                    }
                }

                if ($CleanLeftovers) {
                    Log-Worker "Buscando carpetas y accesos directos de '$($app.Name)'..." 'INFO'
                    $paths = @(Get-PathsWorker $app)
                    $shcuts = @(Get-ShortcutsWorker $app)

                    foreach ($p in $paths) {
                        if (Test-ProtectedWorker $p.Path) {
                            Log-Worker "Ruta protegida omitida: $($p.Path)" 'WARN'
                            continue
                        }
                        $hasUserFiles = $false
                        $uFile = Get-ChildItem -LiteralPath $p.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                            Where-Object { $ProtectedExtensions -contains $_.Extension.ToLower() } |
                            Select-Object -First 1
                        if ($uFile) { $hasUserFiles = $true }

                        if ($hasUserFiles) {
                            Log-Worker "Carpeta con archivos de usuario omitida por seguridad: $($p.Path)" 'WARN'
                            continue
                        }

                        if ($WhatIf) {
                            Log-Worker "[WhatIf] Borraria carpeta [$($p.Tipo)] $($p.Path) ($($p.SizeMB) MB)" 'SIM'
                        }
                        else {
                            $prefix = $p.Path.TrimEnd('\') + '\'
                            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                                Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
                                ForEach-Object {
                                    Log-Worker "Cerrando proceso bloqueador: $($_.Name) (PID $($_.ProcessId))" 'WARN'
                                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                                }

                            Remove-Item -LiteralPath $p.Path -Recurse -Force -ErrorAction SilentlyContinue
                            if (Test-Path -LiteralPath $p.Path) {
                                & icacls.exe $p.Path /setowner "*S-1-5-32-544" /t /c /q 2>&1 | Out-Null
                                & icacls.exe $p.Path /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
                                Remove-Item -LiteralPath $p.Path -Recurse -Force -ErrorAction SilentlyContinue
                            }

                            if (Test-Path -LiteralPath $p.Path) {
                                Log-Worker "No se pudo eliminar carpeta: $($p.Path)" 'ERR'
                            }
                            else {
                                Log-Worker "Carpeta eliminada [$($p.Tipo)]: $($p.Path) ($($p.SizeMB) MB)" 'OK'
                            }
                        }
                    }

                    foreach ($s in $shcuts) {
                        $ext = [IO.Path]::GetExtension($s.Path).ToLower()
                        if ($ProtectedExtensions -contains $ext) {
                            Log-Worker "Acceso directo/archivo protegido omitido: $($s.Path)" 'WARN'
                            continue
                        }
                        if ($WhatIf) {
                            Log-Worker "[WhatIf] Borraria acceso directo: $($s.Path)" 'SIM'
                        }
                        else {
                            Remove-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue
                            if (Test-Path -LiteralPath $s.Path) {
                                Log-Worker "No se pudo eliminar acceso directo: $($s.Path)" 'ERR'
                            }
                            else {
                                Log-Worker "Acceso directo eliminado: $($s.Path)" 'OK'
                            }
                        }
                    }
                }

                $stillRegistered = Test-Path -LiteralPath $app.PSPath
                if ($stillRegistered) {
                    Log-Worker "Nota: '$($app.Name)' aun figura en el registro de desinstalacion." 'WARN'
                }
                else {
                    Log-Worker "Entrada de registro ya no existe para '$($app.Name)'." 'OK'
                }

                $SharedState.ProgressValue = $idx
            }

            $SharedState.StatusText = "Proceso finalizado."
            Log-Worker "============================================================" 'OK'
            Log-Worker "Todas las tareas seleccionadas finalizaron." 'OK'
        }
        catch {
            $SharedState.ErrorText = $_.Exception.Message
            Log-Worker "Error critico en trabajador: $($_.Exception.Message)" 'ERR'
        }
        finally {
            $SharedState.Completed = $true
        }
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($workerScript)

    $script:ActiveRunspace = $rs
    $script:ActivePowerShell = $ps
    $script:AsyncResult = $ps.BeginInvoke()
    $script:PollTimer.Start()
}

$script:PollTimer.Add_Tick({
    $lblStatus.Text = $script:SharedState.StatusText
    $val = [Math]::Min($progressBar.Maximum, [Math]::Max($progressBar.Minimum, [int]$script:SharedState.ProgressValue))
    $progressBar.Value = $val

    if ($script:SharedState.Completed) {
        $script:PollTimer.Stop()
        try {
            if ($script:ActivePowerShell -and $script:AsyncResult) {
                [void]$script:ActivePowerShell.EndInvoke($script:AsyncResult)
            }
        }
        catch {}
        try { if ($script:ActivePowerShell) { $script:ActivePowerShell.Dispose() } } catch {}
        try { if ($script:ActiveRunspace) { $script:ActiveRunspace.Close(); $script:ActiveRunspace.Dispose() } } catch {}

        $script:ActivePowerShell = $null
        $script:ActiveRunspace = $null
        $script:AsyncResult = $null

        $script:AllApps = Get-InstalledApps
        Populate-ListView $txtSearch.Text
        $progressBar.Value = $progressBar.Maximum
        Set-UiBusy $false
        $lblStatus.Text = "Completado. Revisa la consola para ver el detalle y errores."
    }
})

function Get-CheckedApps {
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($item in $listView.CheckedItems) {
        if ($item.Tag) { $selected.Add($item.Tag) }
    }
    if ($selected.Count -eq 0 -and $listView.SelectedItems.Count -gt 0) {
        foreach ($item in $listView.SelectedItems) {
            if ($item.Tag) { $selected.Add($item.Tag) }
        }
    }
    return @($selected)
}

$txtSearch.Add_TextChanged({
    Populate-ListView $txtSearch.Text
})

$btnRefresh.Add_Click({
    if ($script:IsBusy) { return }
    Write-ConsoleLog "Actualizando lista de programas instalados..." 'INFO'
    $script:AllApps = Get-InstalledApps
    Populate-ListView $txtSearch.Text
})

$btnUninstall.Add_Click({
    $apps = Get-CheckedApps
    if ($apps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Marca al menos una aplicacion en la casilla o seleccionala.", "Sin seleccion", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $msg = "Se desinstalaran $($apps.Count) aplicacion(es). El progreso y los comandos apareceran en la consola abierta.`n`nDeseas continuar?"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, "Confirmar desinstalacion", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-BackgroundJob -SelectedApps $apps -RunNormalUninstall $true -CleanLeftovers $chkCleanLeftovers.Checked
    }
})

$btnForceClean.Add_Click({
    $apps = Get-CheckedApps
    if ($apps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Marca al menos una aplicacion en la casilla o seleccionala.", "Sin seleccion", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $msg = "Se ejecutara limpieza de carpetas y accesos directos (sin lanzar desinstalador normal) para $($apps.Count) aplicacion(es).`nLas rutas protegidas y archivos de usuario se mantienen a salvo.`n`nDeseas continuar?"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, "Confirmar limpieza de restos", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-BackgroundJob -SelectedApps $apps -RunNormalUninstall $false -CleanLeftovers $chkCleanLeftovers.Checked
    }
})

$btnClose.Add_Click({
    $form.Close()
})

$form.Add_FormClosing({
    if ($script:IsBusy) {
        $ans = [System.Windows.Forms.MessageBox]::Show("Hay una tarea en ejecucion. Si cierras ahora, podria quedar un proceso en segundo plano. Cerrar de todos modos?", "Tarea activa", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
    }
    $script:PollTimer.Stop()
})

# Carga inicial
Write-ConsoleLog "Cargando aplicaciones instaladas..." 'INFO'
$script:AllApps = Get-InstalledApps
Populate-ListView ""
Write-ConsoleLog "Aplicaciones cargadas: $($script:AllApps.Count). Interfaz lista." 'OK'

[void]$form.ShowDialog()
$script:PollTimer.Dispose()
Write-ConsoleLog "Ventana UI cerrada. Log final guardado en: $LogFile" 'INFO'