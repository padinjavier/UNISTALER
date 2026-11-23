<#
  Desinstalador APB - Version con UI (WPF, modo noche).  (Archivo solo ASCII a proposito.)
  Reutiliza la logica segura del v3.

  NOVEDADES v4:
    - Si una carpeta no se puede borrar porque un proceso la esta usando,
      se detecta el proceso, se te pregunta, y si aceptas se cierra y se reintenta.
    - Flujo secuencial estricto: App1 -> (exito o limpieza manual) -> App2.
    - Dialogo de error de borrado con opcion de forzar cierre de procesos.

  PROTECCIONES (identicas al v3):
    - NUNCA toca Documentos, Escritorio, Descargas, Imagenes, Videos, Musica.
    - NUNCA borra archivos de usuario (.docx, .xlsx, .pdf, .jpg, .mp4, etc.)
      salvo confirmacion explicita carpeta por carpeta.
    - NUNCA toca firewall, servicios, tareas programadas ni variables de entorno.
    - Solo borra la entrada de desinstalacion del registro, con backup previo.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# ---------- Elevacion ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$script:LogFile = Join-Path $env:TEMP ("Desinstalar-Seguro_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
function Write-Log([string]$m) {
    try { Add-Content -LiteralPath $script:LogFile -Value ("{0:HH:mm:ss}  {1}" -f (Get-Date), $m) } catch {}
}

# ---------- Tipos auxiliares (C#) ----------
if (-not ('AppItem' -as [type])) {
    Add-Type -ReferencedAssemblies PresentationCore, WindowsBase -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Windows.Media;
using System.Runtime.InteropServices;

public class AppItem : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    public static event Action SelectionChanged;
    static long counter = 0;
    void Notify(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }

    public string Name { get; set; }
    public string Version { get; set; }
    public string Publisher { get; set; }
    public object Data { get; set; }
    public long SelOrder { get; set; }

    public string Letter {
        get { string n = Name == null ? "" : Name.Trim(); return n.Length > 0 ? n.Substring(0, 1).ToUpper() : "?"; }
    }

    bool sel;
    public bool IsSelected {
        get { return sel; }
        set {
            if (sel == value) return;
            sel = value;
            SelOrder = value ? ++counter : 0;
            Notify("IsSelected");
            Action h = SelectionChanged; if (h != null) h();
        }
    }

    ImageSource icon;
    public ImageSource Icon { get { return icon; } set { icon = value; Notify("Icon"); } }

    double sizeMB = -1;
    public double SizeMB { get { return sizeMB; } set { sizeMB = value; Notify("SizeMB"); Notify("SizeText"); } }
    public string SizeText {
        get {
            if (sizeMB < 0) return "-";
            if (sizeMB >= 1024) return (sizeMB / 1024).ToString("0.00") + " GB";
            if (sizeMB < 0.1) return "<0.1 MB";
            return sizeMB.ToString("0.#") + " MB";
        }
    }
}

public static class ShellNotify
{
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@
}

# ============================================================
#  CORE (logica v3)
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
            $es = 0
            if ($p.EstimatedSize -is [ValueType]) { $es = [int64]$p.EstimatedSize }
            [pscustomobject]@{
                Name = $p.DisplayName; Version = $p.DisplayVersion; Publisher = $p.Publisher
                InstallLocation = $p.InstallLocation; DisplayIcon = $p.DisplayIcon
                UninstallString = $p.UninstallString; QuietUninstallString = $p.QuietUninstallString
                WindowsInstaller = $p.WindowsInstaller; Key = $item.PSChildName
                PSPath = $item.PSPath; Origen = $k.Origen; EstimatedSizeKB = $es
            }
        }
    }
    @($apps | Sort-Object Name)
}

function Get-ExeFromString([string]$s) {
    if (-not $s) { return $null }
    $s = [Environment]::ExpandEnvironmentVariables($s)
    if ($s -match '^\s*"?([A-Za-z]:\\[^"]*?\.(?:exe|ico|dll))') { return $matches[1] }
    return $null
}

function Get-FolderSizeMB([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $sum) { return 0 }
    [math]::Round(($sum / 1MB), 1)
}

function Get-CleanAppName([string]$name) {
    if (-not $name) { return '' }
    ($name -replace '\s*\(.*?\)', '' -replace '\s+(x64|x86|64-bit|32-bit|v?\d+(\.\d+)+).*$', '').Trim()
}

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

function Get-ProtectedUserFolders {
    @(
        [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyVideos'),
        (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Pictures'),
        (Join-Path $env:USERPROFILE 'Music'), (Join-Path $env:USERPROFILE 'Videos'),
        (Join-Path $env:USERPROFILE 'OneDrive'), (Join-Path $env:USERPROFILE 'Favorites'),
        (Join-Path $env:USERPROFILE 'Contacts'), (Join-Path $env:USERPROFILE 'Links'),
        (Join-Path $env:USERPROFILE 'Saved Games'), (Join-Path $env:USERPROFILE 'Searches')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { $_.TrimEnd('\') }
}

function Test-ProtectedPath([string]$path) {
    try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $true }
    if ($full.Length -le 3) { return $true }
    $pf86 = ${env:ProgramFiles(x86)}; if (-not $pf86) { $pf86 = $env:ProgramFiles }
    $protected = @(
        $env:SystemDrive, $env:windir, $env:ProgramFiles, $pf86, $env:ProgramData,
        $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA,
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
    foreach ($uf in (Get-ProtectedUserFolders)) {
        if ($full -eq $uf -or $full -like ($uf + '\*')) { return $true }
    }
    return $false
}

function Test-FolderContainsUserFiles([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return $false }
    $n = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $script:ProtectedExtensions -contains $_.Extension.ToLower() }).Count
    return ($n -gt 0)
}

function Get-NameTokens([string]$name, [string]$publisher) {
    $generic = @('microsoft', 'windows', 'google', 'adobe', 'apple', 'intel', 'nvidia', 'amd', 'oracle',
        'update', 'runtime', 'redistributable', 'visual', 'studio', 'driver', 'drivers', 'software',
        'system', 'service', 'services', 'common', 'shared', 'setup', 'install', 'installer', 'program',
        'programs', 'files', 'application', 'apps', 'data', 'tools', 'client', 'server', 'desktop',
        'professional', 'standard', 'enterprise', 'home', 'edition', 'plus', 'premium', 'ultimate',
        'community', 'free', 'language', 'pack', 'advanced', 'security', 'scanner', 'monitor', 'manager',
        'control', 'center', 'agent', 'helper', 'utility', 'utilities', 'wizard', 'config', 'editor', 'viewer')
    if (-not $name) { return @() }
    $clean = Get-CleanAppName $name
    @($clean -split '\s+' | Where-Object {
            $_ -match '^[A-Za-z0-9][A-Za-z0-9\-\+\.]*$' -and
            $_.Length -ge 4 -and
            $_ -notmatch '^\d+$' -and
            ($generic -notcontains $_.ToLower())
        } | Select-Object -First 2) | Sort-Object -Unique
}

function Get-AppAssociatedPaths($app) {
    $r = [System.Collections.Generic.List[object]]::new()

    if ($app.InstallLocation) {
        $loc = $app.InstallLocation.Trim('"').TrimEnd('\')
        if ($loc -and (Test-Path -LiteralPath $loc) -and -not (Test-ProtectedPath $loc)) {
            $r.Add([pscustomobject]@{ Path = $loc; Tipo = 'Instalacion'; SizeMB = (Get-FolderSizeMB $loc) })
        }
    }

    foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)' -and (Test-Path -LiteralPath $dir) -and -not (Test-ProtectedPath $dir)) {
                if (-not ($r | Where-Object { $_.Path -eq $dir })) {
                    $r.Add([pscustomobject]@{ Path = $dir; Tipo = 'Ejecutable'; SizeMB = (Get-FolderSizeMB $dir) })
                }
            }
        }
    }

    $tokens = @(Get-NameTokens $app.Name $app.Publisher)

    $words = ($app.Name -split '\s+') | Where-Object { $_ -match '^[A-Za-z]{2,}' } | Select-Object -First 2
    if ($words -and $tokens.Count -gt 0) {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Join-Path $env:LOCALAPPDATA 'Programs')) |
            Where-Object { $_ -and (Test-Path $_) }
        $pattern = '*' + ($words -join ' ') + '*'
        foreach ($rt in $roots) {
            Get-ChildItem $rt -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pattern } |
                ForEach-Object {
                    $full = $_.FullName
                    if (Test-ProtectedPath $full) { return }
                    if (-not ($r | Where-Object { $_.Path -eq $full })) {
                        $r.Add([pscustomobject]@{ Path = $full; Tipo = 'Programa'; SizeMB = (Get-FolderSizeMB $full) })
                    }
                }
        }
    }

    if ($tokens.Count -gt 0) {
        $dataRoots = @(
            @{ Root = $env:APPDATA; Kind = 'APPDATA' },
            @{ Root = $env:LOCALAPPDATA; Kind = 'LOCALAPPDATA' },
            @{ Root = (Join-Path $env:LOCALAPPDATA 'Programs'); Kind = 'LOCALAPPDATA\Programs' },
            @{ Root = $env:ProgramData; Kind = 'ProgramData' }
        ) | Where-Object { $_.Root -and (Test-Path $_.Root) }
        foreach ($dr in $dataRoots) {
            foreach ($tok in $tokens) {
                Get-ChildItem -LiteralPath $dr.Root -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$tok*" } |
                    ForEach-Object {
                        $full = $_.FullName
                        if (Test-ProtectedPath $full) { return }
                        if (-not ($r | Where-Object { $_.Path -eq $full })) {
                            $r.Add([pscustomobject]@{ Path = $full; Tipo = $dr.Kind; SizeMB = (Get-FolderSizeMB $full) })
                        }
                    }
            }
        }

        $cachePatterns = @('*cache*', '*temp*', '*tmp*', '*log*')
        foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData) | Where-Object { $_ -and (Test-Path $_) }) {
            foreach ($tok in $tokens) {
                foreach ($pat in $cachePatterns) {
                    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*$tok*" -and $_.Name -like $pat } |
                        ForEach-Object {
                            $full = $_.FullName
                            if (Test-ProtectedPath $full) { return }
                            if (-not ($r | Where-Object { $_.Path -eq $full })) {
                                $r.Add([pscustomobject]@{ Path = $full; Tipo = 'Cache'; SizeMB = (Get-FolderSizeMB $full) })
                            }
                        }
                }
            }
        }
    }
    @($r | Sort-Object Path -Unique)
}

function Get-Shortcuts($app, $installPaths) {
    $r = [System.Collections.Generic.List[object]]::new()
    $fullClean = Get-CleanAppName $app.Name
    $installOnly = @($installPaths |
            Where-Object { $_ -and $_.Tipo -in @('Instalacion', 'Programa', 'Ejecutable') } |
            ForEach-Object { $_.Path.TrimEnd('\').ToLower() })
    if (-not $fullClean -and $installOnly.Count -eq 0) { return @() }
    $roots = @(
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    ) | Where-Object { $_ -and (Test-Path $_) }
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch {}
    try {
        foreach ($root in $roots) {
            Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $lnk = $_
                    $matched = $false
                    if ($shell -and $installOnly.Count -gt 0) {
                        try {
                            $target = $shell.CreateShortcut($lnk.FullName).TargetPath
                            if ($target) {
                                $tl = $target.ToLower()
                                foreach ($ip in $installOnly) {
                                    if ($tl -eq $ip -or $tl.StartsWith($ip + '\')) { $matched = $true; break }
                                }
                            }
                        } catch {}
                    }
                    if (-not $matched -and $fullClean.Length -ge 5 -and $lnk.BaseName -like "*$fullClean*") { $matched = $true }
                    if ($matched) { $r.Add([pscustomobject]@{ Path = $lnk.FullName; Tipo = 'Acceso directo' }) }
                }
        }
    }
    finally {
        if ($shell) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch {} }
    }
    @($r | Sort-Object Path -Unique)
}

function Stop-ProcessesInFolder([string]$folder) {
    $prefix = $folder.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
}

# ============================================================
#  NUEVAS FUNCIONES PARA MANEJO DE BLOQUEOS
# ============================================================
function Get-BlockingProcesses([string]$folder) {
    $prefix = $folder.TrimEnd('\') + '\'
    $procs = @()
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        }
    } catch {}
    return $procs
}

function Stop-BlockingProcesses($procs) {
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Log "Proceso cerrado: $($p.Name) (PID: $($p.ProcessId))"
        } catch {
            Write-Log "No se pudo cerrar el proceso $($p.Name): $_"
        }
    }
}

function Remove-FolderSafe([string]$folder, [bool]$Force = $false) {
    if (Test-ProtectedPath $folder) { Write-Log "PROTEGIDA, omitida: $folder"; return $false }
    if ((-not $Force) -and (Test-FolderContainsUserFiles $folder)) { Write-Log "Con archivos de usuario, omitida: $folder"; return $false }

    # 1. Intento normal (silencioso)
    $null = & cmd.exe /c "rd /s /q `"$folder`"" 2>&1
    if (Wait-PathGone $folder 2) {
        Write-Log "Carpeta eliminada (normal): $folder"
        return $true
    }

    # 2. Si falló, buscar procesos bloqueantes
    $blockers = Get-BlockingProcesses $folder
    if ($blockers.Count -gt 0) {
        $names = ($blockers | Select-Object -ExpandProperty Name -Unique) -join ', '
        $msg = "La carpeta no se pudo borrar porque esta en uso por:`n`n$names`n`n¿Deseas cerrar estos procesos para continuar con la eliminacion?"
        
        $choice = Show-Confirm 'Archivos en uso' $msg 'Si, cerrar y borrar' 'No, omitir carpeta' 'warn'
        
        if ($choice) {
            Set-Progress $folder '' 'Cerrando procesos...'
            Stop-BlockingProcesses $blockers
            Wait-Ui 1000
            Close-Progress
            
            $null = & cmd.exe /c "rd /s /q `"$folder`"" 2>&1
            if (Wait-PathGone $folder 5) {
                Write-Log "Carpeta eliminada (tras cerrar procesos): $folder"
                return $true
            }
        } else {
            Write-Log "Usuario omitio cerrar procesos para: $folder"
            return $false
        }
    }

    # 3. Intento forzado (takeown/icacls)
    if (Test-Path -LiteralPath $folder) {
        Stop-ProcessesInFolder $folder
        $null = & takeown.exe /f $folder /r /d s 2>&1
        $null = & icacls.exe $folder /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q 2>&1
        $null = & cmd.exe /c "rd /s /q `"$folder`"" 2>&1
        $null = Wait-PathGone $folder 5
    }

    $ok = -not (Test-Path -LiteralPath $folder)
    if ($ok) { Write-Log "Carpeta eliminada (forzado): $folder" } 
    else { Write-Log "Carpeta NO se pudo borrar definitivamente: $folder" }
    return $ok
}

function Remove-FileSafe([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $true }
    $ext = [IO.Path]::GetExtension($file).ToLower()
    if ($script:ProtectedExtensions -contains $ext) { return $false }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $file) {
        & icacls.exe $file /setowner "*S-1-5-32-544" /c /q 2>&1 | Out-Null
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    $ok = -not (Test-Path -LiteralPath $file)
    Write-Log ("Archivo {0}: {1}" -f $(if ($ok) { 'eliminado' } else { 'NO se pudo borrar' }), $file)
    return $ok
}

function Remove-RegistryEntryWithBackup($app) {
    if (-not (Test-Path -LiteralPath $app.PSPath)) { return $true }
    try {
        $safeName = ($app.Key -replace '[\\/:*?"<>|]', '_')
        $backup = Join-Path $env:TEMP ("RegBackup_{0}_{1}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $safeName)
        $native = $app.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
        $native = $native -replace '^HKCU:\\?', 'HKEY_CURRENT_USER\' -replace '^HKLM:\\?', 'HKEY_LOCAL_MACHINE\'
        & reg.exe export $native $backup /y 2>&1 | Out-Null
        Remove-Item -LiteralPath $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Entrada de registro eliminada (backup: $backup)"
        return (-not (Test-Path -LiteralPath $app.PSPath))
    }
    catch { return $false }
}

function Get-SnapshotStatus($snapshot) {
    $remaining = @(); $removed = @(); $remShort = @(); $removedShort = @()
    foreach ($p in $snapshot.Paths) { if (Test-Path -LiteralPath $p.Path) { $remaining += $p } else { $removed += $p } }
    foreach ($s in $snapshot.Shortcuts) { if (Test-Path -LiteralPath $s.Path) { $remShort += $s } else { $removedShort += $s } }
    [pscustomobject]@{
        RemainingPaths = $remaining; RemovedPaths = $removed
        RemainingShortcuts = $remShort; RemovedShortcuts = $removedShort
    }
}

# ============================================================
#  UTILIDADES DE UI
# ============================================================
function Invoke-UiPump {
    try {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
    } catch {}
}

function Wait-Ui([int]$Ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) { Invoke-UiPump; Start-Sleep -Milliseconds 50 }
}

function Wait-PathGone([string]$Path, [int]$Sec = 5) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Test-Path -LiteralPath $Path) -and $sw.Elapsed.TotalSeconds -lt $Sec) { Wait-Ui 250 }
    return (-not (Test-Path -LiteralPath $Path))
}

function Wait-SnapshotSettled($snap, $app, [string]$sub, [int]$MaxSec = 30, [int]$StableSec = 6) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastKey = ''
    $lastChange = 0.0
    while ($true) {
        $st = Get-SnapshotStatus $snap
        $reg = Test-Path -LiteralPath $app.PSPath
        $nP = @($st.RemainingPaths).Count
        $nS = @($st.RemainingShortcuts).Count
        $left = $nP + $nS + $(if ($reg) { 1 } else { 0 })
        if ($left -eq 0) { return $st }
        $key = "$nP|$nS|$reg"
        $now = $sw.Elapsed.TotalSeconds
        if ($key -ne $lastKey) { $lastKey = $key; $lastChange = $now }
        if (($now - $lastChange) -ge $StableSec -or $now -ge $MaxSec) { return $st }
        Set-Progress $app.Name $sub ("Esperando a que Windows termine de borrar... ({0} pendiente(s))" -f $left)
        Wait-Ui 700
    }
}

function Invoke-NormalUninstall($app, [int]$TimeoutMin = 15) {
    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')
    if ($isMsi) { $exe = 'msiexec.exe'; $argLine = "/x $($app.Key) /qn /norestart" }
    elseif ($app.QuietUninstallString) { $exe = 'cmd.exe'; $argLine = '/c "' + $app.QuietUninstallString + '"' }
    elseif ($app.UninstallString) { $exe = 'cmd.exe'; $argLine = '/c "' + $app.UninstallString + '"' }
    else { Write-Log 'Sin desinstalador registrado'; return $null }
    Write-Log "Ejecutando: $exe $argLine"
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            Invoke-UiPump
            Start-Sleep -Milliseconds 100
            if ($sw.Elapsed.TotalMinutes -ge $TimeoutMin) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                Write-Log 'Tiempo agotado'
                return -1
            }
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode

        $loc = if ($app.InstallLocation) { ([string]$app.InstallLocation).Trim('"').TrimEnd('\') } else { '' }
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        Wait-Ui 1500
        while ((Test-Path -LiteralPath $app.PSPath) -and ($sw2.Elapsed.TotalMinutes -lt $TimeoutMin)) {
            $busy = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                    $_.ExecutablePath -and (
                        $_.Name -match '^(Au_|unins\d*|uninst\w*|uninstall\w*)\.exe$' -or
                        ($loc -and $_.ExecutablePath.StartsWith($loc + '\', [StringComparison]::OrdinalIgnoreCase))
                    )
                }).Count
            if ($busy -eq 0) { break }
            Wait-Ui 700
        }
        return $code
    }
    catch { Write-Log "Error al ejecutar desinstalador: $($_.Exception.Message)"; return -1 }
}

function Get-AppIcon($app) {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($app.DisplayIcon) {
        $di = [Environment]::ExpandEnvironmentVariables([string]$app.DisplayIcon)
        if ($di -match '^\s*"?([A-Za-z]:\\[^"]*?\.(?:exe|ico|dll))') { $candidates.Add($matches[1]) }
    }
    if ($app.InstallLocation) {
        $loc = ([string]$app.InstallLocation).Trim('"')
        if ($loc -and (Test-Path -LiteralPath $loc)) {
            try {
                Get-ChildItem -LiteralPath $loc -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '^(unins|uninst|setup|update)' } |
                    Sort-Object Length -Descending | Select-Object -First 3 |
                    ForEach-Object { $candidates.Add($_.FullName) }
            } catch {}
        }
    }
    $us = Get-ExeFromString $app.UninstallString
    if ($us) { $candidates.Add($us) }
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $ico = $null
        try {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($c)
            if ($ico) {
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $ico.Handle, [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                $src.Freeze()
                return $src
            }
        }
        catch {}
        finally { if ($ico) { $ico.Dispose() } }
    }
    return $null
}

function Format-SizeMB([double]$mb) {
    if ($mb -ge 1024) { return ('{0:0.00} GB' -f ($mb / 1024)) }
    return ('{0:0.#} MB' -f $mb)
}

# ============================================================
#  ESTILOS Y DIALOGOS (modo noche)
# ============================================================
if (-not [System.Windows.Application]::Current) { $script:WpfApp = New-Object System.Windows.Application }
else { $script:WpfApp = [System.Windows.Application]::Current }
$script:WpfApp.ShutdownMode = 'OnExplicitShutdown'

$stylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="BgBrush" Color="#16161A"/>
  <SolidColorBrush x:Key="PanelBrush" Color="#1E1E23"/>
  <SolidColorBrush x:Key="Panel2Brush" Color="#26262C"/>
  <SolidColorBrush x:Key="LineBrush" Color="#34343C"/>
  <SolidColorBrush x:Key="TextBrush" Color="#ECECF0"/>
  <SolidColorBrush x:Key="DimBrush" Color="#9A9AA6"/>
  <SolidColorBrush x:Key="AccentBrush" Color="#3B82F6"/>
  <SolidColorBrush x:Key="DangerBrush" Color="#EF4444"/>
  <SolidColorBrush x:Key="SuccessBrush" Color="#22C55E"/>
  <SolidColorBrush x:Key="WarnBrush" Color="#F59E0B"/>

  <Style x:Key="BtnSecondary" TargetType="Button">
    <Setter Property="Background" Value="#33333B"/>
    <Setter Property="Foreground" Value="#FFFFFF"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="18,9"/>
    <Setter Property="Margin" Value="8,0,0,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="#44444F"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnSecondary}">
    <Setter Property="Background" Value="#3B82F6"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="#5B9BFF"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnSecondary}">
    <Setter Property="Background" Value="#DC2F3F"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="#F0485A"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="DarkTextBox" TargetType="TextBox">
    <Setter Property="Background" Value="#26262C"/>
    <Setter Property="Foreground" Value="#ECECF0"/>
    <Setter Property="CaretBrush" Value="#ECECF0"/>
    <Setter Property="BorderBrush" Value="#34343C"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="bd" Property="BorderBrush" Value="#3B82F6"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="#ECECF0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border x:Name="box" Width="20" Height="20" CornerRadius="5" BorderThickness="1.5"
                    BorderBrush="#6B6B75" Background="Transparent" VerticalAlignment="Top" Margin="0,1,0,0">
              <Path x:Name="tick" Data="M4,10 L8,14 L16,5" Stroke="White" StrokeThickness="2"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter Grid.Column="1" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="box" Property="BorderBrush" Value="#3B82F6"/>
            </Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="box" Property="Background" Value="#3B82F6"/>
              <Setter TargetName="box" Property="BorderBrush" Value="#3B82F6"/>
              <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="ScrollThumbStyle" TargetType="Thumb">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="th" Background="#4A4A55" CornerRadius="4" Margin="2,0"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="th" Property="Background" Value="#6A6A78"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="ScrollRepeatStyle" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="IsTabStop" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Border Background="Transparent"/>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="12"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Grid Background="Transparent">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.DecreaseRepeatButton>
                <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ScrollRepeatStyle}"/>
              </Track.DecreaseRepeatButton>
              <Track.Thumb>
                <Thumb Style="{StaticResource ScrollThumbStyle}"/>
              </Track.Thumb>
              <Track.IncreaseRepeatButton>
                <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ScrollRepeatStyle}"/>
              </Track.IncreaseRepeatButton>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@
$script:WpfApp.Resources.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Parse($stylesXaml))

$script:BrushConv = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$hex) { $script:BrushConv.ConvertFromString($hex) }
function New-Thick([double]$l, [double]$t, [double]$r, [double]$b) { [System.Windows.Thickness]::new($l, $t, $r, $b) }

function New-Text([string]$Text, [string]$Color = '#ECECF0', [double]$Size = 13, [string]$Weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = (Get-Brush $Color)
    $t.FontSize = $Size
    $t.FontWeight = $Weight
    $t.TextWrapping = 'Wrap'
    $t
}

$script:DialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI">
  <Border Margin="16" Background="#1E1E23" BorderBrush="#34343C" BorderThickness="1" CornerRadius="12">
    <Border.Effect>
      <DropShadowEffect BlurRadius="22" ShadowDepth="2" Opacity="0.55" Color="Black"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border x:Name="Header" Grid.Row="0" Padding="22,18,22,10" Background="Transparent">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border x:Name="IconBox" Width="40" Height="40" CornerRadius="20" Background="#3B82F6" Margin="0,0,14,0">
            <TextBlock x:Name="IconText" Text="i" FontSize="22" FontWeight="Bold" Foreground="White"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <TextBlock x:Name="TitleText" FontSize="17" FontWeight="Bold" Foreground="#ECECF0" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="SubText" FontSize="12" Foreground="#9A9AA6" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Grid>
      </Border>
      <Grid x:Name="Body" Grid.Row="1" Margin="22,6,22,6"/>
      <StackPanel x:Name="Buttons" Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="22,10,22,20"/>
    </Grid>
  </Border>
</Window>
'@

function New-Dialog {
    param([string]$Title = '', [string]$Subtitle = '', [double]$Width = 540, [double]$Height = 260, [string]$Kind = 'info', [switch]$NoEsc)
    $w = [System.Windows.Markup.XamlReader]::Parse($script:DialogXaml)
    $w.Width = $Width + 32
    $w.Height = $Height + 32
    $w.FindName('TitleText').Text = $Title
    $w.FindName('SubText').Text = $Subtitle
    if (-not $Subtitle) { $w.FindName('SubText').Visibility = 'Collapsed' }
    $map = @{
        info = @('i', '#3B82F6'); question = @('?', '#3B82F6'); warn = @('!', '#F59E0B')
        danger = @('!', '#EF4444'); success = @('OK', '#22C55E')
    }
    $m = $map[$Kind]; if (-not $m) { $m = $map['info'] }
    $w.FindName('IconText').Text = $m[0]
    if ($m[0] -eq 'OK') { $w.FindName('IconText').FontSize = 14 }
    $w.FindName('IconBox').Background = (Get-Brush $m[1])
    $w.FindName('Header').Add_MouseLeftButtonDown({
            param($s, $e)
            try { [System.Windows.Window]::GetWindow($s).DragMove() } catch {}
        })
    if (-not $NoEsc) {
        $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    }
    if ($script:MainWindow -and $script:MainWindow.IsVisible) { $w.Owner = $script:MainWindow }
    @{ Win = $w; Body = $w.FindName('Body'); Buttons = $w.FindName('Buttons') }
}

function Add-DlgButton($d, [string]$Text, [string]$Style, $Value, [switch]$Default, [scriptblock]$OnClick) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.Style = $script:WpfApp.FindResource($Style)
    $b.Tag = $Value
    if ($Default) { $b.IsDefault = $true }
    if ($OnClick) {
        $b.Add_Click($OnClick)
    }
    else {
        $b.Add_Click({
                param($s, $e)
                $script:DlgResult = $s.Tag
                [System.Windows.Window]::GetWindow($s).Close()
            })
    }
    $null = $d.Buttons.Children.Add($b)
    $b
}

function Show-Dlg($d, $DefaultResult) {
    $script:DlgResult = $DefaultResult
    [void]$d.Win.ShowDialog()
    $script:DlgResult
}

function Add-TextBody($d, [string]$Text) {
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $t = New-Text $Text '#D0D0D8' 14
    $t.Margin = (New-Thick 0 4 8 4)
    $sv.Content = $t
    $null = $d.Body.Children.Add($sv)
}

function Show-Message([string]$Title, [string]$Message, [string]$Kind = 'info', [string]$Ok = 'Aceptar') {
    $lines = ($Message -split "`n" | ForEach-Object { [math]::Max(1, [math]::Ceiling($_.Length / 60)) } | Measure-Object -Sum).Sum
    $h = [math]::Min(560, 160 + 21 * $lines)
    $d = New-Dialog -Title $Title -Width 540 -Height $h -Kind $Kind
    Add-TextBody $d $Message
    $null = Add-DlgButton $d $Ok 'BtnPrimary' $true -Default
    $null = Show-Dlg $d $true
}

function Show-Confirm([string]$Title, [string]$Message, [string]$Yes = 'Si, continuar', [string]$No = 'Cancelar', [string]$Kind = 'question', [switch]$Danger) {
    $lines = ($Message -split "`n" | ForEach-Object { [math]::Max(1, [math]::Ceiling($_.Length / 60)) } | Measure-Object -Sum).Sum
    $h = [math]::Min(600, 170 + 21 * $lines)
    $d = New-Dialog -Title $Title -Width 560 -Height $h -Kind $Kind
    Add-TextBody $d $Message
    $null = Add-DlgButton $d $No 'BtnSecondary' $false
    $yesStyle = if ($Danger) { 'BtnDanger' } else { 'BtnPrimary' }
    $null = Add-DlgButton $d $Yes $yesStyle $true -Default
    [bool](Show-Dlg $d $false)
}

# ---------- Progreso ----------
function Open-Progress {
    if ($script:Prog) { return }
    $d = New-Dialog -Title 'Procesando...' -Subtitle '' -Width 500 -Height 200 -Kind 'info' -NoEsc
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    $status = New-Text '' '#D0D0D8' 13
    $status.Margin = (New-Thick 0 0 0 14)
    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.IsIndeterminate = $true
    $bar.Height = 6
    $bar.BorderThickness = (New-Thick 0 0 0 0)
    $bar.Background = (Get-Brush '#34343C')
    $bar.Foreground = (Get-Brush '#3B82F6')
    $null = $sp.Children.Add($status)
    $null = $sp.Children.Add($bar)
    $null = $d.Body.Children.Add($sp)
    $script:Prog = @{ Dlg = $d; Title = $d.Win.FindName('TitleText'); Sub = $d.Win.FindName('SubText'); Status = $status }
    $d.Win.Show()
    Invoke-UiPump
}

function Set-Progress([string]$Title, [string]$Sub, [string]$Status) {
    if (-not $script:Prog) { Open-Progress }
    $script:Prog.Title.Text = $Title
    $script:Prog.Sub.Text = $Sub
    $script:Prog.Sub.Visibility = 'Visible'
    $script:Prog.Status.Text = $Status
    Invoke-UiPump
}

function Close-Progress {
    if ($script:Prog) {
        try { $script:Prog.Dlg.Win.Close() } catch {}
        $script:Prog = $null
        Invoke-UiPump
    }
}

# ---------- Dialogo de rutas ----------
function New-PathRow([string]$Tipo, [string]$Path, [string]$Size, [string]$Color = '#3B82F6') {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = (New-Thick 0 4 0 4)
    1..3 | ForEach-Object { $null = $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
    $g.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(138)
    $g.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $g.ColumnDefinitions[2].Width = [System.Windows.GridLength]::Auto

    $pill = New-Object System.Windows.Controls.Border
    $pill.Background = (Get-Brush '#2D2D35')
    $pill.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $pill.Padding = (New-Thick 8 2 8 2)
    $pill.HorizontalAlignment = 'Left'
    $pill.VerticalAlignment = 'Top'
    $pt = New-Text $Tipo $Color 11 'SemiBold'
    $pt.TextWrapping = 'NoWrap'
    $pill.Child = $pt
    $null = $g.Children.Add($pill)

    $tp = New-Text $Path '#ECECF0' 12.5
    $tp.Margin = (New-Thick 0 1 10 0)
    [System.Windows.Controls.Grid]::SetColumn($tp, 1)
    $null = $g.Children.Add($tp)

    if ($Size) {
        $ts = New-Text $Size '#9A9AA6' 12
        $ts.VerticalAlignment = 'Top'
        $ts.Margin = (New-Thick 0 1 0 0)
        [System.Windows.Controls.Grid]::SetColumn($ts, 2)
        $null = $g.Children.Add($ts)
    }
    $g
}

function New-ScrollCard {
    $card = New-Object System.Windows.Controls.Border
    $card.Background = (Get-Brush '#18181C')
    $card.BorderBrush = (Get-Brush '#34343C')
    $card.BorderThickness = (New-Thick 1 1 1 1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Padding = (New-Thick 14 12 6 12)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sv.Content = $sp
    $card.Child = $sv
    @{ Card = $card; Stack = $sp }
}

function Show-AppPathsDialog($App, $Paths, $Shortcuts) {
    $sub = if ($App.Version) { "v$($App.Version)   |   $($App.Publisher)" } else { "$($App.Publisher)" }
    $d = New-Dialog -Title $App.Name -Subtitle $sub -Width 800 -Height 620 -Kind 'info'
    $sc = New-ScrollCard
    $stack = $sc.Stack

    $h1 = New-Text ("Carpetas detectadas ({0})" -f @($Paths).Count) '#F59E0B' 13 'Bold'
    $h1.Margin = (New-Thick 0 0 0 6)
    $null = $stack.Children.Add($h1)
    foreach ($p in $Paths) {
        $isInstall = $p.Tipo -in @('Instalacion', 'Programa', 'Ejecutable')
        $hasUser = (-not $isInstall) -and (Test-FolderContainsUserFiles $p.Path)
        $path = $p.Path
        if ($hasUser) { $path += '   [CONTIENE ARCHIVOS DE USUARIO]' }
        $size = if ($p.SizeMB -gt 0) { Format-SizeMB $p.SizeMB } else { '' }
        $color = if ($hasUser) { '#EF4444' } else { '#3B82F6' }
        $null = $stack.Children.Add((New-PathRow $p.Tipo $path $size $color))
    }
    if (@($Paths).Count -eq 0) {
        $null = $stack.Children.Add((New-Text 'No se encontraron carpetas en disco.' '#9A9AA6' 12.5))
    }

    $h2 = New-Text ("Accesos directos detectados ({0})" -f @($Shortcuts).Count) '#F59E0B' 13 'Bold'
    $h2.Margin = (New-Thick 0 16 0 6)
    $null = $stack.Children.Add($h2)
    foreach ($s in $Shortcuts) { $null = $stack.Children.Add((New-PathRow 'Acceso directo' $s.Path '' '#A78BFA')) }
    if (@($Shortcuts).Count -eq 0) {
        $null = $stack.Children.Add((New-Text 'No se encontraron accesos directos.' '#9A9AA6' 12.5))
    }

    $note = New-Text "Documentos, Escritorio, Descargas, Imagenes, etc. NUNCA se tocan.`nArchivos .docx, .xlsx, .pdf, .jpg, .mp4, etc. NUNCA se borran sin tu confirmacion." '#22C55E' 11.5
    $note.Margin = (New-Thick 0 16 0 0)
    $null = $stack.Children.Add($note)

    $null = $d.Body.Children.Add($sc.Card)
    $null = Add-DlgButton $d 'Cancelar todo' 'BtnSecondary' 'Cancel'
    $null = Add-DlgButton $d 'Omitir esta app' 'BtnSecondary' 'Skip'
    $null = Add-DlgButton $d 'Desinstalar' 'BtnDanger' 'Uninstall' -Default
    Show-Dlg $d 'Cancel'
}

# ---------- Dialogo de resultados / restos ----------
function Update-ResultsLive {
    $left = 0
    foreach ($c in $script:CurrentChecks) {
        if ($c.Visibility -eq 'Collapsed') { continue }
        if (Test-Path -LiteralPath $c.Tag.Path) { $left++ }
        else { $c.IsChecked = $false; $c.Visibility = 'Collapsed' }
    }
    $regLeft = $false
    if ($script:RegCheck -and $script:RegCheck.Visibility -ne 'Collapsed') {
        if (Test-Path -LiteralPath $script:ResApp.PSPath) { $regLeft = $true }
        else { $script:RegCheck.IsChecked = $false; $script:RegCheck.Visibility = 'Collapsed' }
    }
    if ($left -eq 0 -and -not $regLeft) {
        $script:ResStatus.Text = 'Ya no queda nada: todo fue eliminado. Pulsa Aceptar.'
        $script:ResStatus.Foreground = (Get-Brush '#22C55E')
        if ($script:BtnResDel) { $script:BtnResDel.IsEnabled = $false }
        if ($script:BtnResSkip) {
            $script:BtnResSkip.Content = 'Aceptar'
            $script:BtnResSkip.Style = $script:WpfApp.FindResource('BtnPrimary')
        }
    }
    else {
        $n = $left + $(if ($regLeft) { 1 } else { 0 })
        $script:ResStatus.Text = "Pendientes: $n. Se revalida solo cada segundo y medio (o pulsa 'Volver a validar')."
        $script:ResStatus.Foreground = (Get-Brush '#9A9AA6')
    }
}

function Show-ResultsDialog($App, $Remaining, $RemainingShortcuts, $ExitCode, $NoUninstaller, $RegStillThere, [int]$RemovedCount) {
    $kind = 'warn'
    $d = New-Dialog -Title $App.Name -Subtitle 'Resultado de la desinstalacion' -Width 780 -Height 620 -Kind $kind
    $sc = New-ScrollCard
    $stack = $sc.Stack
    $script:CurrentChecks = New-Object System.Collections.Generic.List[object]

    if ($NoUninstaller) {
        $w = New-Text 'Este programa no tiene desinstalador registrado. Solo se pueden limpiar los restos.' '#F59E0B' 12.5
        $w.Margin = (New-Thick 0 0 0 8)
        $null = $stack.Children.Add($w)
    }
    elseif ($ExitCode -ne $null -and $ExitCode -ne 0) {
        $w = New-Text "El desinstalador termino con codigo $ExitCode (puede ser un error de idioma del instalador)." '#F59E0B' 12.5
        $w.Margin = (New-Thick 0 0 0 8)
        $null = $stack.Children.Add($w)
    }
    $ok = New-Text "Elementos eliminados por el desinstalador: $RemovedCount" '#22C55E' 13 'SemiBold'
    $ok.Margin = (New-Thick 0 0 0 4)
    $null = $stack.Children.Add($ok)

    $script:ResApp = $App
    $script:ResStatus = New-Text 'Revalidando automaticamente cada segundo y medio...' '#9A9AA6' 11.5
    $script:ResStatus.Margin = (New-Thick 0 0 0 10)
    $null = $stack.Children.Add($script:ResStatus)

    $mk = {
        param([string]$Main, [string]$Info, [string]$InfoColor, $Tag, [bool]$Checked)
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Padding = (New-Thick 10 0 0 0)
        $cb.Margin = (New-Thick 0 5 0 5)
        $cp = New-Object System.Windows.Controls.StackPanel
        $null = $cp.Children.Add((New-Text $Main '#ECECF0' 12.5))
        if ($Info) { $null = $cp.Children.Add((New-Text $Info $InfoColor 11)) }
        $cb.Content = $cp
        $cb.Tag = $Tag
        $cb.IsChecked = $Checked
        $cb
    }

    if (@($Remaining).Count -gt 0) {
        $h = New-Text 'Carpetas que aun existen' '#F59E0B' 13 'Bold'
        $h.Margin = (New-Thick 0 6 0 4)
        $null = $stack.Children.Add($h)
        foreach ($p in $Remaining) {
            $isInstall = $p.Tipo -in @('Instalacion', 'Programa', 'Ejecutable')
            $hasUser = (-not $isInstall) -and (Test-FolderContainsUserFiles $p.Path)
            $info = "[{0}]  {1}" -f $p.Tipo, (Format-SizeMB $p.SizeMB)
            $color = '#9A9AA6'
            if ($hasUser) { $info += '   CONTIENE ARCHIVOS DE USUARIO (se pedira confirmacion extra)'; $color = '#EF4444' }
            $cb = & $mk $p.Path $info $color @{ Path = $p.Path; IsFolder = $true; HasUser = $hasUser; IsInstall = $isInstall } (-not $hasUser)
            $null = $stack.Children.Add($cb)
            $script:CurrentChecks.Add($cb)
        }
    }
    if (@($RemainingShortcuts).Count -gt 0) {
        $h = New-Text 'Accesos directos' '#F59E0B' 13 'Bold'
        $h.Margin = (New-Thick 0 14 0 4)
        $null = $stack.Children.Add($h)
        foreach ($s in $RemainingShortcuts) {
            $cb = & $mk $s.Path '' '#9A9AA6' @{ Path = $s.Path; IsFolder = $false; HasUser = $false } $true
            $null = $stack.Children.Add($cb)
            $script:CurrentChecks.Add($cb)
        }
    }
    $script:RegCheck = $null
    if ($RegStillThere) {
        $h = New-Text 'Registro de Windows' '#F59E0B' 13 'Bold'
        $h.Margin = (New-Thick 0 14 0 4)
        $null = $stack.Children.Add($h)
        $cb = & $mk 'Entrada de desinstalacion (el programa sigue en la lista de Windows)' 'Se guarda un backup .reg en la carpeta TEMP antes de borrar.' '#9A9AA6' @{ Reg = $true } $true
        $null = $stack.Children.Add($cb)
        $script:RegCheck = $cb
    }

    $null = $d.Body.Children.Add($sc.Card)

    $null = Add-DlgButton $d 'Volver a validar' 'BtnSecondary' $null -OnClick { Update-ResultsLive }
    $null = Add-DlgButton $d 'Marcar seguros' 'BtnSecondary' $null -OnClick {
        foreach ($c in $script:CurrentChecks) { $c.IsChecked = (-not $c.Tag.HasUser) }
        if ($script:RegCheck) { $script:RegCheck.IsChecked = $true }
    }
    $null = Add-DlgButton $d 'Desmarcar todo' 'BtnSecondary' $null -OnClick {
        foreach ($c in $script:CurrentChecks) { $c.IsChecked = $false }
        if ($script:RegCheck) { $script:RegCheck.IsChecked = $false }
    }
    $script:BtnResSkip = Add-DlgButton $d 'No borrar nada' 'BtnSecondary' 'Skip'
    $script:BtnResDel = Add-DlgButton $d 'Borrar seleccionados' 'BtnDanger' 'Delete' -Default

    $script:ResTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ResTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:ResTimer.Add_Tick({ try { Update-ResultsLive } catch {} })
    $d.Win.Add_Closed({ try { $script:ResTimer.Stop() } catch {} })
    $script:ResTimer.Start()
    try { Update-ResultsLive } catch {}

    $action = Show-Dlg $d 'Skip'
    $selected = @($script:CurrentChecks | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { $_.Tag })
    $delReg = ($script:RegCheck -and $script:RegCheck.IsChecked -eq $true)
    [pscustomobject]@{ Action = $action; Selected = $selected; DeleteReg = [bool]$delReg }
}

# ---------- Resumen final ----------
function Show-SummaryDialog($Results) {
    $ok = @($Results | Where-Object { $_.Result -eq 'Completo' }).Count
    $parc = @($Results | Where-Object { $_.Result -eq 'Parcial' }).Count
    $fail = @($Results | Where-Object { $_.Result -eq 'Fallido' }).Count
    $skip = @($Results | Where-Object { $_.Result -in @('Omitido', 'Cancelado') }).Count
    $kind = if ($fail -gt 0) { 'danger' } elseif ($parc -gt 0) { 'warn' } else { 'success' }
    $d = New-Dialog -Title 'Resumen de la cola' -Subtitle ("{0} programa(s) procesado(s)" -f @($Results).Count) -Width 640 -Height 520 -Kind $kind

    $root = New-Object System.Windows.Controls.Grid
    $null = $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::Auto }))
    $null = $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))

    $chips = New-Object System.Windows.Controls.Grid
    $chips.Margin = (New-Thick 0 0 0 12)
    1..4 | ForEach-Object { $null = $chips.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
    $defs = @(
        @{ N = $ok; L = 'Completos'; C = '#22C55E' }, @{ N = $parc; L = 'Parciales'; C = '#F59E0B' },
        @{ N = $fail; L = 'Fallidos'; C = '#EF4444' }, @{ N = $skip; L = 'Omitidos'; C = '#9A9AA6' }
    )
    for ($i = 0; $i -lt 4; $i++) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = (Get-Brush '#26262C')
        $b.CornerRadius = [System.Windows.CornerRadius]::new(8)
        $b.Margin = (New-Thick 0 0 $(if ($i -lt 3) { 8 } else { 0 }) 0)
        $b.Padding = (New-Thick 8 10 8 10)
        $sp = New-Object System.Windows.Controls.StackPanel
        $n = New-Text ([string]$defs[$i].N) $defs[$i].C 24 'Bold'
        $n.HorizontalAlignment = 'Center'
        $l = New-Text $defs[$i].L '#9A9AA6' 11.5
        $l.HorizontalAlignment = 'Center'
        $null = $sp.Children.Add($n); $null = $sp.Children.Add($l)
        $b.Child = $sp
        [System.Windows.Controls.Grid]::SetColumn($b, $i)
        $null = $chips.Children.Add($b)
    }
    $null = $root.Children.Add($chips)

    $sc = New-ScrollCard
    [System.Windows.Controls.Grid]::SetRow($sc.Card, 1)
    foreach ($r in $Results) {
        $color = switch ($r.Result) { 'Completo' { '#22C55E' } 'Parcial' { '#F59E0B' } 'Fallido' { '#EF4444' } default { '#9A9AA6' } }
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = (New-Thick 0 4 0 4)
        1..2 | ForEach-Object { $null = $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
        $row.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(100)
        $row.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $tag = New-Text $r.Result $color 12 'SemiBold'
        $nm = New-Text $r.App '#ECECF0' 13
        [System.Windows.Controls.Grid]::SetColumn($nm, 1)
        $null = $row.Children.Add($tag); $null = $row.Children.Add($nm)
        $null = $sc.Stack.Children.Add($row)
    }
    $lg = New-Text ("Log: " + $script:LogFile) '#6B6B75' 10.5
    $lg.Margin = (New-Thick 0 12 0 0)
    $null = $sc.Stack.Children.Add($lg)
    $null = $root.Children.Add($sc.Card)
    $null = $d.Body.Children.Add($root)

    $null = Add-DlgButton $d 'Aceptar' 'BtnPrimary' $true -Default
    $null = Show-Dlg $d $true
}

# ============================================================
#  PROCESAMIENTO DE UNA APP
# ============================================================
function Invoke-ProcessOneApp($app, [int]$pos, [int]$total) {
    $sub = "Programa $pos de $total"
    Write-Log "=== $($app.Name) $($app.Version)"

    Set-Progress $app.Name $sub 'Buscando carpetas y accesos directos asociados...'
    $paths = @(Get-AppAssociatedPaths $app)
    $shortcuts = @(Get-Shortcuts $app $paths)
    Close-Progress

    $choice = Show-AppPathsDialog $app $paths $shortcuts
    if ($choice -eq 'Cancel') { Write-Log 'Cola cancelada por el usuario'; return 'Abort' }
    if ($choice -ne 'Uninstall') { return 'Omitido' }

    Set-Progress $app.Name $sub 'Ejecutando el desinstalador... (puede abrir su propia ventana)'
    $exit = Invoke-NormalUninstall $app
    Write-Log "Codigo de salida: $exit"
    Set-Progress $app.Name $sub 'Verificando que Windows termine de borrar...'

    $snap = [pscustomobject]@{ Paths = $paths; Shortcuts = $shortcuts }
    $status = Wait-SnapshotSettled $snap $app $sub
    $regThere = Test-Path -LiteralPath $app.PSPath
    $removedCount = @($status.RemovedPaths).Count + @($status.RemovedShortcuts).Count
    Close-Progress

    if (@($status.RemainingPaths).Count -eq 0 -and @($status.RemainingShortcuts).Count -eq 0 -and -not $regThere) {
        Write-Log 'Desinstalacion completa'
        return 'Completo'
    }

    $res = Show-ResultsDialog $app $status.RemainingPaths $status.RemainingShortcuts $exit ($exit -eq $null) $regThere $removedCount

    if ($res.Action -eq 'Delete') {
        $items = @($res.Selected)
        $userItems = @($items | Where-Object { $_.HasUser })
        $allowUser = $false
        if ($userItems.Count -gt 0) {
            $msg = "Estas carpetas contienen archivos personales (documentos, imagenes, etc.):`n`n" +
            (($userItems | ForEach-Object { $_.Path }) -join "`n") +
            "`n`nBorrar TODO su contenido? Esta accion no se puede deshacer."
            $allowUser = Show-Confirm 'Archivos de usuario detectados' $msg 'Si, borrar todo' 'Conservarlas' 'danger' -Danger
        }
        Open-Progress
        foreach ($t in $items) {
            if ($t.HasUser -and -not $allowUser) { continue }
            Set-Progress $app.Name $sub ("Eliminando: " + $t.Path)
            if ($t.IsFolder) { $null = Remove-FolderSafe ([string]$t.Path) ([bool]($t.HasUser -or $t.IsInstall)) }
            else { $null = Remove-FileSafe $t.Path }
        }
        if ($res.DeleteReg) {
            Set-Progress $app.Name $sub 'Eliminando la entrada del registro (con backup)...'
            $null = Remove-RegistryEntryWithBackup $app
        }
        $script:ShellDirty = $true
        Close-Progress
        
        # Verificacion final post-borrado
        $stillThere = @($items | Where-Object { Test-Path -LiteralPath $_.Path })
        if ($stillThere.Count -gt 0) {
            $errList = ($stillThere | ForEach-Object { $_.Path }) -join "`n"
            Show-Message 'Aviso de limpieza' "Algunas carpetas no se pudieron borrar (posiblemente en uso por el sistema):`n`n$errList" 'warn'
        }
    }

    $finalReg = Test-Path -LiteralPath $app.PSPath
    $finalPaths = @($paths | Where-Object { Test-Path -LiteralPath $_.Path })
    $finalShort = @($shortcuts | Where-Object { Test-Path -LiteralPath $_.Path })
    if (-not $finalReg -and $finalPaths.Count -eq 0 -and $finalShort.Count -eq 0) { Write-Log 'Veredicto: completo'; return 'Completo' }
    if (-not $finalReg) { Write-Log 'Veredicto: parcial'; return 'Parcial' }
    Write-Log 'Veredicto: fallido (registro presente)'
    return 'Fallido'
}

function Invoke-UninstallQueue {
    if ($script:Busy) { return }
    $queue = @($script:Items | Where-Object { $_.IsSelected } | Sort-Object SelOrder)
    if ($queue.Count -eq 0) { return }

    $list = for ($i = 0; $i -lt $queue.Count; $i++) { "{0}. {1}" -f ($i + 1), $queue[$i].Name }
    $msg = "Se procesaran {0} programa(s) en este orden:`n`n{1}`n`nAntes de cada uno veras las rutas detectadas y podras omitirlo." -f $queue.Count, ($list -join "`n")
    if (-not (Show-Confirm 'Procesar cola de desinstalacion' $msg 'Continuar' 'Cancelar' 'question' -Danger)) { return }

    $script:Busy = $true
    $script:ShellDirty = $false
    $results = New-Object System.Collections.Generic.List[object]
    try {
        $idx = 0
        foreach ($q in $queue) {
            $idx++
            $r = Invoke-ProcessOneApp $q.Data $idx $queue.Count
            if ($r -eq 'Abort') { break }
            $results.Add([pscustomobject]@{ App = $q.Name; Result = $r })
        }
    }
    finally {
        Close-Progress
        $script:Busy = $false
    }
    if ($script:ShellDirty) {
        try { [ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero) } catch {}
    }
    if ($results.Count -gt 0) { Show-SummaryDialog $results }
    Load-Apps
}

# ============================================================
#  VENTANA PRINCIPAL
# ============================================================
[xml]$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desinstalador APB" Height="800" Width="1180" MinWidth="900" MinHeight="560"
        Background="#16161A" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI"
        Foreground="#ECECF0" UseLayoutRounding="True">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- CABECERA -->
    <Border Grid.Row="0" Background="#1E1E23" BorderBrush="#34343C" BorderThickness="0,0,0,1" Padding="24,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Margin="0,0,32,0" VerticalAlignment="Center">
          <TextBlock Text="Desinstalador APB" FontSize="22" FontWeight="Bold" Foreground="#ECECF0"/>
          <TextBlock Text="Desinstalacion segura con limpieza controlada" FontSize="12" Foreground="#9A9AA6" Margin="0,2,0,0"/>
        </StackPanel>
        <Grid Grid.Column="1" MaxWidth="520" HorizontalAlignment="Left" Width="520">
          <TextBox x:Name="TxtSearch" Style="{StaticResource DarkTextBox}" Height="40"/>
          <TextBlock x:Name="TxtPlaceholder" Text="Buscar por nombre o editor..." Foreground="#6B6B75"
                     VerticalAlignment="Center" HorizontalAlignment="Left" Margin="14,0,0,0"
                     IsHitTestVisible="False" FontSize="14"/>
        </Grid>
        <Button Grid.Column="2" x:Name="BtnRefresh" Content="Actualizar" Style="{StaticResource BtnSecondary}" Height="40" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <!-- BARRA DE HERRAMIENTAS -->
    <Grid Grid.Row="1" Margin="24,14,24,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="TxtCount" Foreground="#9A9AA6" FontSize="13" VerticalAlignment="Center"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="BtnSelAll" Content="Seleccionar visibles" Style="{StaticResource BtnSecondary}" Padding="14,7"/>
        <Button x:Name="BtnSelNone" Content="Limpiar seleccion" Style="{StaticResource BtnSecondary}" Padding="14,7"/>
      </StackPanel>
    </Grid>

    <!-- LISTA -->
    <Border Grid.Row="2" Margin="24,0,24,0" Background="#1E1E23" BorderBrush="#34343C" BorderThickness="1" CornerRadius="10">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="8,12,20,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="48"/>
            <ColumnDefinition Width="52"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="150"/>
            <ColumnDefinition Width="120"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="HdrName" Grid.Column="2" Text="NOMBRE" FontSize="11" FontWeight="SemiBold"
                     Foreground="#9A9AA6" Cursor="Hand"/>
          <TextBlock Grid.Column="3" Text="VERSION" FontSize="11" FontWeight="SemiBold" Foreground="#9A9AA6"/>
          <TextBlock x:Name="HdrSize" Grid.Column="4" Text="TAMANO" FontSize="11" FontWeight="SemiBold"
                     Foreground="#9A9AA6" HorizontalAlignment="Right" Margin="0,0,16,0" Cursor="Hand"/>
        </Grid>

        <ListBox x:Name="LvApps" Grid.Row="1" Background="Transparent" BorderThickness="0" Margin="8,0,8,8"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling"
                 Foreground="#ECECF0" FocusVisualStyle="{x:Null}">
          <ListBox.ItemContainerStyle>
            <Style TargetType="ListBoxItem">
              <Setter Property="Background" Value="Transparent"/>
              <Setter Property="Padding" Value="0"/>
              <Setter Property="Margin" Value="0,1"/>
              <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
              <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ListBoxItem">
                    <Border Background="{TemplateBinding Background}" CornerRadius="8">
                      <ContentPresenter/>
                    </Border>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
              <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter Property="Background" Value="#26262C"/>
                </Trigger>
                <DataTrigger Binding="{Binding IsSelected}" Value="True">
                  <Setter Property="Background" Value="#1B2F4B"/>
                </DataTrigger>
              </Style.Triggers>
            </Style>
          </ListBox.ItemContainerStyle>
          <ListBox.ItemTemplate>
            <DataTemplate>
              <Grid Background="Transparent" Height="54">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="48"/>
                  <ColumnDefinition Width="52"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="150"/>
                  <ColumnDefinition Width="120"/>
                </Grid.ColumnDefinitions>
                <CheckBox Grid.Column="0" IsChecked="{Binding IsSelected, Mode=TwoWay}"
                          HorizontalAlignment="Center" VerticalAlignment="Center" Padding="0"/>
                <Border Grid.Column="1" Width="38" Height="38" CornerRadius="9" Background="#2D2D35"
                        HorizontalAlignment="Left" VerticalAlignment="Center">
                  <Grid>
                    <TextBlock Text="{Binding Letter}" FontSize="16" FontWeight="Bold" Foreground="#6B6B75"
                               HorizontalAlignment="Center" VerticalAlignment="Center">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Setter Property="Visibility" Value="Collapsed"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding Icon}" Value="{x:Null}">
                              <Setter Property="Visibility" Value="Visible"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                    <Image Source="{Binding Icon}" Width="26" Height="26" RenderOptions.BitmapScalingMode="HighQuality"/>
                  </Grid>
                </Border>
                <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="0,0,14,0">
                  <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" Foreground="#ECECF0" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding Publisher}" FontSize="12" Foreground="#9A9AA6" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <TextBlock Grid.Column="3" Text="{Binding Version}" FontSize="13" Foreground="#B8B8C2"
                           VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
                <TextBlock Grid.Column="4" Text="{Binding SizeText}" FontSize="13" Foreground="#B8B8C2"
                           VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,16,0"/>
              </Grid>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>

        <TextBlock x:Name="TxtLoading" Grid.Row="1" Text="Cargando programas instalados..." FontSize="15"
                   Foreground="#9A9AA6" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
      </Grid>
    </Border>

    <!-- PIE -->
    <Border Grid.Row="3" Background="#1E1E23" BorderBrush="#34343C" BorderThickness="0,1,0,0" Padding="24,14" Margin="0,16,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtSelInfo" Foreground="#B8B8C2" FontSize="13" VerticalAlignment="Center"/>
        <Button x:Name="BtnUninstall" Grid.Column="1" Content="Desinstalar seleccionados"
                Style="{StaticResource BtnDanger}" Padding="24,11" FontSize="14" IsEnabled="False"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

function Update-Count {
    $n = @($script:View).Count
    $script:ui.TxtCount.Text = "{0} de {1} programas" -f $n, $script:Items.Count
}

function Update-Footer {
    $sel = @($script:Items | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) {
        $script:ui.TxtSelInfo.Text = 'Ningun programa seleccionado. Marca uno o varios para desinstalar.'
        $script:ui.BtnUninstall.Content = 'Desinstalar seleccionados'
        $script:ui.BtnUninstall.IsEnabled = $false
    }
    else {
        $mb = [double](($sel | Where-Object { $_.SizeMB -gt 0 } | Measure-Object SizeMB -Sum).Sum)
        $txt = "{0} seleccionado(s)" -f $sel.Count
        if ($mb -gt 0) { $txt += "   |   espacio aproximado a liberar: " + (Format-SizeMB $mb) }
        $script:ui.TxtSelInfo.Text = $txt
        $script:ui.BtnUninstall.Content = "Desinstalar ($($sel.Count))"
        $script:ui.BtnUninstall.IsEnabled = (-not $script:Busy)
    }
}

function Apply-Sort {
    $script:View.SortDescriptions.Clear()
    $dir = if ($script:SortDesc) { 'Descending' } else { 'Ascending' }
    $sd = New-Object System.ComponentModel.SortDescription -ArgumentList $script:SortKey, ([System.ComponentModel.ListSortDirection]$dir)
    $script:View.SortDescriptions.Add($sd)
    $arrow = if ($script:SortDesc) { ' v' } else { ' ^' }
    $script:ui.HdrName.Text = 'NOMBRE' + $(if ($script:SortKey -eq 'Name') { $arrow } else { '' })
    $script:ui.HdrSize.Text = 'TAMANO' + $(if ($script:SortKey -eq 'SizeMB') { $arrow } else { '' })
}

function Start-SizeJobs($jobs) {
    if (-not $jobs -or $jobs.Count -eq 0) { return }
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
            param($jobs, $queue)
            foreach ($j in $jobs) {
                $parts = $j -split '\|', 3
                $sum = 0
                try { $sum = (Get-ChildItem -LiteralPath $parts[2] -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch {}
                if ($sum -gt 0) {
                    $mb = [math]::Round($sum / 1MB, 1).ToString([Globalization.CultureInfo]::InvariantCulture)
                    $queue.Enqueue(('{0}|{1}|{2}' -f $parts[0], $parts[1], $mb))
                }
            }
        }).AddArgument($jobs).AddArgument($script:SizeQueue)
    $script:SizePs = $ps
    $null = $ps.BeginInvoke()
}

function Load-Apps {
    $script:ui.TxtLoading.Visibility = 'Visible'
    $script:ui.BtnRefresh.IsEnabled = $false
    Invoke-UiPump
    $script:Gen++
    $script:Items.Clear()
    $script:IconQueue.Clear()
    $jobs = New-Object System.Collections.Generic.List[string]
    $apps = Get-InstalledApps
    $i = 0
    foreach ($a in $apps) {
        $it = New-Object AppItem
        $it.Name = [string]$a.Name
        $it.Version = [string]$a.Version
        $it.Publisher = [string]$a.Publisher
        $it.Data = $a
        if ($a.EstimatedSizeKB -gt 0) { $it.SizeMB = [math]::Round($a.EstimatedSizeKB / 1024, 1) }
        elseif ($a.InstallLocation) {
            $loc = ([string]$a.InstallLocation).Trim('"').TrimEnd('\')
            if ($loc) { $jobs.Add(("{0}|{1}|{2}" -f $script:Gen, $i, $loc)) }
        }
        $script:Items.Add($it)
        $script:IconQueue.Enqueue($it)
        $i++
    }
    Apply-Sort
    Update-Count
    Update-Footer
    $script:ui.TxtLoading.Visibility = 'Collapsed'
    $script:ui.BtnRefresh.IsEnabled = $true
    Start-SizeJobs $jobs.ToArray()
    $script:Timer.Start()
}

# ---------- Estado ----------
$script:Busy = $false
$script:Prog = $null
$script:Gen = 0
$script:Search = ''
$script:SortKey = 'Name'
$script:SortDesc = $false
$script:Loaded = $false
$script:IconQueue = [System.Collections.Generic.Queue[object]]::new()
$script:SizeQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

try {
    $main = [System.Windows.Markup.XamlReader]::Parse($mainXaml.OuterXml)
    $script:MainWindow = $main
    $script:ui = @{}
    foreach ($n in 'TxtSearch', 'TxtPlaceholder', 'BtnRefresh', 'TxtCount', 'BtnSelAll', 'BtnSelNone', 'LvApps', 'HdrName', 'HdrSize', 'TxtLoading', 'TxtSelInfo', 'BtnUninstall') {
        $script:ui[$n] = $main.FindName($n)
    }

    $script:Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[AppItem]'
    $script:ui.LvApps.ItemsSource = $script:Items
    $script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $script:View.Filter = [System.Predicate[object]] {
        param($o)
        $t = $script:Search
        if ([string]::IsNullOrWhiteSpace($t)) { return $true }
        ($o.Name -and $o.Name.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($o.Publisher -and $o.Publisher.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }

    # Timer: carga iconos poco a poco y recoge tamanos calculados en segundo plano
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $script:Timer.Add_Tick({
            try {
                $n = 0
                while ($n -lt 4 -and $script:IconQueue.Count -gt 0) {
                    $it = $script:IconQueue.Dequeue()
                    $img = Get-AppIcon $it.Data
                    if ($img) { $it.Icon = $img }
                    $n++
                }
                $line = $null; $k = 0; $gotSize = $false
                while ($k -lt 50 -and $script:SizeQueue.TryDequeue([ref]$line)) {
                    $parts = $line -split '\|', 3
                    if ([int]$parts[0] -eq $script:Gen) {
                        $idx = [int]$parts[1]
                        if ($idx -lt $script:Items.Count) {
                            $script:Items[$idx].SizeMB = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
                            $gotSize = $true
                        }
                    }
                    $k++
                }
                if ($gotSize) { Update-Footer }
            }
            catch {}
        })

    [AppItem]::add_SelectionChanged([System.Action] { Update-Footer })

    # Clic en cualquier parte de la fila alterna la casilla
    $script:ui.LvApps.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            $d = $e.OriginalSource -as [System.Windows.DependencyObject]
            while ($d -and -not ($d -is [System.Windows.Controls.ListBoxItem]) -and
                -not ($d -is [System.Windows.Controls.CheckBox]) -and
                -not ($d -is [System.Windows.Controls.Primitives.ScrollBar])) {
                if ($d -is [System.Windows.Media.Visual]) { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) }
                else { $d = [System.Windows.LogicalTreeHelper]::GetParent($d) }
            }
            if ($d -is [System.Windows.Controls.ListBoxItem]) {
                $it = $d.DataContext
                if ($it) { $it.IsSelected = (-not $it.IsSelected); $e.Handled = $true }
            }
        })

    $script:ui.TxtSearch.Add_TextChanged({
            $script:Search = $script:ui.TxtSearch.Text
            $script:ui.TxtPlaceholder.Visibility = $(if ($script:ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' })
            $script:View.Refresh()
            Update-Count
        })
    $script:ui.TxtSearch.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $script:ui.TxtSearch.Text = '' } })

    $script:ui.HdrName.Add_MouseLeftButtonUp({
            if ($script:SortKey -eq 'Name') { $script:SortDesc = -not $script:SortDesc } else { $script:SortKey = 'Name'; $script:SortDesc = $false }
            Apply-Sort
        })
    $script:ui.HdrSize.Add_MouseLeftButtonUp({
            if ($script:SortKey -eq 'SizeMB') { $script:SortDesc = -not $script:SortDesc } else { $script:SortKey = 'SizeMB'; $script:SortDesc = $true }
            Apply-Sort
        })

    $script:ui.BtnSelAll.Add_Click({ foreach ($i in @($script:View)) { $i.IsSelected = $true } })
    $script:ui.BtnSelNone.Add_Click({ foreach ($i in @($script:Items)) { $i.IsSelected = $false } })
    $script:ui.BtnRefresh.Add_Click({ if (-not $script:Busy) { Load-Apps } })

    $script:ui.BtnUninstall.Add_Click({
            try { Invoke-UninstallQueue }
            catch {
                $where = "linea " + $_.InvocationInfo.ScriptLineNumber + ": " + ($_.InvocationInfo.Line + "").Trim()
                Write-Log ("ERROR: " + $_.Exception.Message + " | " + $where)
                Write-Log ($_.ScriptStackTrace + "")
                $script:Busy = $false
                Close-Progress
                Show-Message 'Ocurrio un error' ($_.Exception.Message + "`n`n" + $where) 'danger'
            }
        })

    $main.Add_Closing({ param($s, $e) if ($script:Busy) { $e.Cancel = $true } })
    $main.Add_Closed({ try { $script:Timer.Stop() } catch {} })
    $main.Add_ContentRendered({
            if (-not $script:Loaded) {
                $script:Loaded = $true
                try { Load-Apps }
                catch { Write-Log ("ERROR al cargar: " + $_.Exception.Message); Show-Message 'Error al cargar' $_.Exception.Message 'danger' }
            }
        })

    Write-Log 'Inicio'
    [void]$main.ShowDialog()
    Write-Log 'Fin'
}
catch {
    Write-Log ("ERROR FATAL: " + $_.Exception.Message)
    [System.Windows.MessageBox]::Show("Error: " + $_.Exception.Message + "`n`nLog: " + $script:LogFile, 'Desinstalador APB') | Out-Null
}