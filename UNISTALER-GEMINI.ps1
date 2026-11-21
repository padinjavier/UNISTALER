<#
  Desinstalador Seguro Iterativo con UI (WPF) y Limpieza Controlada.
  Ejecutable via:
    irm https://raw.githubusercontent.com/padinjavier/UNISTALER/main/UNISTALER-GUI.ps1 | iex
  Modo simulacion:
    $env:UNISTALER_WHATIF=1; irm ... | iex
#>

# ---------- Auto-elevar a Administrador ----------
$WhatIf = ($env:UNISTALER_WHATIF -eq '1')
$ScriptUrl = 'https://raw.githubusercontent.com/padinjavier/UNISTALER/main/UNISTALER-GUI.ps1'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIf) {
    Add-Type -AssemblyName PresentationFramework
    $ans = [System.Windows.MessageBox]::Show(
        "Se recomiendan permisos de Administrador para desinstalar y limpiar carpetas residuales.`n`n¿Relanzar como Administrador?",
        "Permisos requeridos",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        try {
            $tmp = Join-Path $env:TEMP ("UNISTALER_{0}.ps1" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Invoke-WebRequest -Uri $ScriptUrl -OutFile $tmp -UseBasicParsing
            Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$tmp`""
            )
            return
        }
        catch {
            [System.Windows.MessageBox]::Show("No se pudo relanzar como Admin: $($_.Exception.Message)", "Aviso") | Out-Null
        }
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

$LogFile = Join-Path $env:TEMP ("Desinstalar-Seguro-UI_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {}

# ============================================================
#  PROTECCION DE DATOS DE USUARIO
# ============================================================
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
    if ([string]::IsNullOrWhiteSpace($path)) { return $true }
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

    foreach ($uf in (Get-ProtectedUserFolders)) {
        if ($full -eq $uf -or $full -like ($uf + '\*')) { return $true }
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
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $len = (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue).Length
        return [math]::Round((($len / 1MB)), 2)
    }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if (-not $sum) { return 0 }
    [math]::Round(($sum / 1MB), 1)
}

# ============================================================
#  ICONOS Y APPS INSTALADAS
# ============================================================
function Get-ExeFromString([string]$s) {
    if (-not $s) { return $null }
    if ($s -match '^\s*"?([A-Za-z]:\\[^",]*?\.(?:exe|ico|dll))') { return $matches[1] }
    return $null
}

function Convert-IconToBitmapSource([System.Drawing.Icon]$icon) {
    if (-not $icon) { return $null }
    try {
        $bmp = $icon.ToBitmap()
        $hBitmap = $bmp.GetHbitmap()
        try {
            $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
                $hBitmap,
                [IntPtr]::Zero,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
            )
            $src.Freeze()
            return $src
        }
        finally {
            # Libera HBITMAP nativo
            $null = [System.Runtime.InteropServices.Marshal]::Release($hBitmap) 2>$null
            $bmp.Dispose()
            $icon.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Get-AppIconImage($displayIcon, $installLocation) {
    $candidates = @()
    $fromIcon = Get-ExeFromString $displayIcon
    if ($fromIcon) { $candidates += $fromIcon }

    if ($installLocation) {
        $cleanLoc = $installLocation.Trim('"').TrimEnd('\')
        if (Test-Path -LiteralPath $cleanLoc) {
            $exes = Get-ChildItem -LiteralPath $cleanLoc -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'unins|setup|update|crash' } |
                Select-Object -First 1
            if ($exes) { $candidates += $exes.FullName }
        }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            try {
                $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($c)
                $img = Convert-IconToBitmapSource $ico
                if ($img) { return $img }
            }
            catch {}
        }
    }

    # Icono por defecto de aplicacion desde shell32.dll
    try {
        $shell32 = Join-Path $env:windir 'System32\shell32.dll'
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($shell32)
        return (Convert-IconToBitmapSource $ico)
    }
    catch {
        return $null
    }
}

function Get-InstalledApps {
    $keys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKLM-64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKLM-32' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'HKCU' }
    )
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $seen = @{}

    foreach ($k in $keys) {
        if (-not (Test-Path $k.Path)) { continue }
        foreach ($item in Get-ChildItem $k.Path -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            if ($p.SystemComponent -eq 1) { continue }
            if ($p.ParentKeyName) { continue }
            if ($p.ReleaseType -in 'Update', 'Hotfix', 'Security Update') { continue }
            if ($p.DisplayName -match 'KB\d{6,}') { continue }

            $dedupKey = "$($p.DisplayName)|$($p.DisplayVersion)|$($p.InstallLocation)"
            if ($seen.ContainsKey($dedupKey)) { continue }
            $seen[$dedupKey] = $true

            $cleanLoc = if ($p.InstallLocation) { $p.InstallLocation.Trim('"').TrimEnd('\') } else { '' }
            $iconImg = Get-AppIconImage $p.DisplayIcon $cleanLoc

            $list.Add([pscustomobject]@{
                IsSelected           = $false
                Icon                 = $iconImg
                Name                 = $p.DisplayName
                Version              = $p.DisplayVersion
                Publisher            = $p.Publisher
                InstallLocation      = if ($cleanLoc) { $cleanLoc } else { '(No especificada)' }
                RawInstallLocation   = $cleanLoc
                DisplayIcon          = $p.DisplayIcon
                UninstallString      = $p.UninstallString
                QuietUninstallString = $p.QuietUninstallString
                WindowsInstaller     = $p.WindowsInstaller
                Key                  = $item.PSChildName
                PSPath               = $item.PSPath
                Origen               = $k.Origen
            })
        }
    }

    @($list | Sort-Object Name)
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

function Get-AppAssociatedPaths($app) {
    $result = New-Object System.Collections.Generic.List[object]
    $added = @{}

    function Add-PathEntry([string]$targetPath, [string]$tipo, [bool]$isFile = $false) {
        if ([string]::IsNullOrWhiteSpace($targetPath)) { return }
        try { $full = [IO.Path]::GetFullPath($targetPath).TrimEnd('\') } catch { return }
        if ($added.ContainsKey($full.ToLower())) { return }
        if (-not (Test-Path -LiteralPath $full)) { return }
        $added[$full.ToLower()] = $true
        $result.Add([pscustomobject]@{
            Path   = $full
            Tipo   = $tipo
            SizeMB = (Get-FolderSizeMB $full)
            IsFile = $isFile
            Exists = $true
        })
    }

    if ($app.RawInstallLocation) {
        Add-PathEntry $app.RawInstallLocation 'Instalacion' $false
    }

    foreach ($s in @($app.DisplayIcon, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)') {
                Add-PathEntry $dir 'Ejecutable' $false
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
                ForEach-Object { Add-PathEntry $_.FullName 'Programa' $false }
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
                Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$tok*" } |
                    ForEach-Object {
                        if (-not (Test-ProtectedPath $_.FullName)) {
                            Add-PathEntry $_.FullName $r.Kind $false
                        }
                    }
            }
        }

        $cachePatterns = @('*cache*', '*temp*', '*tmp*', '*log*')
        foreach ($r in $dataRoots) {
            foreach ($tok in $tokens) {
                foreach ($pat in $cachePatterns) {
                    Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*$tok*" -and $_.Name -like $pat } |
                        ForEach-Object {
                            if (-not (Test-ProtectedPath $_.FullName)) {
                                Add-PathEntry $_.FullName 'Cache' $false
                            }
                        }
                }
            }
        }

        $shortcutRoots = @(
            [Environment]::GetFolderPath('CommonDesktopDirectory'),
            [Environment]::GetFolderPath('Desktop'),
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
        ) | Where-Object { $_ -and (Test-Path $_) }

        foreach ($sRoot in $shortcutRoots) {
            foreach ($tok in $tokens) {
                Get-ChildItem -LiteralPath $sRoot -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$tok*" } |
                    ForEach-Object { Add-PathEntry $_.FullName 'Acceso directo' $true }
            }
        }
    }

    @($result | Sort-Object Path)
}

# ============================================================
#  DESINSTALACION Y BORRADO SEGURO
# ============================================================
function Stop-ProcessesInFolder([string]$folder) {
    if ($WhatIf) { return }
    $prefix = $folder.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Invoke-SingleUninstall($app, [int]$TimeoutMin = 15) {
    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')

    if ($isMsi) {
        $exe = 'msiexec.exe'
        $argLine = "/x $($app.Key) /qn /norestart"
    }
    elseif ($app.QuietUninstallString) {
        $exe = 'cmd.exe'
        $argLine = "/c $($app.QuietUninstallString)"
    }
    elseif ($app.UninstallString) {
        $exe = 'cmd.exe'
        $argLine = "/c $($app.UninstallString)"
    }
    else {
        return @{ Success = $false; Message = "Este programa no tiene desinstalador registrado." }
    }

    if ($WhatIf) {
        Start-Sleep -Milliseconds 600
        return @{ Success = $true; Message = "[WhatIf] Simulado: $exe $argLine" }
    }

    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Normal
        if (-not $proc.WaitForExit($TimeoutMin * 60 * 1000)) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            return @{ Success = $false; Message = "Tiempo agotado ($TimeoutMin min) al desinstalar." }
        }
        return @{ Success = $true; Message = "Desinstalador finalizo con codigo: $($proc.ExitCode)" }
    }
    catch {
        return @{ Success = $false; Message = "Error al ejecutar desinstalador: $($_.Exception.Message)" }
    }
}

function Remove-ResidualEntry($entry) {
    $target = $entry.Path
    if (-not (Test-Path -LiteralPath $target)) { return @{ Deleted = $true; Reason = "Ya no existe" } }

    if ($entry.IsFile) {
        $ext = [IO.Path]::GetExtension($target).ToLower()
        if ($script:ProtectedExtensions -contains $ext) {
            return @{ Deleted = $false; Reason = "Archivo de usuario protegido" }
        }
        if ($WhatIf) { return @{ Deleted = $true; Reason = "[WhatIf] Eliminado" } }
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $target) {
            & icacls.exe $target /setowner "*S-1-5-32-544" /c /q | Out-Null
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
        return @{ Deleted = (-not (Test-Path -LiteralPath $target)); Reason = if (Test-Path -LiteralPath $target) { "Bloqueado o en uso" } else { "Eliminado" } }
    }

    if (Test-ProtectedPath $target) {
        return @{ Deleted = $false; Reason = "Ruta protegida del sistema o usuario" }
    }

    if (Test-FolderContainsUserFiles $target) {
        $ans = [System.Windows.MessageBox]::Show(
            "La carpeta contiene archivos de usuario (.docx, .xlsx, .pdf, .jpg, etc.):`n`n$target`n`n¿Desea borrarla de todas formas?",
            "Archivos de usuario detectados",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) {
            return @{ Deleted = $false; Reason = "Omitida por contener archivos de usuario" }
        }
    }

    if ($WhatIf) { return @{ Deleted = $true; Reason = "[WhatIf] Eliminada" } }

    Stop-ProcessesInFolder $target
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $target) {
        & icacls.exe $target /setowner "*S-1-5-32-544" /t /c /q | Out-Null
        & icacls.exe $target /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q | Out-Null
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
    return @{ Deleted = (-not (Test-Path -LiteralPath $target)); Reason = if (Test-Path -LiteralPath $target) { "Quedaron elementos en uso o bloqueados" } else { "Eliminada" } }
}

# ============================================================
#  INTERFAZ GRAFICA WPF
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UNISTALER Iterativo con Limpieza Controlada"
        Height="680" Width="980"
        WindowStartupLocation="CenterScreen"
        Background="#F4F6F9">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Encabezado -->
        <Border Grid.Row="0" Background="White" CornerRadius="8" Padding="14" Margin="0,0,0,12" BorderBrush="#DCE2EA" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock x:Name="TxtHeaderTitle" Text="Paso 1: Selecciona las aplicaciones a desinstalar" FontSize="18" FontWeight="Bold" Foreground="#1E293B"/>
                    <TextBlock x:Name="TxtHeaderSubtitle" Text="Marca una o varias aplicaciones. Se procesarán una por una y se validarán sus carpetas al finalizar." FontSize="12" Foreground="#64748B" Margin="0,4,0,0"/>
                </StackPanel>
                <Border Grid.Column="1" x:Name="BadgeWhatIf" Background="#FEF3C7" CornerRadius="6" Padding="10,4" VerticalAlignment="Center" Visibility="Collapsed">
                    <TextBlock Text="MODO SIMULACIÓN (WHATIF)" FontWeight="Bold" Foreground="#92400E" FontSize="11"/>
                </Border>
            </Grid>
        </Border>

        <!-- VISTA 1: SELECCION MULTIPLE -->
        <Grid x:Name="ViewSelection" Grid.Row="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <DockPanel Grid.Row="0" Margin="0,0,0,10">
                <TextBlock Text="Buscar:" VerticalAlignment="Center" Margin="0,0,8,0" FontWeight="SemiBold" Foreground="#334155"/>
                <TextBox x:Name="TxtFilter" Width="280" Height="30" VerticalContentAlignment="Center" Padding="8,0" BorderBrush="#CBD5E1"/>
                <Button x:Name="BtnClearFilter" Content="Limpiar" Margin="8,0,0,0" Padding="12,4" Background="#E2E8F0" BorderThickness="0"/>
                <TextBlock x:Name="TxtSelectedCount" Text="Seleccionadas: 0" DockPanel.Dock="Right" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="#0F172A"/>
            </DockPanel>

            <DataGrid x:Name="GridApps" Grid.Row="1"
                      AutoGenerateColumns="False"
                      CanUserAddRows="False"
                      CanUserDeleteRows="False"
                      IsReadOnly="False"
                      SelectionMode="Extended"
                      GridLinesVisibility="Horizontal"
                      HorizontalGridLinesBrush="#E2E8F0"
                      Background="White"
                      BorderBrush="#DCE2EA"
                      BorderThickness="1"
                      RowHeight="42">
                <DataGrid.Columns>
                    <DataGridCheckBoxColumn Binding="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}" Width="45"/>
                    <DataGridTemplateColumn Header="Icono" Width="55" IsReadOnly="True">
                        <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                                <Image Source="{Binding Icon}" Width="24" Height="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                    <DataGridTextColumn Header="Aplicación" Binding="{Binding Name}" Width="260" IsReadOnly="True" FontWeight="SemiBold"/>
                    <DataGridTextColumn Header="Versión" Binding="{Binding Version}" Width="110" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Fabricante" Binding="{Binding Publisher}" Width="170" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Ruta de instalación" Binding="{Binding InstallLocation}" Width="*" IsReadOnly="True"/>
                </DataGrid.Columns>
            </DataGrid>
        </Grid>

        <!-- VISTA 2: EJECUCION ITERATIVA POR APP -->
        <Border x:Name="ViewQueue" Grid.Row="1" Background="White" CornerRadius="8" Padding="18" BorderBrush="#DCE2EA" BorderThickness="1" Visibility="Collapsed">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Datos de la app actual -->
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Image x:Name="ImgCurrentApp" Width="48" Height="48" Margin="0,0,14,0" VerticalAlignment="Top"/>
                    <StackPanel Grid.Column="1">
                        <TextBlock x:Name="TxtCurrentAppName" Text="APP NAME" FontSize="20" FontWeight="Bold" Foreground="#0F172A"/>
                        <TextBlock x:Name="TxtCurrentAppMeta" Text="Versión • Fabricante" FontSize="12" Foreground="#64748B" Margin="0,2,0,0"/>
                    </StackPanel>
                    <TextBlock x:Name="TxtQueueProgress" Grid.Column="2" Text="App 1 de 1" FontSize="13" FontWeight="SemiBold" Foreground="#2563EB" VerticalAlignment="Top"/>
                </Grid>

                <Separator Grid.Row="1" Margin="0,14,0,14"/>

                <!-- Lista de rutas asociadas + estado de validacion -->
                <Grid Grid.Row="2">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" Text="RUTAS ASOCIADAS DETECTADAS:" FontSize="13" FontWeight="Bold" Foreground="#334155" Margin="0,0,0,8"/>

                    <ListView x:Name="ListAppPaths" Grid.Row="1" BorderBrush="#E2E8F0" BorderThickness="1">
                        <ListView.View>
                            <GridView>
                                <GridViewColumn Header="Tipo" DisplayMemberBinding="{Binding Tipo}" Width="140"/>
                                <GridViewColumn Header="Ruta" DisplayMemberBinding="{Binding Path}" Width="560"/>
                                <GridViewColumn Header="Tamaño (MB)" DisplayMemberBinding="{Binding SizeMB}" Width="100"/>
                                <GridViewColumn Header="Estado" DisplayMemberBinding="{Binding StatusText}" Width="110"/>
                            </GridView>
                        </ListView.View>
                    </ListView>

                    <!-- Panel de validacion post-desinstalacion -->
                    <Border x:Name="PanelValidation" Grid.Row="2" Background="#F8FAFC" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,12,0,0" Visibility="Collapsed">
                        <StackPanel>
                            <TextBlock x:Name="TxtValidationMessage" Text="" FontSize="13" FontWeight="SemiBold" TextWrapping="Wrap" Foreground="#0F172A"/>
                            <StackPanel x:Name="PanelResidualActions" Orientation="Horizontal" Margin="0,10,0,0" Visibility="Collapsed">
                                <Button x:Name="BtnAcceptResidual" Content="Aceptar (Borrar carpetas residuales)" Background="#DC2626" Foreground="White" FontWeight="SemiBold" Padding="14,7" Margin="0,0,10,0" BorderThickness="0"/>
                                <Button x:Name="BtnRejectResidual" Content="No (Conservar y pasar a la siguiente)" Background="#64748B" Foreground="White" FontWeight="SemiBold" Padding="14,7" BorderThickness="0"/>
                            </StackPanel>
                            <Button x:Name="BtnNextApp" Content="Siguiente aplicación →" Background="#2563EB" Foreground="White" FontWeight="SemiBold" Padding="14,7" Margin="0,10,0,0" HorizontalAlignment="Left" BorderThickness="0" Visibility="Collapsed"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <!-- Boton principal de desinstalar -->
                <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                    <Button x:Name="BtnSkipApp" Content="Omitir esta app" Background="#E2E8F0" Foreground="#1E293B" Padding="14,9" Margin="0,0,10,0" BorderThickness="0"/>
                    <Button x:Name="BtnUninstallCurrent" Content="Desinstalar" Background="#16A34A" Foreground="White" FontWeight="Bold" FontSize="14" Padding="22,9" BorderThickness="0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Barra inferior -->
        <DockPanel Grid.Row="2" Margin="0,12,0,0">
            <TextBlock x:Name="TxtStatusBar" Text="Listo" VerticalAlignment="Center" Foreground="#475569"/>
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
                <Button x:Name="BtnBackToSelection" Content="← Volver a selección" Padding="14,8" Margin="0,0,10,0" Visibility="Collapsed"/>
                <Button x:Name="BtnStartQueue" Content="Continuar con seleccionadas →" Background="#2563EB" Foreground="White" FontWeight="Bold" Padding="16,8" BorderThickness="0"/>
            </StackPanel>
        </DockPanel>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Controles
$TxtHeaderTitle      = $window.FindName('TxtHeaderTitle')
$TxtHeaderSubtitle   = $window.FindName('TxtHeaderSubtitle')
$BadgeWhatIf         = $window.FindName('BadgeWhatIf')
$ViewSelection       = $window.FindName('ViewSelection')
$TxtFilter           = $window.FindName('TxtFilter')
$BtnClearFilter      = $window.FindName('BtnClearFilter')
$TxtSelectedCount    = $window.FindName('TxtSelectedCount')
$GridApps            = $window.FindName('GridApps')

$ViewQueue           = $window.FindName('ViewQueue')
$ImgCurrentApp       = $window.FindName('ImgCurrentApp')
$TxtCurrentAppName   = $window.FindName('TxtCurrentAppName')
$TxtCurrentAppMeta   = $window.FindName('TxtCurrentAppMeta')
$TxtQueueProgress    = $window.FindName('TxtQueueProgress')
$ListAppPaths        = $window.FindName('ListAppPaths')
$PanelValidation     = $window.FindName('PanelValidation')
$TxtValidationMessage= $window.FindName('TxtValidationMessage')
$PanelResidualActions= $window.FindName('PanelResidualActions')
$BtnAcceptResidual   = $window.FindName('BtnAcceptResidual')
$BtnRejectResidual   = $window.FindName('BtnRejectResidual')
$BtnNextApp          = $window.FindName('BtnNextApp')
$BtnSkipApp          = $window.FindName('BtnSkipApp')
$BtnUninstallCurrent = $window.FindName('BtnUninstallCurrent')

$TxtStatusBar        = $window.FindName('TxtStatusBar')
$BtnBackToSelection  = $window.FindName('BtnBackToSelection')
$BtnStartQueue       = $window.FindName('BtnStartQueue')

if ($WhatIf) { $BadgeWhatIf.Visibility = 'Visible' }

# Estado de la sesion
$script:AllApps = Get-InstalledApps
$script:Queue = @()
$script:QueueIndex = 0
$script:CurrentPaths = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:RemainingResiduals = @()

function Update-SelectedCount {
    $cnt = @($script:AllApps | Where-Object { $_.IsSelected }).Count
    $TxtSelectedCount.Text = "Seleccionadas: $cnt"
}

function Apply-AppFilter {
    $q = $TxtFilter.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($q)) {
        $GridApps.ItemsSource = $script:AllApps
    }
    else {
        $GridApps.ItemsSource = @($script:AllApps | Where-Object {
            $_.Name -like "*$q*" -or $_.Publisher -like "*$q*" -or $_.InstallLocation -like "*$q*"
        })
    }
    Update-SelectedCount
}

$GridApps.Add_CellEditEnding({
    $window.Dispatcher.BeginInvoke([Action]{ Update-SelectedCount }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
})
$TxtFilter.Add_TextChanged({ Apply-AppFilter })
$BtnClearFilter.Add_Click({ $TxtFilter.Text = ''; Apply-AppFilter })

function Move-ToNextApp {
    $script:QueueIndex++
    if ($script:QueueIndex -ge $script:Queue.Count) {
        [System.Windows.MessageBox]::Show(
            "Se ha completado el proceso para todas las aplicaciones seleccionadas.`n`nLog guardado en:`n$LogFile",
            "Proceso finalizado",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null

        # Volver a Paso 1 y refrescar lista de apps
        $script:AllApps = Get-InstalledApps
        $TxtFilter.Text = ''
        Apply-AppFilter
        $ViewQueue.Visibility = 'Collapsed'
        $ViewSelection.Visibility = 'Visible'
        $BtnStartQueue.Visibility = 'Visible'
        $BtnBackToSelection.Visibility = 'Collapsed'
        $TxtHeaderTitle.Text = "Paso 1: Selecciona las aplicaciones a desinstalar"
        $TxtHeaderSubtitle.Text = "Lista actualizada tras la desinstalación."
        $TxtStatusBar.Text = "Listo"
        return
    }

    Load-QueueItem $script:Queue[$script:QueueIndex]
}

function Load-QueueItem($app) {
    $total = $script:Queue.Count
    $pos = $script:QueueIndex + 1

    $TxtHeaderTitle.Text = "Paso 2: Desinstalación y validación ($pos de $total)"
    $TxtHeaderSubtitle.Text = "Revisa las rutas asociadas y pulsa 'Desinstalar' para iniciar el proceso."
    $TxtQueueProgress.Text = "App $pos de $total"

    $ImgCurrentApp.Source = $app.Icon
    $TxtCurrentAppName.Text = "$($app.Name) $($app.Version)".Trim()
    $pub = if ($app.Publisher) { $app.Publisher } else { "Fabricante desconocido" }
    $TxtCurrentAppMeta.Text = "$pub  •  Origen: $($app.Origen)"

    $script:CurrentPaths.Clear()
    $script:RemainingResiduals = @()
    foreach ($p in (Get-AppAssociatedPaths $app)) {
        $script:CurrentPaths.Add([pscustomobject]@{
            Path       = $p.Path
            Tipo       = $p.Tipo
            SizeMB     = $p.SizeMB
            IsFile     = $p.IsFile
            StatusText = "Pendiente"
        })
    }
    $ListAppPaths.ItemsSource = $script:CurrentPaths

    $PanelValidation.Visibility = 'Collapsed'
    $PanelResidualActions.Visibility = 'Collapsed'
    $BtnNextApp.Visibility = 'Collapsed'
    $BtnUninstallCurrent.IsEnabled = $true
    $BtnSkipApp.IsEnabled = $true
    $TxtStatusBar.Text = "Esperando acción para: $($app.Name)"
}

$BtnStartQueue.Add_Click({
    $selected = @($script:AllApps | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Selecciona al menos una aplicación.", "Sin selección") | Out-Null
        return
    }

    $script:Queue = $selected
    $script:QueueIndex = 0
    $ViewSelection.Visibility = 'Collapsed'
    $ViewQueue.Visibility = 'Visible'
    $BtnStartQueue.Visibility = 'Collapsed'
    $BtnBackToSelection.Visibility = 'Visible'

    Load-QueueItem $script:Queue[0]
})

$BtnBackToSelection.Add_Click({
    $ViewQueue.Visibility = 'Collapsed'
    $ViewSelection.Visibility = 'Visible'
    $BtnStartQueue.Visibility = 'Visible'
    $BtnBackToSelection.Visibility = 'Collapsed'
    $TxtHeaderTitle.Text = "Paso 1: Selecciona las aplicaciones a desinstalar"
    $TxtHeaderSubtitle.Text = "Marca una o varias aplicaciones. Se procesarán una por una."
    $TxtStatusBar.Text = "Listo"
})

$BtnSkipApp.Add_Click({
    Move-ToNextApp
})

$BtnUninstallCurrent.Add_Click({
    $app = $script:Queue[$script:QueueIndex]
    $BtnUninstallCurrent.IsEnabled = $false
    $BtnSkipApp.IsEnabled = $false
    $TxtStatusBar.Text = "Desinstalando $($app.Name)..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $res = Invoke-SingleUninstall $app
    Start-Sleep -Seconds 2

    # Validar si las carpetas/rutas asociadas se eliminaron en automatico
    $stillExisting = New-Object System.Collections.Generic.List[object]
    $updatedList = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    foreach ($entry in $script:CurrentPaths) {
        $existsNow = Test-Path -LiteralPath $entry.Path
        $status = if ($existsNow) { "Aún existe" } else { "Eliminada" }
        $updatedList.Add([pscustomobject]@{
            Path       = $entry.Path
            Tipo       = $entry.Tipo
            SizeMB     = $entry.SizeMB
            IsFile     = $entry.IsFile
            StatusText = $status
        })
        if ($existsNow) {
            $stillExisting.Add($entry)
        }
    }

    $script:CurrentPaths = $updatedList
    $ListAppPaths.ItemsSource = $script:CurrentPaths
    $PanelValidation.Visibility = 'Visible'

    if ($stillExisting.Count -eq 0) {
        $TxtValidationMessage.Foreground = [System.Windows.Media.Brushes]::DarkGreen
        $TxtValidationMessage.Text = "$($res.Message)`nSe borraron todas las carpetas asociadas en automático. Pasando a la siguiente aplicación..."
        $PanelResidualActions.Visibility = 'Collapsed'
        $BtnNextApp.Visibility = 'Collapsed'
        $TxtStatusBar.Text = "Carpetas eliminadas en automático para $($app.Name)"
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        Start-Sleep -Seconds 2
        Move-ToNextApp
    }
    else {
        $script:RemainingResiduals = @($stillExisting)
        $TxtValidationMessage.Foreground = [System.Windows.Media.Brushes]::DarkRed
        $TxtValidationMessage.Text = "$($res.Message)`nQuedaron $($stillExisting.Count) carpeta(s)/ruta(s) residual(es). ¿Quiere borrar las carpetas residuales?"
        $PanelResidualActions.Visibility = 'Visible'
        $BtnNextApp.Visibility = 'Collapsed'
        $TxtStatusBar.Text = "Carpetas residuales detectadas para $($app.Name)"
    }
})

$BtnAcceptResidual.Add_Click({
    $PanelResidualActions.Visibility = 'Collapsed'
    $TxtStatusBar.Text = "Borrando carpetas residuales..."

    $updatedList = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($entry in $script:CurrentPaths) {
        if (Test-Path -LiteralPath $entry.Path) {
            $delRes = Remove-ResidualEntry $entry
            $st = if ($delRes.Deleted) { "Borrada" } else { $delRes.Reason }
            $updatedList.Add([pscustomobject]@{
                Path       = $entry.Path
                Tipo       = $entry.Tipo
                SizeMB     = $entry.SizeMB
                IsFile     = $entry.IsFile
                StatusText = $st
            })
        }
        else {
            $updatedList.Add([pscustomobject]@{
                Path       = $entry.Path
                Tipo       = $entry.Tipo
                SizeMB     = $entry.SizeMB
                IsFile     = $entry.IsFile
                StatusText = "Eliminada"
            })
        }
    }

    $script:CurrentPaths = $updatedList
    $ListAppPaths.ItemsSource = $script:CurrentPaths
    $TxtValidationMessage.Foreground = [System.Windows.Media.Brushes]::DarkGreen
    $TxtValidationMessage.Text = "Limpieza de carpetas residuales procesada. Pulsa 'Siguiente aplicación' para continuar."
    $BtnNextApp.Visibility = 'Visible'
    $TxtStatusBar.Text = "Limpieza residual finalizada"
})

$BtnRejectResidual.Add_Click({
    $PanelResidualActions.Visibility = 'Collapsed'
    $TxtValidationMessage.Foreground = [System.Windows.Media.Brushes]::SlateGray
    $TxtValidationMessage.Text = "Carpetas residuales conservadas. Pasando a la siguiente aplicación..."
    $TxtStatusBar.Text = "Carpetas residuales conservadas"
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    Start-Sleep -Seconds 1
    Move-ToNextApp
})

$BtnNextApp.Add_Click({
    Move-ToNextApp
})

Apply-AppFilter
$TxtStatusBar.Text = "Cargadas $($script:AllApps.Count) aplicaciones"
$null = $window.ShowDialog()
try { Stop-Transcript | Out-Null } catch {}