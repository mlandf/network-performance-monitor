#Requires -Version 5.1
<#
    NetworkMonitor.ps1 - Netzwerk-Performance-Monitor mit WPF-GUI + SQLite
    Ping-Verfuegbarkeit + iperf3 TCP/UDP Performance-Monitoring
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

#region SQLite Setup
function Initialize-SQLite {
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        try {
            Install-Module -Name PSSQLite -Scope CurrentUser -Force -ErrorAction Stop
        }
        catch {
            [System.Windows.MessageBox]::Show(
                "PSSQLite-Modul wird benoetigt.`nBitte ausfuehren:`nInstall-Module PSSQLite -Scope CurrentUser",
                "Modul fehlt", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return $false
        }
    }
    Import-Module PSSQLite -ErrorAction Stop
    return $true
}

function Initialize-Database {
    param([string]$DbPath)
    $queries = @(
        "CREATE TABLE IF NOT EXISTS ping (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            session_id TEXT NOT NULL,
            target TEXT NOT NULL,
            status TEXT NOT NULL,
            latency_ms REAL,
            ttl INTEGER,
            during_iperf INTEGER NOT NULL DEFAULT 0
        )",
        "CREATE TABLE IF NOT EXISTS iperf (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            session_id TEXT NOT NULL,
            target TEXT NOT NULL,
            protocol TEXT NOT NULL,
            direction TEXT NOT NULL DEFAULT 'Upload',
            bandwidth_mbps REAL,
            jitter_ms REAL,
            packet_loss_pct REAL,
            retransmits INTEGER,
            cpu_pct REAL
        )",
        "CREATE TABLE IF NOT EXISTS sessions (
            session_id TEXT PRIMARY KEY,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_minutes INTEGER,
            ping_targets TEXT,
            iperf_target TEXT,
            ping_interval_sec INTEGER,
            iperf_interval_min INTEGER
        )",
        "CREATE INDEX IF NOT EXISTS idx_ping_ts ON ping(timestamp)",
        "CREATE INDEX IF NOT EXISTS idx_ping_session ON ping(session_id)",
        "CREATE INDEX IF NOT EXISTS idx_iperf_ts ON iperf(timestamp)",
        "CREATE INDEX IF NOT EXISTS idx_iperf_session ON iperf(session_id)",
        "PRAGMA journal_mode=WAL",
        "PRAGMA busy_timeout=5000"
    )
    foreach ($q in $queries) {
        Invoke-SqliteQuery -DataSource $DbPath -Query $q
    }
    # Migrate: add direction column if missing (old DBs)
    try {
        $cols = Invoke-SqliteQuery -DataSource $DbPath -Query "PRAGMA table_info(iperf)"
        if ($cols.name -notcontains 'direction') {
            Invoke-SqliteQuery -DataSource $DbPath -Query "ALTER TABLE iperf ADD COLUMN direction TEXT NOT NULL DEFAULT 'Upload'"
        }
    } catch {}
    try {
        $cols = Invoke-SqliteQuery -DataSource $DbPath -Query "PRAGMA table_info(ping)"
        if ($cols.name -notcontains 'during_iperf') {
            Invoke-SqliteQuery -DataSource $DbPath -Query "ALTER TABLE ping ADD COLUMN during_iperf INTEGER NOT NULL DEFAULT 0"
        }
    } catch {}
}
#endregion

#region XAML GUI
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Netzwerk Performance Monitor" Height="800" Width="850"
        WindowStartupLocation="CenterScreen" Background="#1e1e2e">
    <Window.Resources>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="Padding" Value="4,2"/>
            <Setter Property="FontFamily" Value="Consolas"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#89b4fa"/>
            <Setter Property="Foreground" Value="#1e1e2e"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="#a6adc8"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="Padding" Value="4,2"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
    </Window.Resources>
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Ping Targets -->
        <GroupBox Grid.Row="0" Header="  Ping-Ziele (Verfuegbarkeitsmonitoring)  ">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="70"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="70"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="70"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Label Grid.Column="0" Content="Ziel 1:" VerticalAlignment="Center"/>
                <TextBox Grid.Column="1" Name="txtPing1" Text="8.8.8.8" Margin="0,2"/>
                <Label Grid.Column="2" Content="Ziel 2:" VerticalAlignment="Center"/>
                <TextBox Grid.Column="3" Name="txtPing2" Text="1.1.1.1" Margin="0,2"/>
                <Label Grid.Column="4" Content="Ziel 3:" VerticalAlignment="Center"/>
                <TextBox Grid.Column="5" Name="txtPing3" Text="9.9.9.9" Margin="0,2"/>
                <Label Grid.Row="1" Grid.Column="0" Content="Intervall:" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBox Name="txtPingInterval" Text="5" Width="40" Margin="0,2"/>
                    <Label Content="Sekunden" Foreground="#a6adc8"/>
                </StackPanel>
            </Grid>
        </GroupBox>

        <!-- iPerf Settings -->
        <GroupBox Grid.Row="1" Header="  iperf3-Einstellungen  ">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Label Content="iperf3.exe:" VerticalAlignment="Center"/>
                <TextBox Grid.Column="1" Name="txtIperfPath" Text="C:\iperf3\iperf3.exe" Margin="0,2"/>
                <Button Grid.Column="2" Name="btnBrowseIperf" Content="..." Width="30" Margin="4,2" Background="#585b70"/>

                <Label Grid.Row="1" Content="Ziel-Server:" VerticalAlignment="Center"/>
                <TextBox Grid.Row="1" Grid.Column="1" Name="txtIperfTarget" Text="192.168.1.1" Margin="0,2"/>

                <Label Grid.Row="2" Content="Port:" VerticalAlignment="Center"/>
                <TextBox Grid.Row="2" Grid.Column="1" Name="txtIperfPort" Text="5201" Width="80" HorizontalAlignment="Left" Margin="0,2"/>

                <Label Grid.Row="3" Content="Testdauer:" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="3" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBox Name="txtIperfDuration" Text="10" Width="40" Margin="0,2"/>
                    <Label Content="Sekunden pro iperf-Durchlauf" Foreground="#a6adc8"/>
                </StackPanel>

                <Label Grid.Row="4" Content="UDP Bitrate:" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="4" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBox Name="txtUdpBitrate" Text="2" Width="40" Margin="0,2"/>
                    <Label Content="Mbit/s (typisch: 2-5)" Foreground="#a6adc8"/>
                </StackPanel>

                <Label Grid.Row="5" Content="iperf-Zyklus:" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBox Name="txtIperfInterval" Text="5" Width="40" Margin="0,2"/>
                    <Label Content="Minuten zwischen Tests" Foreground="#a6adc8"/>
                </StackPanel>
            </Grid>
        </GroupBox>

        <!-- Test Duration + Output -->
        <GroupBox Grid.Row="2" Header="  Testlaufzeit und Ausgabe  ">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Label Content="Gesamtdauer:" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBox Name="txtTotalDuration" Text="1" Width="50" Margin="0,2"/>
                    <ComboBox Name="cmbDurationUnit" Width="100" Margin="4,2" SelectedIndex="1">
                        <ComboBoxItem Content="Minuten"/>
                        <ComboBoxItem Content="Stunden"/>
                        <ComboBoxItem Content="Tage"/>
                    </ComboBox>
                    <Label Content="" Name="lblEstimate" Foreground="#fab387" FontSize="11"/>
                </StackPanel>

                <Label Grid.Row="1" Content="Datenbank:" VerticalAlignment="Center"/>
                <TextBox Grid.Row="1" Grid.Column="1" Name="txtDbPath" Text="" Margin="0,2" IsReadOnly="True"/>
                <Button Grid.Row="1" Grid.Column="2" Name="btnBrowseDb" Content="..." Width="30" Margin="4,2" Background="#585b70"/>

                <Label Grid.Row="2" Content="" VerticalAlignment="Center"/>
                <StackPanel Grid.Row="2" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,4">
                    <Label Content="Format: SQLite (.db) - beliebig viele Sessions in einer Datei" Foreground="#a6adc8" FontSize="11"/>
                </StackPanel>
            </Grid>
        </GroupBox>

        <!-- Progress -->
        <GroupBox Grid.Row="3" Header="  Fortschritt  ">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ProgressBar Name="progressBar" Height="22" Background="#313244" Foreground="#a6e3a1" BorderBrush="#45475a" Value="0"/>
                <Label Grid.Column="1" Name="lblProgress" Content="--:--:-- verbleibend" Foreground="#a6adc8" FontFamily="Consolas" FontSize="11" Margin="8,0,0,0"/>
            </Grid>
        </GroupBox>

        <!-- Control Buttons -->
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Center" Margin="5">
            <Button Name="btnStart" Content="[>] Monitoring starten" Width="180" Margin="5" Background="#a6e3a1"/>
            <Button Name="btnStop" Content="[X] Stoppen" Width="140" Margin="5" Background="#f38ba8" IsEnabled="False"/>
            <Button Name="btnDashboard" Content="[=] Dashboard oeffnen" Width="170" Margin="5" Background="#cba6f7"/>
            <Button Name="btnDownloadIperf" Content="[v] iperf3 Download" Width="160" Margin="5" Background="#fab387"/>
        </StackPanel>

        <!-- Log -->
        <GroupBox Grid.Row="5" Header="  Log  ">
            <TextBox Name="txtLog" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                     TextWrapping="Wrap" Background="#181825" Foreground="#a6e3a1"
                     FontFamily="Consolas" FontSize="11" AcceptsReturn="True"/>
        </GroupBox>

        <!-- Status Bar -->
        <Border Grid.Row="6" Background="#313244" CornerRadius="3" Padding="8,4" Margin="0,5,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="txtStatus" Text="Bereit" Foreground="#a6adc8" FontFamily="Segoe UI"/>
                <TextBlock Grid.Column="2" Name="txtStats" Text="" Foreground="#89b4fa" FontFamily="Segoe UI"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$txtPing1 = $window.FindName("txtPing1")
$txtPing2 = $window.FindName("txtPing2")
$txtPing3 = $window.FindName("txtPing3")
$txtPingInterval = $window.FindName("txtPingInterval")
$txtIperfPath = $window.FindName("txtIperfPath")
$txtIperfTarget = $window.FindName("txtIperfTarget")
$txtIperfPort = $window.FindName("txtIperfPort")
$txtIperfDuration = $window.FindName("txtIperfDuration")
$txtUdpBitrate = $window.FindName("txtUdpBitrate")
$txtIperfInterval = $window.FindName("txtIperfInterval")
$txtTotalDuration = $window.FindName("txtTotalDuration")
$cmbDurationUnit = $window.FindName("cmbDurationUnit")
$lblEstimate = $window.FindName("lblEstimate")
$txtDbPath = $window.FindName("txtDbPath")
$progressBar = $window.FindName("progressBar")
$lblProgress = $window.FindName("lblProgress")
$txtLog = $window.FindName("txtLog")
$txtStatus = $window.FindName("txtStatus")
$txtStats = $window.FindName("txtStats")
$btnStart = $window.FindName("btnStart")
$btnStop = $window.FindName("btnStop")
$btnDashboard = $window.FindName("btnDashboard")
$btnBrowseIperf = $window.FindName("btnBrowseIperf")
$btnBrowseDb = $window.FindName("btnBrowseDb")
$btnDownloadIperf = $window.FindName("btnDownloadIperf")
#endregion

#region State
$script:running = $false
$script:pingJob = $null
$script:iperfJob = $null
$script:pingCount = 0
$script:iperfCount = 0
$script:sessionId = ""
$script:startTime = $null
$script:endTime = $null

$defaultDbDir = [System.IO.Path]::Combine(
    [Environment]::GetFolderPath("MyDocuments"), "NetworkMonitor"
)
$txtDbPath.Text = Join-Path $defaultDbDir "networkmonitor.db"
#endregion

#region Estimate calculation
function Update-Estimate {
    $dur = 0
    try { $dur = [double]$txtTotalDuration.Text } catch { return }
    $unit = $cmbDurationUnit.SelectedIndex
    $totalMin = switch ($unit) { 0 { $dur } 1 { $dur * 60 } 2 { $dur * 1440 } }

    $pingIntervalSec = 5; try { $pingIntervalSec = [int]$txtPingInterval.Text } catch {}
    $iperfIntervalMin = 5; try { $iperfIntervalMin = [int]$txtIperfInterval.Text } catch {}
    $targets = @($txtPing1.Text, $txtPing2.Text, $txtPing3.Text) | Where-Object { $_ -ne "" }

    $pingRows = [math]::Floor($totalMin * 60 / $pingIntervalSec) * $targets.Count
    $iperfRows = [math]::Floor($totalMin / $iperfIntervalMin) * 2

    $lblEstimate.Content = "~ $pingRows Pings, $iperfRows iperf-Tests"
}

$txtTotalDuration.Add_TextChanged({ Update-Estimate })
$cmbDurationUnit.Add_SelectionChanged({ Update-Estimate })
$txtPingInterval.Add_TextChanged({ Update-Estimate })
$txtIperfInterval.Add_TextChanged({ Update-Estimate })
Update-Estimate
#endregion

#region Helper Functions
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $window.Dispatcher.Invoke([Action]{
        $txtLog.AppendText("[$timestamp] $Message`r`n")
        $txtLog.ScrollToEnd()
    })
}

function Update-Status {
    param([string]$Text)
    $window.Dispatcher.Invoke([Action]{
        $txtStatus.Text = $Text
    })
}

function Update-Stats {
    $window.Dispatcher.Invoke([Action]{
        $txtStats.Text = "Pings: $($script:pingCount) | iperf-Tests: $($script:iperfCount)"
    })
}

function Update-Progress {
    if ($null -eq $script:startTime -or $null -eq $script:endTime) { return }
    $now = Get-Date
    $total = ($script:endTime - $script:startTime).TotalSeconds
    $elapsed = ($now - $script:startTime).TotalSeconds
    $pct = [math]::Min(100, [math]::Round(($elapsed / $total) * 100, 1))
    $remaining = $script:endTime - $now
    if ($remaining.TotalSeconds -lt 0) { $remaining = [TimeSpan]::Zero }

    $window.Dispatcher.Invoke([Action]{
        $progressBar.Value = $pct
        if ($remaining.TotalHours -ge 1) {
            $lblProgress.Content = "{0:0}h {1:00}m verbleibend" -f [math]::Floor($remaining.TotalHours), $remaining.Minutes
        } else {
            $lblProgress.Content = "{0:00}:{1:00} verbleibend" -f $remaining.Minutes, $remaining.Seconds
        }
    })
}
#endregion

#region Background Ping Runspace
$script:pingRunspace = $null
$script:pingPowerShell = $null
$script:pingResultQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:pingRunning = [System.Threading.ManualResetEventSlim]::new($false)
$script:pingStop = [System.Threading.CancellationTokenSource]::new()
$script:pingPause = [System.Threading.ManualResetEventSlim]::new($true)  # true = not paused

function Start-PingRunspace {
    param(
        [string[]]$Targets,
        [int]$IntervalSec,
        [string]$DbPath,
        [string]$SessionId
    )

    $script:pingStop = [System.Threading.CancellationTokenSource]::new()
    $script:pingRunspace = [runspacefactory]::CreateRunspace()
    $script:pingRunspace.Open()

    $script:pingRunspace.SessionStateProxy.SetVariable("Targets", $Targets)
    $script:pingRunspace.SessionStateProxy.SetVariable("IntervalSec", $IntervalSec)
    $script:pingRunspace.SessionStateProxy.SetVariable("DbPath", $DbPath)
    $script:pingRunspace.SessionStateProxy.SetVariable("SessionId", $SessionId)
    $script:pingRunspace.SessionStateProxy.SetVariable("ResultQueue", $script:pingResultQueue)
    $script:pingRunspace.SessionStateProxy.SetVariable("CancelToken", $script:pingStop.Token)
    $script:pingRunspace.SessionStateProxy.SetVariable("PauseFlag", $script:pingPause)

    $script:pingPowerShell = [powershell]::Create()
    $script:pingPowerShell.Runspace = $script:pingRunspace

    [void]$script:pingPowerShell.AddScript({
        Import-Module PSSQLite -ErrorAction SilentlyContinue

        # Enable WAL mode for concurrent reads/writes
        try {
            Invoke-SqliteQuery -DataSource $DbPath -Query "PRAGMA journal_mode=WAL" -ErrorAction SilentlyContinue
            Invoke-SqliteQuery -DataSource $DbPath -Query "PRAGMA busy_timeout=5000" -ErrorAction SilentlyContinue
        } catch {}

        while (-not $CancelToken.IsCancellationRequested) {
            $duringIperf = if ($PauseFlag.IsSet) { 0 } else { 1 }
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            foreach ($target in $Targets) {
                if ($CancelToken.IsCancellationRequested) { break }
                try {
                    $result = Test-Connection -ComputerName $target -Count 1 -ErrorAction Stop
                    $latency = $result.ResponseTime
                    $ttl = $result.TimeToLive
                    if ($null -eq $ttl) { $ttl = 0 }

                    $retries = 3
                    while ($retries -gt 0) {
                        try {
                            Invoke-SqliteQuery -DataSource $DbPath -Query `
                                "INSERT INTO ping (timestamp, session_id, target, status, latency_ms, ttl, during_iperf) VALUES (@ts, @sid, @tgt, 'OK', @lat, @ttl, @di)" `
                                -SqlParameters @{ ts=$timestamp; sid=$SessionId; tgt=$target; lat=$latency; ttl=$ttl; di=$duringIperf }
                            break
                        } catch {
                            $retries--
                            if ($retries -gt 0) { Start-Sleep -Milliseconds 200 }
                        }
                    }
                    $iperfTag = if ($duringIperf) { " [iperf]" } else { "" }
                    [void]$ResultQueue.Enqueue("OK|$target|$latency|$ttl$iperfTag")
                }
                catch {
                    $retries = 3
                    while ($retries -gt 0) {
                        try {
                            Invoke-SqliteQuery -DataSource $DbPath -Query `
                                "INSERT INTO ping (timestamp, session_id, target, status, latency_ms, ttl, during_iperf) VALUES (@ts, @sid, @tgt, 'FAIL', -1, 0, @di)" `
                                -SqlParameters @{ ts=$timestamp; sid=$SessionId; tgt=$target; di=$duringIperf }
                            break
                        } catch {
                            $retries--
                            if ($retries -gt 0) { Start-Sleep -Milliseconds 200 }
                        }
                    }
                    [void]$ResultQueue.Enqueue("FAIL|$target|0|0")
                }
            }
            [void]$ResultQueue.Enqueue("CYCLE_DONE")

            # Sleep in small increments so we can cancel quickly
            $slept = 0
            while ($slept -lt ($IntervalSec * 1000) -and -not $CancelToken.IsCancellationRequested) {
                Start-Sleep -Milliseconds 500
                $slept += 500
            }
        }
    })

    $script:pingPowerShell.BeginInvoke() | Out-Null
}

function Stop-PingRunspace {
    if ($script:pingStop) {
        $script:pingStop.Cancel()
    }
    if ($script:pingPowerShell) {
        try { $script:pingPowerShell.Stop() } catch {}
        $script:pingPowerShell.Dispose()
        $script:pingPowerShell = $null
    }
    if ($script:pingRunspace) {
        try { $script:pingRunspace.Close() } catch {}
        $script:pingRunspace.Dispose()
        $script:pingRunspace = $null
    }
}
#endregion

#region Timer Setup
$script:uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:uiTimer.Interval = [TimeSpan]::FromSeconds(1)

$script:iperfTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:iperfRunning = $false

# UI timer: drain ping result queue, update progress, check auto-stop
$script:uiTimer.Add_Tick({
    if (-not $script:running) { return }

    # Drain ping results from background runspace
    $msg = $null
    while ($script:pingResultQueue.TryDequeue([ref]$msg)) {
        if ($msg -eq "CYCLE_DONE") {
            $script:pingCount++
            Update-Stats
        } else {
            $parts = $msg.Split('|')
            $status = $parts[0]
            $target = $parts[1]
            $latency = $parts[2]
            $ttl = $parts[3]
            if ($status -eq "OK") {
                Write-Log "PING $target - OK (${latency}ms, TTL=$ttl)"
            } else {
                Write-Log "PING $target - FAIL"
            }
        }
    }

    Update-Progress

    # Auto-stop
    if ((Get-Date) -ge $script:endTime) {
        $btnStop.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
})

$script:iperfTimer.Add_Tick({
    if ($script:running -and -not $script:iperfRunning) {
        if ((Get-Date) -ge $script:endTime) { return }
        $script:iperfRunning = $true
        $script:pingPause.Reset()  # Pause pings during iperf
        Update-Status "iperf3-Tests laufen (Pings pausiert)..."

        $iperfExe = $txtIperfPath.Text
        $target = $txtIperfTarget.Text
        $port = $txtIperfPort.Text
        $duration = $txtIperfDuration.Text
        $udpBitrate = $txtUdpBitrate.Text
        $dbPath = $txtDbPath.Text
        $sid = $script:sessionId

        $scriptBlock = {
            param($exe, $tgt, $p, $dur, $br, $db, $sessionId)

            Import-Module PSSQLite -ErrorAction SilentlyContinue
            try {
                Invoke-SqliteQuery -DataSource $db -Query "PRAGMA journal_mode=WAL" -ErrorAction SilentlyContinue
                Invoke-SqliteQuery -DataSource $db -Query "PRAGMA busy_timeout=5000" -ErrorAction SilentlyContinue
            } catch {}

            $results = @()

            foreach ($dir in @('Upload','Download')) {
                $reverseFlag = if ($dir -eq 'Download') { '-R' } else { $null }
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                # TCP
                try {
                    $tcpArgs = @('-c', $tgt, '-p', $p, '-t', $dur, '-i', '1', '--json')
                    if ($reverseFlag) { $tcpArgs += $reverseFlag }
                    $tcpOut = & $exe @tcpArgs 2>&1
                    $tcpJson = $tcpOut | Out-String | ConvertFrom-Json
                    if ($tcpJson.end) {
                        $sumKey = if ($dir -eq 'Download') { 'sum_received' } else { 'sum_sent' }
                        $sumObj = $tcpJson.end.$sumKey
                        if (-not $sumObj) { $sumObj = $tcpJson.end.sum_sent }
                        $bw = [math]::Round($sumObj.bits_per_second / 1000000, 2)
                        $retrans = if ($sumObj.retransmits) { $sumObj.retransmits } else { 0 }
                        $cpu = if ($tcpJson.end.cpu_utilization_percent) {
                            [math]::Round($tcpJson.end.cpu_utilization_percent.host_total, 1)
                        } else { 0 }
                        Invoke-SqliteQuery -DataSource $db -Query `
                            "INSERT INTO iperf (timestamp,session_id,target,protocol,direction,bandwidth_mbps,jitter_ms,packet_loss_pct,retransmits,cpu_pct) VALUES (@ts,@sid,@tgt,'TCP',@dir,@bw,0,0,@rt,@cpu)" `
                            -SqlParameters @{ts=$timestamp;sid=$sessionId;tgt=$tgt;dir=$dir;bw=$bw;rt=$retrans;cpu=$cpu}
                        $results += "TCP $dir : ${bw} Mbit/s, Retransmits: $retrans"
                    }
                } catch {
                    Invoke-SqliteQuery -DataSource $db -Query `
                        "INSERT INTO iperf (timestamp,session_id,target,protocol,direction,bandwidth_mbps,jitter_ms,packet_loss_pct,retransmits,cpu_pct) VALUES (@ts,@sid,@tgt,'TCP',@dir,0,0,0,-1,0)" `
                        -SqlParameters @{ts=$timestamp;sid=$sessionId;tgt=$tgt;dir=$dir}
                    $results += "TCP $dir : FEHLER - $($_.Exception.Message)"
                }

                Start-Sleep -Seconds 2

                # UDP
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                try {
                    $udpArgs = @('-c', $tgt, '-p', $p, '-t', $dur, '-i', '1', '-u', '-b', "${br}M", '--json')
                    if ($reverseFlag) { $udpArgs += $reverseFlag }
                    $udpOut = & $exe @udpArgs 2>&1
                    $udpJson = $udpOut | Out-String | ConvertFrom-Json
                    if ($udpJson.end) {
                        $bw = [math]::Round($udpJson.end.sum.bits_per_second / 1000000, 2)
                        $jitter = [math]::Round($udpJson.end.sum.jitter_ms, 3)
                        $loss = [math]::Round($udpJson.end.sum.lost_percent, 2)
                        $cpu = if ($udpJson.end.cpu_utilization_percent) {
                            [math]::Round($udpJson.end.cpu_utilization_percent.host_total, 1)
                        } else { 0 }
                        Invoke-SqliteQuery -DataSource $db -Query `
                            "INSERT INTO iperf (timestamp,session_id,target,protocol,direction,bandwidth_mbps,jitter_ms,packet_loss_pct,retransmits,cpu_pct) VALUES (@ts,@sid,@tgt,'UDP',@dir,@bw,@jit,@loss,0,@cpu)" `
                            -SqlParameters @{ts=$timestamp;sid=$sessionId;tgt=$tgt;dir=$dir;bw=$bw;jit=$jitter;loss=$loss;cpu=$cpu}
                        $results += "UDP $dir : ${bw} Mbit/s, Jitter: ${jitter}ms, Loss: ${loss}%"
                    }
                } catch {
                    Invoke-SqliteQuery -DataSource $db -Query `
                        "INSERT INTO iperf (timestamp,session_id,target,protocol,direction,bandwidth_mbps,jitter_ms,packet_loss_pct,retransmits,cpu_pct) VALUES (@ts,@sid,@tgt,'UDP',@dir,0,0,100,0,0)" `
                        -SqlParameters @{ts=$timestamp;sid=$sessionId;tgt=$tgt;dir=$dir}
                    $results += "UDP $dir : FEHLER - $($_.Exception.Message)"
                }

                Start-Sleep -Seconds 2
            }

            return $results
        }

        $script:iperfJob = Start-Job -ScriptBlock $scriptBlock -ArgumentList @(
            $iperfExe, $target, $port, $duration, $udpBitrate, $dbPath, $sid
        )

        $script:jobCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:jobCheckTimer.Interval = [TimeSpan]::FromSeconds(2)
        $script:jobCheckTimer.Add_Tick({
            if ($script:iperfJob -and $script:iperfJob.State -eq "Completed") {
                $results = Receive-Job -Job $script:iperfJob
                Remove-Job -Job $script:iperfJob -Force
                $script:iperfJob = $null
                foreach ($r in $results) {
                    Write-Log "iperf3: $r"
                }
                $script:iperfCount++
                Update-Stats
                Update-Status "Monitoring aktiv - naechster iperf in $($txtIperfInterval.Text) Min."
                $script:iperfRunning = $false
                $script:pingPause.Set()  # Resume pings
                $script:jobCheckTimer.Stop()
            }
            elseif ($script:iperfJob -and $script:iperfJob.State -eq "Failed") {
                $err = Receive-Job -Job $script:iperfJob -ErrorAction SilentlyContinue 2>&1
                Write-Log "iperf3 Job fehlgeschlagen: $err"
                Remove-Job -Job $script:iperfJob -Force
                $script:iperfJob = $null
                $script:iperfRunning = $false
                $script:pingPause.Set()  # Resume pings
                $script:jobCheckTimer.Stop()
            }
        })
        $script:jobCheckTimer.Start()
    }
})
#endregion

#region Event Handlers
$btnStart.Add_Click({
    if ($script:running) { return }

    if (-not (Initialize-SQLite)) { return }

    $targets = @($txtPing1.Text, $txtPing2.Text, $txtPing3.Text) | Where-Object { $_ -ne "" }
    if ($targets.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Mindestens ein Ping-Ziel angeben!", "Fehler",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $dbDir = Split-Path $txtDbPath.Text -Parent
    if (-not (Test-Path $dbDir)) {
        New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
    }

    Initialize-Database -DbPath $txtDbPath.Text

    $dur = [double]$txtTotalDuration.Text
    $unit = $cmbDurationUnit.SelectedIndex
    $totalMin = switch ($unit) { 0 { $dur } 1 { $dur * 60 } 2 { $dur * 1440 } }

    $script:startTime = Get-Date
    $script:endTime = $script:startTime.AddMinutes($totalMin)
    $script:sessionId = $script:startTime.ToString("yyyyMMdd-HHmmss")

    $pingIntervalSec = [int]$txtPingInterval.Text
    $iperfIntervalMin = [int]$txtIperfInterval.Text
    Invoke-SqliteQuery -DataSource $txtDbPath.Text -Query `
        "INSERT INTO sessions (session_id, start_time, duration_minutes, ping_targets, iperf_target, ping_interval_sec, iperf_interval_min) VALUES (@sid, @st, @dur, @pt, @it, @pi, @ii)" `
        -SqlParameters @{
            sid=$script:sessionId; st=$script:startTime.ToString("yyyy-MM-dd HH:mm:ss")
            dur=[int]$totalMin; pt=($targets -join ","); it=$txtIperfTarget.Text
            pi=$pingIntervalSec; ii=$iperfIntervalMin
        }

    $endStr = $script:endTime.ToString("HH:mm:ss dd.MM.yyyy")
    Write-Log "Monitoring gestartet - Session: $($script:sessionId)"
    Write-Log "Geplantes Ende: $endStr ($totalMin Minuten)"
    Write-Log "Datenbank: $($txtDbPath.Text)"
    Write-Log "Ping-Ziele: $($targets -join ', ') (alle ${pingIntervalSec}s)"
    Write-Log "iperf3-Ziel: $($txtIperfTarget.Text):$($txtIperfPort.Text) (alle ${iperfIntervalMin}min)"

    $script:running = $true
    $script:pingCount = 0
    $script:iperfCount = 0

    # Start ping in background runspace
    Start-PingRunspace -Targets $targets -IntervalSec $pingIntervalSec `
        -DbPath $txtDbPath.Text -SessionId $script:sessionId

    # Start UI update timer
    $script:uiTimer.Start()

    # Start iperf timer
    $script:iperfTimer.Interval = [TimeSpan]::FromMinutes($iperfIntervalMin)
    $script:iperfTimer.Start()

    $btnStart.IsEnabled = $false
    $btnStop.IsEnabled = $true
    Update-Status "Monitoring aktiv bis $endStr"
})

$btnStop.Add_Click({
    $script:running = $false
    $script:uiTimer.Stop()
    $script:iperfTimer.Stop()

    Stop-PingRunspace

    if ($script:iperfJob) {
        Stop-Job -Job $script:iperfJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:iperfJob -Force -ErrorAction SilentlyContinue
        $script:iperfJob = $null
    }

    if ($script:sessionId -and $txtDbPath.Text) {
        try {
            $endTs = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Invoke-SqliteQuery -DataSource $txtDbPath.Text -Query `
                "UPDATE sessions SET end_time = @et WHERE session_id = @sid" `
                -SqlParameters @{ et=$endTs; sid=$script:sessionId }
        } catch {}
    }

    $btnStart.IsEnabled = $true
    $btnStop.IsEnabled = $false
    Update-Status "Gestoppt"
    $window.Dispatcher.Invoke([Action]{
        $progressBar.Value = 100
        $lblProgress.Content = "Abgeschlossen"
    })
    Write-Log "Monitoring gestoppt - $($script:pingCount) Ping-Zyklen, $($script:iperfCount) iperf-Tests"
    Write-Log "Daten gespeichert in: $($txtDbPath.Text)"
})

$btnBrowseIperf.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "iperf3|iperf3.exe|Alle Dateien|*.*"
    $dialog.Title = "iperf3.exe auswaehlen"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtIperfPath.Text = $dialog.FileName
    }
})

$btnBrowseDb.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "SQLite Datenbank|*.db|Alle Dateien|*.*"
    $dialog.Title = "Datenbank-Datei waehlen"
    $dialog.FileName = "networkmonitor.db"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtDbPath.Text = $dialog.FileName
    }
})

$btnDownloadIperf.Add_Click({
    Start-Process "https://github.com/ar51an/iperf3-win-builds/releases"
})

$btnDashboard.Add_Click({
    $dashboardPath = Join-Path $PSScriptRoot "dashboard.html"
    if (Test-Path $dashboardPath) {
        Start-Process $dashboardPath
    }
    else {
        [System.Windows.MessageBox]::Show(
            "dashboard.html nicht gefunden!`nBitte im gleichen Ordner wie das Skript ablegen.",
            "Fehler", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    }
})

$window.Add_Closing({
    $script:running = $false
    $script:uiTimer.Stop()
    $script:iperfTimer.Stop()
    Stop-PingRunspace
    if ($script:iperfJob) {
        Stop-Job -Job $script:iperfJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:iperfJob -Force -ErrorAction SilentlyContinue
    }
    if ($script:sessionId -and $txtDbPath.Text) {
        try {
            Invoke-SqliteQuery -DataSource $txtDbPath.Text -Query `
                "UPDATE sessions SET end_time = @et WHERE session_id = @sid" `
                -SqlParameters @{ et=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); sid=$script:sessionId }
        } catch {}
    }
})
#endregion

$window.ShowDialog() | Out-Null
