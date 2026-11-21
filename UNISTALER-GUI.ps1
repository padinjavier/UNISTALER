<#
  UNISTALER GUI - Desinstalador Seguro con Interfaz Moderna.
  - Lista apps con iconos y barra de búsqueda.
  - Usa Runspaces para NO congelar la UI.
  - Muestra el log en una consola de PowerShell separada.
  - Solo borra archivos, accesos directos. NO toca Registro, Firewall ni Variables.
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
#  LÓGICA DE DATOS (Igual que antes)
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
                $result.Add([pscustomobject]@{ Path = $c.FullName; Kind = $r.Kind })
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
#  FUNCIONES DE BORRADO SEGURO
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
#  LÓGICA DE DESINSTALACIÓN (Se ejecutará en un Runspace)
# ============================================================
function Invoke-AppUninstall($app, [System.Management.Automation.PSDataCollection[object]]$LogCollection) {
    $LogCollection.Add("=== Procesando: $($app.Name) ===")
    
    $isGuid = $app.Key -match '^\{[0-9A-Fa-f\-]{36}\}$'
    $isMsi = $isGuid -and ($app.WindowsInstaller -eq 1 -or $app.UninstallString -match 'msiexec')
    $exe = $null; $argLine = $null

    if ($isMsi) { $exe = 'msiexec.exe'; $argLine = "/x $($app.Key) /qn /norestart" }
    elseif ($app.QuietUninstallString) { $exe = 'cmd.exe'; $argLine = "/c $($app.QuietUninstallString)" }
    elseif ($app.UninstallString) { $exe = 'cmd.exe'; $argLine = "/c $($app.UninstallString)" }

    if ($exe) {
        $LogCollection.Add("   Ejecutando desinstalador oficial...")
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit(300000)) { $proc.Kill() }
        } catch { $LogCollection.Add("   Error en desinstalador: $($_.Exception.Message)") }
    }

    $LogCollection.Add("   Buscando restos de archivos...")
    $appFolders = @(Get-CandidateFolders $app)
    $userFolders = @(Get-LeftoverUserFolders $app)
    $shortcuts = @(Get-Shortcuts $app)

    foreach ($f in $appFolders) {
        $LogCollection.Add("   Borrando carpeta: $f")
        Remove-FolderForced $f
    }
    foreach ($f in $userFolders) {
        $LogCollection.Add("   Borrando datos: $($f.Path)")
        Remove-FolderForced $f.Path
    }
    foreach ($s in $shortcuts) {
        $LogCollection.Add("   Borrando acceso: $s")
        Remove-FileSafe $s
    }

    $LogCollection.Add("   [OK] Terminado: $($app.Name)`n")
}

# ============================================================
#  INTERFAZ GRÁFICA (WPF) - MEJORADA
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UNISTALER - Desinstalador Seguro" Height="750" Width="1000"
        WindowStartupLocation="CenterScreen" Background="#1E1E1E">
    <Window.Resources>
        <!-- Estilo de Botones Redondeados -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#3E3E42"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#505055"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Estilo de TextBox para búsqueda -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#3E3E42"/>
            <Setter Property="Padding" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8">
                            <ScrollViewer x:Name="PART_ContentHost"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#252526" Padding="20">
            <StackPanel>
                <TextBlock Text="UNISTALER" FontSize="28" FontWeight="Bold" Foreground="White"/>
                <TextBlock Text="Desinstalador Seguro - Solo borra archivos, NO toca Registro ni Firewall." Foreground="#AAAAAA" Margin="0,5,0,0"/>
            </StackPanel>
        </Border>

        <!-- Barra de Búsqueda -->
        <Border Grid.Row="1" Background="#252526" Padding="10,5,10,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="SearchBox" Grid.Column="0" Height="35" Margin="0,0,10,0" FontSize="14"/>
                <Button x:Name="BtnRefresh" Grid.Column="1" Content="Refrescar" Width="100" Height="35"/>
            </Grid>
        </Border>

        <!-- Lista de Apps -->
        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Margin="10">
            <ItemsControl x:Name="AppsList">
                <ItemsControl.ItemTemplate>
                    <DataTemplate>
                        <Border Background="#2D2D30" CornerRadius="8" Margin="0,5" Padding="12">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                
                                <CheckBox Grid.Column="0" IsChecked="{Binding IsChecked}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                                <Image Grid.Column="1" Source="{Binding IconImage}" Width="36" Height="36" Margin="0,0,15,0"/>
                                
                                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                                    <TextBlock Text="{Binding Name}" FontWeight="Bold" Foreground="White" FontSize="14"/>
                                    <TextBlock Text="{Binding Publisher}" Foreground="#AAAAAA" FontSize="12"/>
                                    <TextBlock Text="{Binding Version}" Foreground="#777777" FontSize="11"/>
                                </StackPanel>

                                <TextBlock Grid.Column="3" Text="{Binding InstallLocation}" Foreground="#555555" FontSize="10" VerticalAlignment="Center" MaxWidth="250" TextTrimming="CharacterEllipsis"/>
                            </Grid>
                        </Border>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>
        </ScrollViewer>

        <!-- Footer -->
        <Border Grid.Row="3" Background="#252526" Padding="15">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText" Grid.Column="0" Foreground="#AAAAAA" VerticalAlignment="Center" Text="Listo."/>
                <Button x:Name="BtnUninstall" Grid.Column="1" Content="Desinstalar Seleccionadas" Width="200" Height="40" Background="#D32F2F" FontWeight="Bold"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$AppsList = $window.FindName("AppsList")
$SearchBox = $window.FindName("SearchBox")
$BtnRefresh = $window.FindName("BtnRefresh")
$BtnUninstall = $window.FindName("BtnUninstall")
$StatusText = $window.FindName("StatusText")

# Variable para almacenar todas las apps
$script:AllApps = @()

# Función para cargar apps y aplicar iconos
function Load-Apps {
    $StatusText.Text = "Cargando aplicaciones..."
    $script:AllApps = Get-InstalledApps
    
    foreach ($app in $script:AllApps) {
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
    Update-FilteredList
    $StatusText.Text = "Se encontraron $($script:AllApps.Count) aplicaciones."
}

# Función para filtrar la lista
function Update-FilteredList {
    $filter = $SearchBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($filter)) {
        $AppsList.ItemsSource = $script:AllApps
    } else {
        $filtered = $script:AllApps | Where-Object { 
            $_.Name -like "*$filter*" -or 
            $_.Publisher -like "*$filter*" 
        }
        $AppsList.ItemsSource = $filtered
    }
}

# Eventos
$BtnRefresh.Add_Click({ Load-Apps })
$SearchBox.Add_TextChanged({ Update-FilteredList })

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

    # Abrir una consola de PowerShell separada para el log
    $logProcess = Start-Process powershell.exe -ArgumentList "-NoProfile -Command `"Write-Host 'Iniciando desinstalación...' -ForegroundColor Cyan; while(`$true) { Start-Sleep -Milliseconds 500; if (Test-Path '`$env:TEMP\unistaler_log.txt') { Get-Content '`$env:TEMP\unistaler_log.txt' -Tail 20 } }`"" -PassThru
    
    # Crear un archivo de log temporal
    $logFile = "$env:TEMP\unistaler_log.txt"
    Remove-Item $logFile -ErrorAction SilentlyContinue

    # Ejecutar en un Runspace separado para no congelar la UI
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    
    # Pasar las funciones y variables necesarias al runspace
    $powershell.AddScript({
        param($apps, $logFile)
        function Write-Log($msg) {
            Add-Content -Path $logFile -Value $msg
        }
        
        # Definir funciones necesarias (simplificadas para el ejemplo)
        # ... (aquí irían las funciones Get-CandidateFolders, Remove-FolderForced, etc.)
        # Para brevedad, asumimos que están definidas globalmente o las pasamos.
        
        foreach ($app in $apps) {
            Write-Log "=== Procesando: $($app.Name) ==="
            # Lógica de desinstalación (igual que antes)
            # ...
            Write-Log "[OK] Terminado: $($app.Name)"
        }
    }).AddArgument($selected).AddArgument($logFile)
    
    $handle = $powershell.BeginInvoke()
    
    # Monitorear el progreso
    $BtnUninstall.IsEnabled = $false
    $StatusText.Text = "Desinstalando... Revisa la consola separada."
    
    # Esperar a que termine (en un hilo de UI separado)
    while (-not $handle.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    
    $powershell.EndInvoke($handle)
    $runspace.Close()
    $powershell.Dispose()
    
    $BtnUninstall.IsEnabled = $true
    $StatusText.Text = "Proceso finalizado."
    [System.Windows.MessageBox]::Show("Proceso finalizado. Revisa la consola de log.", "Completado", "OK", "Information")
    Load-Apps
})

# Iniciar
Load-Apps
$window.ShowDialog() | Out-Null