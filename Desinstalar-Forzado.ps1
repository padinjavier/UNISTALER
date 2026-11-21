<#
  Desinstalador Gráfico Seguro (WPF).
  - Muestra apps instaladas con sus iconos.
  - Permite seleccionar varias con checkboxes.
  - Desinstala y limpia SOLO archivos/carpetas/accesos directos.
  - NO toca Registro, Firewall ni Variables de Entorno (solo lectura para listar).
#>
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- Auto-elevar a Administrador ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ============================================================
#  LÓGICA DE DATOS (Reutilizada y adaptada de tu script)
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
            
            # Intentar obtener el icono
            $iconPath = $null
            if ($p.DisplayIcon) {
                if ($p.DisplayIcon -match '^"([^"]+)"') { $iconPath = $matches[1] }
                elseif ($p.DisplayIcon -match '^([^,]+)') { $iconPath = $matches[1] }
            }
            if (-not $iconPath -and $p.InstallLocation) {
                $exe = Get-ChildItem -LiteralPath $p.InstallLocation -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) { $iconPath = $exe.FullName }
            }

            [pscustomobject]@{
                Name                 = $p.DisplayName
                Version              = $p.DisplayVersion
                Publisher            = $p.Publisher
                InstallLocation      = $p.InstallLocation
                IconPath             = $iconPath
                UninstallString      = $p.UninstallString
                QuietUninstallString = $p.QuietUninstallString
                WindowsInstaller     = $p.WindowsInstaller
                Key                  = $item.PSChildName
                PSPath               = $item.PSPath
                Origen               = $k.Origen
                IsChecked            = $false
                IconImage            = $null
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

function Get-CandidateFolders($app) {
    $c = New-Object System.Collections.Generic.List[string]
    if ($app.InstallLocation) { $c.Add($app.InstallLocation.Trim('"').TrimEnd('\')) }
    foreach ($s in @($app.IconPath, $app.UninstallString, $app.QuietUninstallString)) {
        $exe = Get-ExeFromString $s
        if ($exe) {
            $dir = Split-Path $exe -Parent
            if ($dir -and $dir -notmatch '\\Windows(\\|$)') { $c.Add($dir) }
        }
    }
    $words = ($app.Name -split '\s+') | Where-Object { $_ -match '^[A-Za-z]{2,}' } | Select-Object -First 2
    if ($words) {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
            (Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ -and (Test-Path $_) }
        $pattern = '*' + ($words -join ' ') + '*'
        foreach ($r in $roots) {
            Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern } | ForEach-Object { $c.Add($_.FullName) }
        }
    }
    $c | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and -not (Test-Protected $_) } |
    ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique
}

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
                        Path = $c.FullName; Kind = $r.Kind
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
    $roots = @(
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        foreach ($tok in $tokens) {
            Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$tok*" } | ForEach-Object { $result.Add($_.FullName) }
        }
    }
    $result | Sort-Object -Unique
}

# ============================================================
#  FUNCIONES DE BORRADO SEGURO (Solo Archivos)
# ============================================================
function Stop-ProcessesInFolder([string]$folder) {
    $prefix = $folder.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Remove-FolderForced([string]$folder) {
    if (Test-Protected $folder) { return }
    Stop-ProcessesInFolder $folder
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $folder) {
        & icacls.exe $folder /setowner "*S-1-5-32-544" /t /c /q | Out-Null
        & icacls.exe $folder /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q | Out-Null
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-FileSafe([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

# ============================================================
#  LÓGICA DE DESINSTALACIÓN
# ============================================================
function Invoke-AppUninstall($app, [System.Windows.Controls.TextBox]$LogBox) {
    $LogBox.AppendText("=== Procesando: $($app.Name) ===`n")
    
    # 1) Desinstalación normal
    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')
    $exe = $null; $argLine = $null

    if ($isMsi) { $exe = 'msiexec.exe'; $argLine = "/x $($app.Key) /qn /norestart" }
    elseif ($app.QuietUninstallString) { $exe = 'cmd.exe'; $argLine = "/c $($app.QuietUninstallString)" }
    elseif ($app.UninstallString) { $exe = 'cmd.exe'; $argLine = "/c $($app.UninstallString)" }

    if ($exe) {
        $LogBox.AppendText("   Ejecutando desinstalador oficial...`n")
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit(300000)) { $proc.Kill() }
        } catch { $LogBox.AppendText("   Error en desinstalador: $($_.Exception.Message)`n") }
    }

    # 2) Limpieza de archivos (forzada)
    $LogBox.AppendText("   Buscando restos de archivos...`n")
    $appFolders = @(Get-CandidateFolders $app)
    $userFolders = @(Get-LeftoverUserFolders $app)
    $shortcuts = @(Get-Shortcuts $app)

    foreach ($f in $appFolders) {
        $LogBox.AppendText("   Borrando carpeta: $f`n")
        Remove-FolderForced $f
    }
    foreach ($f in $userFolders) {
        $LogBox.AppendText("   Borrando datos: $($f.Path)`n")
        Remove-FolderForced $f.Path
    }
    foreach ($s in $shortcuts) {
        $LogBox.AppendText("   Borrando acceso: $s`n")
        Remove-FileSafe $s
    }

    $LogBox.AppendText("   [OK] Terminado: $($app.Name)`n`n")
    $LogBox.ScrollToEnd()
}

# ============================================================
#  INTERFAZ GRÁFICA (WPF)
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desinstalador Seguro APB" Height="700" Width="950"
        WindowStartupLocation="CenterScreen" Background="#1E1E1E">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#252526" Padding="15">
            <StackPanel>
                <TextBlock Text="Desinstalador Seguro" FontSize="24" FontWeight="Bold" Foreground="White"/>
                <TextBlock Text="Selecciona las aplicaciones que deseas eliminar (Solo borra archivos, NO toca Registro ni Firewall)." Foreground="#AAAAAA" Margin="0,5,0,0"/>
            </StackPanel>
        </Border>

        <!-- Lista de Apps -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="10">
            <ItemsControl x:Name="AppsList">
                <ItemsControl.ItemTemplate>
                    <DataTemplate>
                        <Border Background="#2D2D30" CornerRadius="5" Margin="0,5" Padding="10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                
                                <CheckBox Grid.Column="0" IsChecked="{Binding IsChecked}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <Image Grid.Column="1" Source="{Binding IconImage}" Width="32" Height="32" Margin="0,0,15,0"/>
                                
                                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                                    <TextBlock Text="{Binding Name}" FontWeight="Bold" Foreground="White" FontSize="14"/>
                                    <TextBlock Text="{Binding Publisher}" Foreground="#AAAAAA" FontSize="12"/>
                                    <TextBlock Text="{Binding Version}" Foreground="#777777" FontSize="11"/>
                                </StackPanel>

                                <TextBlock Grid.Column="3" Text="{Binding InstallLocation}" Foreground="#555555" FontSize="10" VerticalAlignment="Center" MaxWidth="200" TextTrimming="CharacterEllipsis"/>
                            </Grid>
                        </Border>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>
        </ScrollViewer>

        <!-- Footer / Log -->
        <Border Grid.Row="2" Background="#252526" Padding="10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="100"/>
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,0,10">
                    <Button x:Name="BtnRefresh" Content="Refrescar Lista" Width="120" Margin="0,0,10,0" Background="#3E3E42" Foreground="White"/>
                    <Button x:Name="BtnUninstall" Content="Desinstalar Seleccionadas" Width="180" Background="#D32F2F" Foreground="White" FontWeight="Bold"/>
                </StackPanel>
                <TextBox x:Name="LogBox" Grid.Row="1" Background="#1E1E1E" Foreground="#00FF00" 
                         FontFamily="Consolas" FontSize="11" IsReadOnly="True" 
                         VerticalScrollBarVisibility="Auto" BorderThickness="0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$AppsList = $window.FindName("AppsList")
$BtnRefresh = $window.FindName("BtnRefresh")
$BtnUninstall = $window.FindName("BtnUninstall")
$LogBox = $window.FindName("LogBox")

# Cargar y mostrar apps
function Load-Apps {
    $LogBox.AppendText("Cargando aplicaciones instaladas...`n")
    $apps = Get-InstalledApps
    
    # Extraer iconos
    foreach ($app in $apps) {
        if ($app.IconPath -and (Test-Path $app.IconPath)) {
            try {
                $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($app.IconPath)
                $app.IconImage = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $icon.Handle, 
                    [System.Windows.Int32Rect]::Empty, 
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
                )
            } catch {}
        }
    }
    $AppsList.ItemsSource = $apps
    $LogBox.AppendText("Se encontraron $($apps.Count) aplicaciones.`n")
}

# Eventos
$BtnRefresh.Add_Click({ Load-Apps })

$BtnUninstall.Add_Click({
    $selected = $AppsList.ItemsSource | Where-Object { $_.IsChecked -eq $true }
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No has seleccionado ninguna aplicación.", "Aviso", "OK", "Information")
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "¿Estás seguro de desinstalar y limpiar archivos de:`n`n$($selected.Name -join "`n")`n`n(Esta acción NO se puede deshacer y NO toca el Registro).", 
        "Confirmar Desinstalación", "YesNo", "Warning"
    )
    if ($confirm -ne 'Yes') { return }

    $BtnUninstall.IsEnabled = $false
    foreach ($app in $selected) {
        Invoke-AppUninstall $app $LogBox
        [System.Windows.Forms.Application]::DoEvents() # Refrescar UI
    }
    $BtnUninstall.IsEnabled = $true
    [System.Windows.MessageBox]::Show("Proceso finalizado. Revisa el log para más detalles.", "Completado", "OK", "Information")
    Load-Apps
})

# Iniciar
Load-Apps
$window.ShowDialog() | Out-Null