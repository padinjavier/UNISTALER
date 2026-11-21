<#
  UNISTALER GUI - Desinstalador Seguro con Interfaz (WPF) + Consola de Log.
  (Archivo solo ASCII a proposito: evita problemas de codificacion con irm | iex.)

  Ejecutar:
    irm https://raw.githubusercontent.com/padinjavier/UNISTALER/main/UNISTALER-GUI.ps1 | iex

  Funcionamiento:
    1) Se abre UNA consola nueva como Administrador (esa es la consola de LOG).
    2) Desde esa consola se abre la ventana (UI).
    3) Al pulsar "Desinstalar", el trabajo corre en un hilo aparte (la UI no se congela)
       y TODOS los mensajes salen en la misma consola de log. No se abre nada nuevo.

  PROTECCIONES:
    - NUNCA toca Documentos, Escritorio, Descargas, Imagenes, Videos, Musica, OneDrive.
    - No borra carpetas con documentos de usuario (.docx, .pdf, .xlsx, .mp3, ...) salvo "Forzar".
    - NUNCA toca firewall, servicios, tareas programadas ni variables de entorno.
    - Del registro solo toca la entrada de desinstalacion (y solo en modo "Forzar", con backup .reg).
#>

$ErrorActionPreference = 'Continue'
$ScriptUrl = 'https://raw.githubusercontent.com/padinjavier/UNISTALER/main/UNISTALER-GUI.ps1'

# ============================================================
#  1) RELANZAR: consola nueva, Administrador y STA (necesario para WPF)
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA)

if (-not $isAdmin -or -not $isSta) {
    Write-Host "Abriendo la consola de UNISTALER (Administrador)..." -ForegroundColor Yellow
    try {
        $self = $PSCommandPath
        if (-not $self -or -not (Test-Path -LiteralPath $self)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $self = Join-Path $env:TEMP 'UNISTALER-GUI.ps1'
            Invoke-WebRequest -Uri ($ScriptUrl + '?t=' + [DateTime]::Now.Ticks) -OutFile $self -UseBasicParsing
        }
        $sp = @{
            FilePath     = 'powershell.exe'
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $self))
        }
        if (-not $isAdmin) { $sp.Verb = 'RunAs' }
        Start-Process @sp
    }
    catch {
        Write-Host "No se pudo relanzar: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

# ------------------------------------------------------------
#  A partir de aqui: esta ES la consola de log (Admin + STA)
# ------------------------------------------------------------
try { $Host.UI.RawUI.WindowTitle = 'UNISTALER - Consola de LOG (no cerrar mientras uses la ventana)' } catch {}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

$script:LogFile = Join-Path $env:TEMP ("UNISTALER_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$global:Q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

# ============================================================
#  2) LIBRERIA (se usa en la UI y se inyecta tal cual al hilo de trabajo)
# ============================================================
$WorkerLib = @'
function Write-Q([string]$lvl, [string]$msg) {
    if ($global:Q) { $global:Q.Enqueue(('{0}|{1}' -f $lvl, $msg)) }
}

# Extensiones de documentos/medios que se consideran "archivos de usuario"
$global:UnistDocExt = @(
    '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.rtf', '.odt', '.ods', '.odp',
    '.psd', '.ai', '.indd', '.cdr',
    '.mp3', '.wav', '.flac', '.aac', '.m4a', '.wma',
    '.mp4', '.avi', '.mkv', '.mov', '.wmv', '.webm',
    '.heic', '.raw', '.eml', '.msg', '.pst', '.ost',
    '.mdb', '.accdb', '.epub', '.mobi', '.azw', '.azw3'
)

function Get-ExeFromString([string]$s) {
    if (-not $s) { return $null }
    if ($s -match '^\s*"?([A-Za-z]:\\[^"]*?\.(?:exe|ico|dll))') { return $matches[1] }
    return $null
}

function Get-CleanName([string]$name) {
    if (-not $name) { return '' }
    $clean = $name -replace '\s*\(.*?\)', '' -replace '\s+(x64|x86|64-bit|32-bit|v?\d+(\.\d+)+).*$', ''
    return $clean.Trim()
}

function Get-NameTokens([string]$name) {
    $generic = @('microsoft', 'windows', 'google', 'adobe', 'apple', 'intel', 'nvidia', 'amd', 'oracle',
        'update', 'runtime', 'redistributable', 'visual', 'studio', 'driver', 'drivers', 'software',
        'system', 'service', 'services', 'common', 'shared', 'setup', 'install', 'installer', 'program',
        'programs', 'files', 'application', 'apps', 'data', 'tools', 'client', 'server', 'desktop',
        'professional', 'standard', 'enterprise', 'home', 'edition', 'plus', 'premium', 'ultimate',
        'community', 'free', 'language', 'pack')
    $tokens = @()
    $clean = Get-CleanName $name
    if ($clean) {
        $tokens = @($clean -split '\s+' | Where-Object {
                $_ -match '^[A-Za-z0-9][A-Za-z0-9\-\+\.]*$' -and
                $_.Length -ge 4 -and
                $_ -notmatch '^\d+$' -and
                ($generic -notcontains $_.ToLower())
            } | Select-Object -First 2)
    }
    @($tokens | Sort-Object -Unique)
}

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

            # Icono: DisplayIcon -> primer exe de la carpeta de instalacion
            $ip = $null
            if ($p.DisplayIcon) {
                $di = [Environment]::ExpandEnvironmentVariables([string]$p.DisplayIcon).Trim()
                if ($di -match '^"([^"]+)"') { $ip = $matches[1] }
                elseif ($di -match '^(.+?)(,\s*-?\d+)?$') { $ip = $matches[1] }
            }
            if ($ip -and -not (Test-Path -LiteralPath $ip -ErrorAction SilentlyContinue)) { $ip = $null }
            if (-not $ip -and $p.InstallLocation) {
                $loc = ([string]$p.InstallLocation).Trim('"')
                if ($loc -and (Test-Path -LiteralPath $loc -ErrorAction SilentlyContinue)) {
                    $exeF = Get-ChildItem -LiteralPath $loc -Filter '*.exe' -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notmatch '^unins' } | Select-Object -First 1
                    if ($exeF) { $ip = $exeF.FullName }
                }
            }

            [pscustomobject]@{
                Name                 = [string]$p.DisplayName
                Version              = [string]$p.DisplayVersion
                Publisher            = [string]$p.Publisher
                InstallLocation      = [string]$p.InstallLocation
                DisplayIcon          = [string]$p.DisplayIcon
                IconPath             = $ip
                UninstallString      = [string]$p.UninstallString
                QuietUninstallString = [string]$p.QuietUninstallString
                WindowsInstaller     = $p.WindowsInstaller
                Key                  = $item.PSChildName
                PSPath               = $item.PSPath
                Origen               = $k.Origen
            }
        }
    }
    @($apps | Sort-Object Name)
}

# ---------------- Proteccion ----------------
function Get-ProtectedUserFolders {
    @(
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
}

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

    foreach ($uf in @(Get-ProtectedUserFolders)) {
        if ($full -eq $uf) { return $true }
        if ($full -like ($uf + '\*')) { return $true }
    }
    return $false
}

function Get-UserFilesIn([string]$folder, [int]$max = 5) {
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $global:UnistDocExt -contains $_.Extension.ToLower() } |
        Select-Object -First $max)
}

# ---------------- Busqueda de restos ----------------
function Get-AppAssociatedPaths($app) {
    $result = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $add = {
        param($p, $t)
        if (-not $p) { return }
        $p = ([string]$p).Trim('"').TrimEnd('\')
        if (-not $p) { return }
        $key = $p.ToLower()
        if ($seen.ContainsKey($key)) { return }
        if (-not (Test-Path -LiteralPath $p)) { return }
        if (Test-ProtectedPath $p) { return }
        $seen[$key] = $true
        $result.Add([pscustomobject]@{ Path = $p; Tipo = $t })
    }

    # 1) Ruta registrada
    & $add $app.InstallLocation 'Instalacion'

    # 2) Carpetas derivadas del ejecutable
    foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)') { & $add $dir 'Ejecutable' }
        }
    }

    # 3) Program Files / ProgramData por nombre
    $clean = Get-CleanName $app.Name
    if ($clean.Length -ge 4) {
        $pf86 = ${env:ProgramFiles(x86)}
        $roots = @($env:ProgramFiles, $pf86, $env:ProgramData, (Join-Path $env:LOCALAPPDATA 'Programs')) |
            Where-Object { $_ -and (Test-Path $_) }
        $pattern = '*' + $clean + '*'
        foreach ($r in $roots) {
            foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
                if ($d.Name -like $pattern) { & $add $d.FullName 'Programa' }
            }
        }
    }

    # 4) Datos de usuario (APPDATA / LOCALAPPDATA / ProgramData)
    $tokens = @(Get-NameTokens $app.Name)
    if ($tokens.Count -gt 0 -or $clean.Length -ge 4) {
        $dataRoots = @(
            @{ Root = $env:APPDATA; Kind = 'APPDATA' },
            @{ Root = $env:LOCALAPPDATA; Kind = 'LOCALAPPDATA' },
            @{ Root = (Join-Path $env:LOCALAPPDATA 'Programs'); Kind = 'LOCALAPPDATA\Programs' },
            @{ Root = (Join-Path $env:USERPROFILE 'AppData\LocalLow'); Kind = 'LocalLow' },
            @{ Root = $env:ProgramData; Kind = 'ProgramData' }
        ) | Where-Object { $_.Root -and (Test-Path $_.Root) }

        foreach ($r in $dataRoots) {
            foreach ($d in @(Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue)) {
                $hit = $false
                if ($clean.Length -ge 4 -and $d.Name -like ('*' + $clean + '*')) { $hit = $true }
                foreach ($tok in $tokens) { if ($d.Name -like ($tok + '*')) { $hit = $true } }
                if ($hit) { & $add $d.FullName $r.Kind }
            }
        }
    }
    @($result)
}

function Get-Shortcuts($app) {
    $found = New-Object System.Collections.Generic.List[string]
    $tokens = @(Get-NameTokens $app.Name)
    $clean = Get-CleanName $app.Name
    if ($tokens.Count -eq 0 -and $clean.Length -lt 4) { return @() }
    $roots = @(
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue)) {
            $hit = $false
            if ($clean.Length -ge 4 -and $f.Name -like ('*' + $clean + '*')) { $hit = $true }
            foreach ($tok in $tokens) { if ($f.Name -like ('*' + $tok + '*')) { $hit = $true } }
            if ($hit -and -not $found.Contains($f.FullName)) { $found.Add($f.FullName) }
        }
    }
    @($found)
}

# ---------------- Borrado ----------------
function Stop-ProcessesInFolder([string]$folder) {
    $prefix = $folder.TrimEnd('\') + '\'
    foreach ($pr in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })) {
        if ($pr.ProcessId -eq $PID) { continue }
        Write-Q 'INFO' "   Cerrando proceso: $($pr.Name) (PID $($pr.ProcessId))"
        Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Remove-FolderSafe([string]$folder, [bool]$simulate, [bool]$force) {
    if (-not (Test-Path -LiteralPath $folder)) { return 'GONE' }
    if (Test-ProtectedPath $folder) {
        Write-Q 'WARN' "   Ruta protegida, se omite: $folder"
        return 'SKIP'
    }
    $uf = @(Get-UserFilesIn $folder 5)
    if ($uf.Count -gt 0 -and -not $force) {
        Write-Q 'WARN' "   Contiene documentos de usuario, se omite: $folder"
        foreach ($f in $uf) { Write-Q 'WARN' "        - $($f.FullName)" }
        Write-Q 'WARN' '        (marca "Forzar" si quieres borrarla igual)'
        return 'SKIP'
    }
    if ($simulate) { Write-Q 'SIM' "   Se borraria carpeta: $folder"; return 'SIM' }

    Stop-ProcessesInFolder $folder
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $folder) {
        & icacls.exe $folder /setowner "*S-1-5-32-544" /t /c /q 2>&1 | Out-Null
        & icacls.exe $folder /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $folder) {
        Write-Q 'ERR' "   No se pudo borrar todo (archivos en uso?): $folder"
        return 'FAIL'
    }
    Write-Q 'OK' "   Eliminada: $folder"
    return 'OK'
}

function Remove-FileSafe([string]$file, [bool]$simulate) {
    if (-not (Test-Path -LiteralPath $file)) { return 'GONE' }
    if ($simulate) { Write-Q 'SIM' "   Se borraria acceso directo: $file"; return 'SIM' }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $file) {
        & icacls.exe $file /setowner "*S-1-5-32-544" /c /q 2>&1 | Out-Null
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $file) { Write-Q 'ERR' "   No se pudo borrar: $file"; return 'FAIL' }
    Write-Q 'OK' "   Eliminado: $file"
    return 'OK'
}

function Remove-UninstallEntry($app, [bool]$simulate) {
    if ($simulate) { Write-Q 'SIM' "   Se borraria la entrada de registro: $($app.PSPath)"; return 'SIM' }
    try {
        $safeName = ($app.Key -replace '[\\/:*?"<>|]', '_')
        $backup = Join-Path $env:TEMP ("RegBackup_{0}_{1}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $safeName)
        $native = $app.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
        & reg.exe export $native $backup /y 2>&1 | Out-Null
        Remove-Item -LiteralPath $app.PSPath -Recurse -Force -ErrorAction Stop
        Write-Q 'OK' "   Entrada de desinstalacion eliminada (backup: $backup)"
        return 'OK'
    }
    catch {
        Write-Q 'ERR' "   No se pudo borrar la entrada de registro: $($_.Exception.Message)"
        return 'FAIL'
    }
}

# ---------------- Desinstalador oficial ----------------
function Invoke-NormalUninstall($app, [bool]$simulate, [int]$timeoutMin = 15) {
    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')
    $hidden = $true
    $exe = $null; $argLine = $null; $method = ''

    if ($isMsi) {
        $exe = 'msiexec.exe'; $argLine = "/x $($app.Key) /qn /norestart"; $method = 'MSI silencioso'
    }
    elseif ($app.QuietUninstallString) {
        $exe = 'cmd.exe'; $argLine = ('/s /c "{0}"' -f $app.QuietUninstallString); $method = 'QuietUninstallString'
    }
    elseif ($app.UninstallString) {
        $us = $app.UninstallString
        if ($us -match 'unins\d{3}\.exe') {
            $us += ' /VERYSILENT /NORESTART /SUPPRESSMSGBOXES'; $method = 'Inno Setup silencioso'
        }
        else {
            $hidden = $false; $method = 'UninstallString (puede abrir una ventana: confirmala si aparece)'
        }
        $exe = 'cmd.exe'; $argLine = ('/s /c "{0}"' -f $us)
    }
    else {
        Write-Q 'WARN' '   Este programa no tiene desinstalador registrado.'
        return $null
    }

    Write-Q 'INFO' "   Metodo: $method"
    if ($simulate) { Write-Q 'SIM' "   Se ejecutaria: $exe $argLine"; return 0 }

    try {
        $ws = 'Normal'; if ($hidden) { $ws = 'Hidden' }
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle $ws
        $null = $proc.Handle
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastBeat = 0
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            if (($sw.Elapsed.TotalSeconds - $lastBeat) -ge 30) {
                $lastBeat = $sw.Elapsed.TotalSeconds
                Write-Q 'INFO' ("   ...desinstalador en ejecucion ({0}s)" -f [int]$sw.Elapsed.TotalSeconds)
            }
            if ($sw.Elapsed.TotalMinutes -ge $timeoutMin) {
                Write-Q 'ERR' "   Tiempo agotado ($timeoutMin min). Se cancela el desinstalador."
                & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
                return -1
            }
        }
        $proc.WaitForExit()
        Write-Q 'INFO' "   Codigo de salida del desinstalador: $($proc.ExitCode)"
        return [int]$proc.ExitCode
    }
    catch {
        Write-Q 'ERR' "   Error al ejecutar el desinstalador: $($_.Exception.Message)"
        return -1
    }
}

# ---------------- Flujo por programa ----------------
function Invoke-AppRemoval($app, $o) {
    $sim = [bool]$o.Simulate
    $force = [bool]$o.Force
    $clean = [bool]$o.Clean

    Write-Q 'STEP' ">>> $($app.Name) $($app.Version)"
    if ($sim) { Write-Q 'SIM' 'MODO SIMULACION: no se borra nada.' }

    # Rutas ANTES de desinstalar (despues el registro ya no ayuda)
    Write-Q 'INFO' 'Buscando rutas asociadas...'
    $paths = @(Get-AppAssociatedPaths $app)
    $links = @(Get-Shortcuts $app)
    foreach ($p in $paths) { Write-Q 'INFO' ("   [{0}] {1}" -f $p.Tipo, $p.Path) }
    foreach ($l in $links) { Write-Q 'INFO' "   [Acceso directo] $l" }
    if ($paths.Count -eq 0 -and $links.Count -eq 0) { Write-Q 'INFO' '   (sin rutas asociadas encontradas)' }

    # Cerrar procesos de la app para que el desinstalador no falle
    if (-not $sim) {
        foreach ($p in $paths) {
            if ($p.Tipo -eq 'Instalacion' -or $p.Tipo -eq 'Ejecutable' -or $p.Tipo -eq 'Programa') {
                Stop-ProcessesInFolder $p.Path
            }
        }
    }

    Write-Q 'INFO' 'Ejecutando desinstalador oficial...'
    $code = Invoke-NormalUninstall $app $sim

    # Verificar de verdad si la entrada desaparecio (algunos desinstaladores terminan y siguen en 2do plano)
    $registered = $false
    if (-not $sim -and $null -ne $code) {
        $waitSec = 8
        if ($code -eq 0 -or $code -eq 3010) { $waitSec = 60 }
        $t = 0
        while ($t -lt $waitSec) {
            if (-not (Test-Path -LiteralPath $app.PSPath)) { break }
            Start-Sleep -Seconds 2; $t += 2
        }
        $registered = [bool](Test-Path -LiteralPath $app.PSPath)
    }
    elseif (-not $sim -and $null -eq $code) {
        $registered = [bool](Test-Path -LiteralPath $app.PSPath)
    }

    $forcedMode = $false
    if ($registered) {
        Write-Q 'ERR' "El programa SIGUE registrado como instalado (codigo: $code)."
        if (-not $force) {
            Write-Q 'WARN' 'No se borro nada mas. Marca "Forzar" y reintenta si quieres limpieza a la fuerza.'
            return 'FAIL'
        }
        Write-Q 'WARN' 'Modo FORZAR: se eliminan carpetas, accesos y la entrada de desinstalacion.'
        $forcedMode = $true
    }
    elseif (-not $sim) {
        if ($code -eq 3010) { Write-Q 'WARN' 'Desinstalado, pero Windows pide reiniciar para terminar.' }
        Write-Q 'OK' 'Desinstalador oficial completado: la entrada ya no esta en la lista.'
    }

    $fail = 0; $skip = 0
    if ($clean -or $forcedMode) {
        Write-Q 'INFO' 'Limpiando restos...'
        foreach ($p in $paths) {
            $r = Remove-FolderSafe $p.Path $sim $force
            if ($r -eq 'FAIL') { $fail++ } elseif ($r -eq 'SKIP') { $skip++ }
        }
        foreach ($l in $links) {
            $r = Remove-FileSafe $l $sim
            if ($r -eq 'FAIL') { $fail++ }
        }
        if ($forcedMode) {
            $r = Remove-UninstallEntry $app $sim
            if ($r -eq 'FAIL') { $fail++ }
        }
    }
    else {
        Write-Q 'INFO' 'Limpieza de restos desactivada (solo se uso el desinstalador oficial).'
    }

    if ($fail -gt 0 -or $skip -gt 0) {
        Write-Q 'WARN' "Terminado con avisos: $($app.Name) (fallos: $fail, omitidos: $skip)"
        return 'PARTIAL'
    }
    Write-Q 'OK' "Terminado: $($app.Name)"
    return 'OK'
}

function Invoke-Batch {
    $apps = @($global:Apps)
    $o = $global:Opts
    $ok = 0; $part = 0; $fail = 0; $i = 0
    foreach ($app in $apps) {
        $i++
        Write-Q 'PROG' "$i|$($apps.Count)"
        $r = 'FAIL'
        try { $r = @(Invoke-AppRemoval $app $o)[-1] }
        catch { Write-Q 'ERR' "Error inesperado: $($_.Exception.Message)" }
        switch ($r) {
            'OK' { $ok++ }
            'PARTIAL' { $part++ }
            default { $fail++ }
        }
    }
    Write-Q 'DONE' "$ok|$part|$fail"
}
'@

Invoke-Expression $WorkerLib

# ============================================================
#  3) CLASE PARA LA LISTA (notifica cambios del checkbox)
# ============================================================
if (-not ('AppItem' -as [type])) {
    Add-Type -ReferencedAssemblies 'PresentationCore', 'WindowsBase' -TypeDefinition @'
using System.ComponentModel;
public class AppItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    public string Name { get; set; }
    public string Version { get; set; }
    public string Publisher { get; set; }
    public string InstallLocation { get; set; }
    public System.Windows.Media.ImageSource IconImage { get; set; }
    public object Raw { get; set; }
    private bool _isChecked;
    public bool IsChecked {
        get { return _isChecked; }
        set {
            _isChecked = value;
            if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs("IsChecked"));
        }
    }
}
'@
}

# ============================================================
#  4) INTERFAZ
# ============================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UNISTALER - Desinstalador Seguro" Height="760" Width="1020" MinHeight="520" MinWidth="760"
        WindowStartupLocation="CenterScreen" Background="#1B1B1F" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#3A3A42"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#26262B"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="CaretBrush" Value="White"/>
            <Setter Property="BorderBrush" Value="#3A3A42"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#DDDDDD"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#232328" Padding="22,16">
            <StackPanel>
                <TextBlock Text="UNISTALER" FontSize="26" FontWeight="Bold" Foreground="White"/>
                <TextBlock Text="Desinstala y limpia restos. El log completo sale en la consola de PowerShell que esta detras."
                           Foreground="#9A9AA5" Margin="0,4,0,0"/>
            </StackPanel>
        </Border>

        <Border Grid.Row="1" Background="#232328" Padding="14,0,14,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid Grid.Column="0" Margin="0,0,10,0">
                    <TextBox x:Name="SearchBox" Height="36" FontSize="14"/>
                    <TextBlock x:Name="SearchHint" Text="Buscar programa o editor..." Foreground="#6E6E78" FontSize="14"
                               IsHitTestVisible="False" VerticalAlignment="Center" Margin="12,0,0,0"/>
                </Grid>
                <Button x:Name="BtnClear" Grid.Column="1" Content="Desmarcar todo" Height="36" Margin="0,0,8,0"/>
                <Button x:Name="BtnRefresh" Grid.Column="2" Content="Refrescar" Height="36" Width="100"/>
            </Grid>
        </Border>

        <ListBox x:Name="AppsList" Grid.Row="2" Background="Transparent" BorderThickness="0" Margin="12,8,12,4"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.ItemContainerStyle>
                <Style TargetType="ListBoxItem">
                    <Setter Property="Focusable" Value="False"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ListBoxItem">
                                <ContentPresenter/>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
                <DataTemplate>
                    <Border Background="#26262B" CornerRadius="8" Margin="0,3">
                        <CheckBox IsChecked="{Binding IsChecked, Mode=TwoWay}" Padding="10,9"
                                  HorizontalContentAlignment="Stretch" VerticalContentAlignment="Center" Margin="10,0,0,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <Image Grid.Column="0" Source="{Binding IconImage}" Width="34" Height="34" Margin="0,0,14,0"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                    <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="White" FontSize="14" TextTrimming="CharacterEllipsis"/>
                                    <TextBlock Text="{Binding Publisher}" Foreground="#9A9AA5" FontSize="12" TextTrimming="CharacterEllipsis"/>
                                    <TextBlock Text="{Binding Version}" Foreground="#6E6E78" FontSize="11"/>
                                </StackPanel>
                                <TextBlock Grid.Column="2" Text="{Binding InstallLocation}" Foreground="#5E5E68" FontSize="10"
                                           VerticalAlignment="Center" MaxWidth="300" TextTrimming="CharacterEllipsis" Margin="12,0,6,0"/>
                            </Grid>
                        </CheckBox>
                    </Border>
                </DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>

        <Border Grid.Row="3" Background="#232328" Padding="16,10">
            <WrapPanel>
                <CheckBox x:Name="ChkClean" IsChecked="True" Margin="0,0,24,0" VerticalAlignment="Center"
                          Content="Borrar restos (carpetas y accesos directos)"
                          ToolTip="Despues del desinstalador oficial, borra carpetas de instalacion, datos en AppData/ProgramData y accesos directos."/>
                <CheckBox x:Name="ChkForce" IsChecked="False" Margin="0,0,24,0" VerticalAlignment="Center"
                          Content="Forzar (si el desinstalador falla o hay documentos)"
                          ToolTip="Si el desinstalador falla, borra a la fuerza y quita la entrada de desinstalacion (con backup .reg). Tambien borra carpetas con documentos dentro."/>
                <CheckBox x:Name="ChkSim" IsChecked="False" VerticalAlignment="Center"
                          Content="Simulacion (no borra nada)"
                          ToolTip="Solo muestra en la consola que haria."/>
            </WrapPanel>
        </Border>

        <Border Grid.Row="4" Background="#1F1F24" Padding="16,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock x:Name="StatusText" Grid.Row="0" Grid.Column="0" Foreground="#B5B5C0" VerticalAlignment="Center" Text="Listo." TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="CountText" Grid.Row="0" Grid.Column="1" Foreground="#9A9AA5" VerticalAlignment="Center" Margin="12,0,16,0" Text="0 seleccionadas"/>
                <Button x:Name="BtnUninstall" Grid.Row="0" Grid.Column="2" Grid.RowSpan="2" Content="Desinstalar seleccionadas"
                        Width="210" Height="42" Background="#D93B3B" FontWeight="Bold"/>
                <ProgressBar x:Name="Progress" Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Height="6" Margin="0,8,16,0"
                             Minimum="0" Maximum="100" Value="0" Foreground="#4F8CFF" Background="#33333A" BorderThickness="0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

foreach ($n in 'AppsList', 'SearchBox', 'SearchHint', 'BtnClear', 'BtnRefresh', 'BtnUninstall',
    'StatusText', 'CountText', 'Progress', 'ChkClean', 'ChkForce', 'ChkSim') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

$script:Items = $null
$script:Job = $null
$script:DoneInfo = $null
$script:IconCache = @{}

# ---------- Iconos ----------
function ConvertTo-ImageSource($icon) {
    $bs = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
        $icon.Handle, [System.Windows.Int32Rect]::Empty,
        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    $bs.Freeze()
    $bs
}
try { $script:DefaultIcon = ConvertTo-ImageSource ([System.Drawing.SystemIcons]::Application) } catch { $script:DefaultIcon = $null }

function Get-AppIcon([string]$path) {
    if (-not $path) { return $script:DefaultIcon }
    if ($script:IconCache.ContainsKey($path)) { return $script:IconCache[$path] }
    $img = $script:DefaultIcon
    try {
        $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
        if ($ic) { $img = ConvertTo-ImageSource $ic; $ic.Dispose() }
    }
    catch {}
    $script:IconCache[$path] = $img
    $img
}

# ---------- Lista / filtro ----------
$script:Predicate = [Predicate[object]] {
    param($o)
    $f = $script:SearchBox.Text
    if ([string]::IsNullOrWhiteSpace($f)) { return $true }
    $f = $f.Trim()
    if ($o.Name -and $o.Name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    if ($o.Publisher -and $o.Publisher.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    return $false
}

function Update-Count {
    $c = 0
    if ($script:Items) { foreach ($i in $script:Items) { if ($i.IsChecked) { $c++ } } }
    $script:CountText.Text = "$c seleccionadas"
}

function Load-Apps {
    $script:StatusText.Text = 'Cargando programas instalados...'
    Write-Host '[INFO] Cargando programas instalados...' -ForegroundColor DarkGray
    $apps = @(Get-InstalledApps)
    $list = New-Object 'System.Collections.Generic.List[AppItem]'
    foreach ($a in $apps) {
        $it = New-Object AppItem
        $it.Name = $a.Name
        $it.Version = $a.Version
        $it.Publisher = $a.Publisher
        $it.InstallLocation = $a.InstallLocation
        $it.IconImage = Get-AppIcon $a.IconPath
        $it.Raw = $a
        $it.add_PropertyChanged({ Update-Count })
        $list.Add($it)
    }
    $script:Items = $list
    $script:AppsList.ItemsSource = $list
    $script:AppsList.Items.Filter = $script:Predicate
    Update-Count
    $script:StatusText.Text = "Se encontraron $($apps.Count) programas."
    Write-Host "[INFO] $($apps.Count) programas encontrados." -ForegroundColor DarkGray
}

# ---------- Salida de log (cola -> consola) ----------
function Write-LogLine([string]$line) {
    $i = $line.IndexOf('|')
    if ($i -lt 0) { return }
    $lvl = $line.Substring(0, $i)
    $msg = $line.Substring($i + 1)
    $ts = Get-Date -Format 'HH:mm:ss'

    switch ($lvl) {
        'PROG' {
            $p = $msg -split '\|'
            if ($p.Count -eq 2 -and [int]$p[1] -gt 0) {
                $script:Progress.Value = (([int]$p[0] - 1) / [int]$p[1]) * 100
            }
            return
        }
        'DONE' { $script:DoneInfo = $msg; return }
        'STEP' {
            Write-Host ''
            Write-Host "[$ts] $msg" -ForegroundColor Cyan
            $script:StatusText.Text = $msg
        }
        'OK' { Write-Host "[$ts] $msg" -ForegroundColor Green }
        'WARN' { Write-Host "[$ts] $msg" -ForegroundColor Yellow }
        'ERR' { Write-Host "[$ts] $msg" -ForegroundColor Red }
        'SIM' { Write-Host "[$ts] $msg" -ForegroundColor Magenta }
        default { Write-Host "[$ts] $msg" -ForegroundColor Gray }
    }
    try { [IO.File]::AppendAllText($script:LogFile, "[$ts] $lvl $msg`r`n") } catch {}
}

function Complete-Job {
    $j = $script:Job
    $script:Job = $null
    try { $null = $j.PS.EndInvoke($j.Handle) }
    catch { Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red }
    $shown = 0
    foreach ($e in $j.PS.Streams.Error) {
        if ($shown -ge 5) { break }
        Write-Host ("[ERROR worker] " + $e.ToString()) -ForegroundColor Red
        $shown++
    }
    try { $j.PS.Dispose(); $j.RS.Close(); $j.RS.Dispose() } catch {}

    $script:Progress.Value = 100
    $script:BtnUninstall.IsEnabled = $true
    $script:BtnRefresh.IsEnabled = $true
    $script:BtnClear.IsEnabled = $true

    $summary = 'Proceso finalizado.'
    if ($script:DoneInfo) {
        $p = $script:DoneInfo -split '\|'
        $summary = "Proceso finalizado.`n`nCorrectos: $($p[0])`nCon avisos: $($p[1])`nFallidos: $($p[2])`n`nRevisa la consola para ver el detalle."
        Write-Host ''
        Write-Host ("=== RESUMEN: correctos {0} | con avisos {1} | fallidos {2} ===" -f $p[0], $p[1], $p[2]) -ForegroundColor White
        Write-Host "Log guardado en: $script:LogFile" -ForegroundColor DarkGray
    }
    $script:DoneInfo = $null
    $script:StatusText.Text = 'Listo.'
    Load-Apps
    [void][System.Windows.MessageBox]::Show($summary, 'UNISTALER', 'OK', 'Information')
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:Timer.Add_Tick({
        $line = $null
        $n = 0
        while ($n -lt 300 -and $global:Q.TryDequeue([ref]$line)) {
            Write-LogLine $line
            $n++
        }
        if ($script:Job -and $script:Job.Handle.IsCompleted -and $global:Q.IsEmpty) {
            Complete-Job
        }
    })
$script:Timer.Start()

# ---------- Eventos ----------
$SearchBox.Add_TextChanged({
        if ([string]::IsNullOrEmpty($script:SearchBox.Text)) { $script:SearchHint.Visibility = 'Visible' }
        else { $script:SearchHint.Visibility = 'Collapsed' }
        $script:AppsList.Items.Refresh()
    })

$BtnRefresh.Add_Click({ Load-Apps })

$BtnClear.Add_Click({
        if ($script:Items) { foreach ($i in $script:Items) { $i.IsChecked = $false } }
    })

$BtnUninstall.Add_Click({
        if ($script:Job) { return }
        $sel = @($script:Items | Where-Object { $_.IsChecked })
        if ($sel.Count -eq 0) {
            [void][System.Windows.MessageBox]::Show('No has seleccionado ningun programa.', 'Aviso', 'OK', 'Information')
            return
        }

        $sim = ($script:ChkSim.IsChecked -eq $true)
        $names = ($sel | ForEach-Object { ' - ' + $_.Name }) -join "`n"
        $txt = "Se desinstalaran $($sel.Count) programa(s):`n`n$names`n`n" +
        "Se cerraran los procesos abiertos de esos programas.`nEsta accion NO se puede deshacer."
        if ($sim) { $txt += "`n`n(MODO SIMULACION: no se borrara nada)" }
        $r = [System.Windows.MessageBox]::Show($txt, 'Confirmar desinstalacion', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }

        $opts = @{
            Clean    = ($script:ChkClean.IsChecked -eq $true)
            Force    = ($script:ChkForce.IsChecked -eq $true)
            Simulate = $sim
        }

        Write-Host ''
        Write-Host '==================== NUEVA TANDA ====================' -ForegroundColor White
        Write-Host ("Programas: {0} | Borrar restos: {1} | Forzar: {2} | Simulacion: {3}" -f $sel.Count, $opts.Clean, $opts.Force, $opts.Simulate) -ForegroundColor DarkGray

        $script:BtnUninstall.IsEnabled = $false
        $script:BtnRefresh.IsEnabled = $false
        $script:BtnClear.IsEnabled = $false
        $script:Progress.Value = 0
        $script:StatusText.Text = 'Trabajando... mira la consola de log.'

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Q', $global:Q)
        $rs.SessionStateProxy.SetVariable('Apps', @($sel | ForEach-Object { $_.Raw }))
        $rs.SessionStateProxy.SetVariable('Opts', $opts)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($WorkerLib + "`r`nInvoke-Batch")
        $h = $ps.BeginInvoke()
        $script:Job = @{ PS = $ps; RS = $rs; Handle = $h }
    })

$window.Add_Closing({
        param($s, $e)
        if ($script:Job) {
            $r = [System.Windows.MessageBox]::Show('Hay una desinstalacion en curso. Cerrar ahora la interrumpe. Cerrar de todas formas?',
                'UNISTALER', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $e.Cancel = $true }
            else { try { $script:Job.PS.Stop() } catch {} }
        }
    })

# ============================================================
#  5) ARRANQUE
# ============================================================
try {
    Clear-Host
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host '  UNISTALER - Consola de LOG' -ForegroundColor Cyan
    Write-Host '  Aqui veras todo lo que hace la ventana.' -ForegroundColor Cyan
    Write-Host '  No cierres esta consola mientras la uses.' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host "Log en archivo: $script:LogFile" -ForegroundColor DarkGray
    Write-Host ''
    Load-Apps
    [void]$window.ShowDialog()
}
catch {
    Write-Host ''
    Write-Host "ERROR FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    try { $script:Timer.Stop() } catch {}
    Write-Host ''
    Write-Host "Log guardado en: $script:LogFile" -ForegroundColor DarkGray
    Read-Host 'Enter para cerrar esta consola' | Out-Null
}