<#
    ControlPanel.ps1 - a GUI front end for the diagnostic and gaming-mode tools.

    WPF rather than WinForms, so the icons are real vector geometry (SVG path
    data in Path elements) and the dark theme matches the fault report.

    Nothing here is new behaviour: it drives the same scripts and the same
    checks. The process picker closes apps politely first, exactly as
    gaming-mode.ps1 does, and the same protected list applies.

    Run:  powershell -ExecutionPolicy Bypass -File .\ControlPanel.ps1
          or double-click Control Panel.cmd
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---------------------------------------------------------------- shared data

$Protected = @(
    'System','Idle','Registry','Memory Compression','csrss','wininit','winlogon',
    'services','lsass','smss','fontdrvhost','dwm','explorer','sihost','ctfmon',
    'taskhostw','RuntimeBroker','ShellExperienceHost','StartMenuExperienceHost',
    'SearchHost','TextInputHost','audiodg','svchost','spoolsv','conhost',
    'MsMpEng','SecurityHealthService','NisSrv','WmiPrvSE','dllhost','WUDFHost',
    'powershell','pwsh','WindowsTerminal','cmd',
    'NVDisplay.Container','nvcontainer','igfxEM','igfxCUIService','IntelCpHDCPSvc'
)

$Recommend = @{
    'chrome'='biggest commit consumer; restores tabs'; 'msedge'='browser; restores tabs'
    'firefox'='browser; restores tabs'; 'msedgewebview2'='embedded browsers'
    'Code'='VS Code; reopens with files intact'; 'Signal'='chat; reconnects'
    'stremio-shell-ng'='media app'; 'stremio-runtime'='media app backend'
    'vFlat Send to PC'='phone transfer helper'; 'SnippingTool'='screenshot tool'
    'Taskmgr'='Task Manager'; 'copilot-runtime'='background assistant'
    'sqlservr'='SQL Server; restart when needed'; 'mongod'='MongoDB; restart when needed'
    'esrv'='Intel energy telemetry'; 'NVIDIA App'='driver UI; drivers unaffected'
}
$Caution = @{
    'claude'='ends our session'; 'Discord'='you may want voice chat'
    'steamwebhelper'='Steam UI - needed to launch Steam games'
    'java'='could be a running server'; 'javaw'='could be a running server'
    'Vortex'='mod manager - may be mid-deploy'
    'AsusScreenXpertReunion'='closing may disable the ScreenPad'
    'Docker Desktop'='stops your containers'; 'com.docker.backend'='stops your containers'
}
$Browsers = @('chrome','msedge','firefox','brave','opera','vivaldi')
foreach ($b in @('brave','opera','vivaldi')) { $Recommend[$b] = 'browser; restores tabs' }
$Presets = @{
    'clean'  = @()
    'browse' = $Browsers
    'work'   = $Browsers + @('Code')
}

# Bugcheck codes Windows records in WER kernel reports, for naming them on the
# Kernel faults card. Keyed by lower-case hex without 0x.
$BugNames = @{
    'a'='IRQL_NOT_LESS_OR_EQUAL'; '18'='REFERENCE_BY_POINTER'; '19'='BAD_POOL_HEADER'
    '1a'='MEMORY_MANAGEMENT'; '1e'='KMODE_EXCEPTION_NOT_HANDLED'; '3b'='SYSTEM_SERVICE_EXCEPTION'
    '50'='PAGE_FAULT_IN_NONPAGED_AREA'; '7e'='SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
    '7f'='UNEXPECTED_KERNEL_MODE_TRAP'; '9c'='MACHINE_CHECK_EXCEPTION'
    '9f'='DRIVER_POWER_STATE_FAILURE'; 'a0'='INTERNAL_POWER_ERROR'
    'be'='ATTEMPTED_WRITE_TO_READONLY_MEMORY'; 'c1'='SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION'
    'c2'='BAD_POOL_CALLER'; 'c4'='DRIVER_VERIFIER_DETECTED_VIOLATION'
    'c9'='DRIVER_VERIFIER_IOMANAGER_VIOLATION'; 'd1'='DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    'd6'='DRIVER_PAGE_FAULT_BEYOND_END_OF_ALLOCATION'; 'ea'='THREAD_STUCK_IN_DEVICE_DRIVER'
    'ef'='CRITICAL_PROCESS_DIED'; 'fc'='ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY'
    '101'='CLOCK_WATCHDOG_TIMEOUT'; '116'='VIDEO_TDR_FAILURE'; '117'='VIDEO_TDR_TIMEOUT_DETECTED'
    '119'='VIDEO_SCHEDULER_INTERNAL_ERROR'; '124'='WHEA_UNCORRECTABLE_ERROR'
    '133'='DPC_WATCHDOG_VIOLATION'; '139'='KERNEL_SECURITY_CHECK_FAILURE'
    '13a'='KERNEL_MODE_HEAP_CORRUPTION'; '141'='VIDEO_ENGINE_TIMEOUT_DETECTED'
    '144'='BUGCODE_USB3_DRIVER'; '154'='UNEXPECTED_STORE_EXCEPTION'
    '15f'='CONNECTED_STANDBY_WATCHDOG_TIMEOUT_LIVEDUMP'; '161'='LIVE_SYSTEM_DUMP'
    '190'='WIN32K_CRITICAL_FAILURE_LIVEDUMP'; '193'='VIDEO_DXGKRNL_LIVEDUMP'
    '1c8'='MANUALLY_INITIATED_POWER_BUTTON_HOLD'
}

# "ThinkPad T14 Gen 6", "ZenBook ...": shown in the header so it is clear which PC this is.
$script:Model = ''
try {
    $bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop
    foreach ($v in @($bios.SystemFamily, $bios.SystemProductName)) {
        if ($v -and $v -notmatch 'To be filled|System Product Name|Default string|^\s*$') { $script:Model = $v.Trim(); break }
    }
} catch { }

# --------------------------------------------------------------------- layout

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Stopcode Toolkit" Height="820" Width="1200"
        MinHeight="640" MinWidth="980"
        WindowStartupLocation="CenterScreen" Background="#0D1117">
  <Window.Resources>
    <SolidColorBrush x:Key="Ground"  Color="#0D1117"/>
    <SolidColorBrush x:Key="Surface" Color="#151B24"/>
    <SolidColorBrush x:Key="Line"    Color="#28313D"/>
    <SolidColorBrush x:Key="Ink"     Color="#E7ECF3"/>
    <SolidColorBrush x:Key="Ink2"    Color="#9EA9B8"/>
    <SolidColorBrush x:Key="Ink3"    Color="#78838F"/>
    <SolidColorBrush x:Key="Accent"  Color="#4FB8C0"/>
    <SolidColorBrush x:Key="Ok"      Color="#5BC08C"/>
    <SolidColorBrush x:Key="Warn"    Color="#E0A93A"/>
    <SolidColorBrush x:Key="Crit"    Color="#EA7A70"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Surface}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>

    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Ink2}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,6,0,10"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="#1B2430"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#243041"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#4FB8C0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#17525A"/>
      <Setter Property="BorderBrush" Value="#4FB8C0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <!-- Default WPF tooltips are light-on-light and do not wrap; restyle them
         so longer explanations are actually readable. -->
    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Background" Value="#11202A"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="HasDropShadow" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <TextBlock Text="{TemplateBinding Content}" TextWrapping="Wrap"
                         MaxWidth="330" Foreground="{TemplateBinding Foreground}"
                         FontSize="{TemplateBinding FontSize}" LineHeight="16"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,16,0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="200"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Border Grid.Row="0" Style="{StaticResource Card}" Padding="16,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal">
          <Path Width="26" Height="26" Stretch="Uniform" Fill="#4FB8C0"
                Data="M12 2 L21 6.5 V12 C21 17 17 21 12 22 C7 21 3 17 3 12 V6.5 Z M12 7 L12 15 M8.5 11 L12 7.5 L15.5 11"/>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Stopcode Toolkit" Foreground="#E7ECF3" FontSize="17" FontWeight="Bold"/>
            <TextBlock x:Name="TxtMachine" Text="" Foreground="#78838F" FontSize="11" FontFamily="Consolas"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" Margin="0,0,8,0" ToolTip="Memory committed against the total available (RAM plus pagefile). When this reaches the limit, programs stop being able to allocate and the desktop can collapse.">
            <StackPanel>
              <TextBlock Text="COMMIT" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtCommit" Text="--" Foreground="#E7ECF3" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" Margin="0,0,8,0" ToolTip="How much commit is still free. A demanding game can need 10 GB or more on its own. Green (18 GB or more) is comfortable, amber is tight, red (under 12 GB) means a demanding game is likely to cause problems.">
            <StackPanel>
              <TextBlock Text="HEADROOM" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtHead" Text="--" Foreground="#5BC08C" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" Margin="0,0,8,0" ToolTip="On an NVIDIA GPU: temperature and power draw from nvidia-smi, amber above 75 degrees and red above 85. On other GPUs (Intel, AMD): current 3D load from the Windows GPU counters, as Task Manager shows it.">
            <StackPanel>
              <TextBlock Text="GPU" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtGpu" Text="--" Foreground="#E7ECF3" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" ToolTip="Kernel error reports Windows has recorded (crashes, GPU engine timeouts, live dumps), with how many are new since the saved baseline. The Kernel faults card lists them by type.">
            <StackPanel>
              <TextBlock Text="FAULTS" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtFaults" Text="--" Foreground="#E0A93A" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <Button Grid.Column="2" x:Name="BtnRefresh" Margin="12,0,0,0" ToolTip="Re-read every value on this panel now, including the GPU (which is otherwise only polled every 20 seconds).">
          <StackPanel Orientation="Horizontal">
            <!-- Stroked, not filled: filling these open arcs drew a solid white blob. -->
            <Path Width="13" Height="13" Stretch="Uniform" Stroke="#E7ECF3" StrokeThickness="1.8"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                  Data="M20 12 A8 8 0 1 1 17.66 6.34 M17.66 1.5 L17.66 6.34 L12.8 6.34"/>
            <TextBlock Text="Refresh" Margin="7,0,0,0"/>
          </StackPanel>
        </Button>
      </Grid>
    </Border>

    <!-- body -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="400"/>
      </Grid.ColumnDefinitions>

      <!-- gaming mode -->
      <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <StackPanel Grid.Row="0" Orientation="Horizontal">
            <Path Width="20" Height="20" Stretch="Uniform" Fill="#4FB8C0"
                  Data="M7 8 H17 A5 5 0 0 1 17 18 H7 A5 5 0 0 1 7 8 Z M9 11 V15 M7 13 H11 M15.5 12.5 A0.9 0.9 0 1 0 15.5 12.4 M17.5 14.5 A0.9 0.9 0 1 0 17.5 14.4"/>
            <TextBlock Text="Gaming Mode" Style="{StaticResource H}" Margin="10,0,0,0"/>
          </StackPanel>
          <TextBlock Grid.Row="1" Style="{StaticResource Sub}"
                     Text="Pick a session type and what to close. Apps are asked to close politely first, so they save state. Protected system processes are never listed."/>

          <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,10">
            <RadioButton x:Name="RbVr"   Content="VR session"  GroupName="mode" ToolTip="VR session: start the VR runtime services found on this PC (Oculus / Meta, Virtual Desktop, SteamVR, Vive). Needs administrator rights, so expect a UAC prompt when you press Apply. Does nothing if no VR software is installed." />
            <RadioButton x:Name="RbFlat" Content="Flat / non-VR" GroupName="mode" IsChecked="True" ToolTip="Flat session: stop the VR services. They start with Windows and keep using CPU even when no headset is connected." />
            <Rectangle Width="1" Fill="#28313D" Margin="6,2,14,2"/>
            <Button x:Name="BtnPreClean"  Content="Clean" ToolTip="Tick every recommended app. Frees the most memory, but closes your browser too." />
            <Button x:Name="BtnPreBrowse" Content="Browse" ToolTip="Tick everything recommended except your web browsers (Chrome, Edge, Firefox, Brave, Opera, Vivaldi), so you can still look things up while playing." />
            <Button x:Name="BtnPreWork"   Content="Work" ToolTip="Keep your web browsers and VS Code open. Frees the least - check the headroom reading before using this with a demanding game." />
            <Button x:Name="BtnPreNone"   Content="None" ToolTip="Untick everything. Nothing will be closed when you press Apply." />
          </StackPanel>

          <Border Grid.Row="3" Background="#0F151D" BorderBrush="#28313D" BorderThickness="1" CornerRadius="4">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10,8">
              <StackPanel x:Name="PnlProcs" ToolTip="Programs currently using more than 150 MB. A green star marks ones that are safe to close and reopen later. Amber ones you may want to keep. System processes are never listed." />
            </ScrollViewer>
          </Border>

          <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,12,0,0">
            <Button x:Name="BtnApply" Style="{StaticResource Primary}" Content="Apply selection" ToolTip="Apply the VR choice, then close every ticked app. Each one is asked to close normally first so it can save; only apps that ignore that are forced after a few seconds." />
            <Button x:Name="BtnRescan" Content="Rescan" ToolTip="Rebuild the list from what is running right now. Useful after you have opened or closed things yourself." />
            <Button x:Name="BtnRestoreVr" Content="Restore VR stack" ToolTip="Start the VR services again and put the power plan back the way it was. Use this when you have finished playing." />
            <TextBlock x:Name="TxtSel" Text="" Foreground="#9EA9B8" FontSize="11.5"
                       VerticalAlignment="Center" Margin="10,0,0,0" FontFamily="Consolas"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- right column -->
      <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
        <StackPanel>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Path Width="18" Height="18" Stretch="Uniform" Fill="#E0A93A"
                      Data="M12 3 L22 20 H2 Z M12 9 V14 M12 16.5 V17.5"/>
                <TextBlock Text="Kernel faults" Style="{StaticResource H}" Margin="10,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="TxtFaultDetail" Style="{StaticResource Sub}" Text="--"/>
              <WrapPanel>
                <Button x:Name="BtnFaultCount"   Content="Count vs baseline" ToolTip="Compare the current kernel fault counts against the saved baseline, to see whether anything new has happened since." />
                <Button x:Name="BtnFaultBaseline" Content="Reset baseline" Margin="0,0,8,8" ToolTip="Save the current counts as the new baseline. Do this when you change something and want to measure its effect from now on." />
                <Button x:Name="BtnFaultAnalyze" Content="Analyse dumps" Margin="0,0,8,8" ToolTip="Collect crash dumps and error reports into the diag folder so they can be read. Needs administrator rights." />
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Path Width="18" Height="18" Stretch="Uniform" Fill="#5BC08C"
                      Data="M2 13 H6 L9 5 L14 19 L16.5 13 H22"/>
                <TextBlock Text="Monitoring" Style="{StaticResource H}" Margin="10,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="TxtMon" Style="{StaticResource Sub}" Text="--"/>
              <WrapPanel>
                <Button x:Name="BtnVideoReport" Content="Video-engine report" ToolTip="Show which programs have been using each GPU's video engines (decode, encode, processing). Video-engine timeouts (0x141) happen there, so this shows what might be triggering them. If the background logger has not recorded anything yet, it samples live for a minute first." />
                <Button x:Name="BtnGpuMonitor"  Content="GPU monitor (5 min)" Margin="0,0,8,8" ToolTip="Watch the GPU for five minutes (temperature, power and throttling on NVIDIA; engine load and memory on other GPUs), and report whether any new faults occurred." />
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Path Width="18" Height="18" Stretch="Uniform" Fill="#4FB8C0"
                      Data="M4 7 H20 M9 7 V4 H15 V7 M6 7 L7.2 20 H16.8 L18 7 M10 11 V17 M14 11 V17"/>
                <TextBlock Text="Disk cleanup" Style="{StaticResource H}" Margin="10,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="TxtDisk" Style="{StaticResource Sub}" Text="--"/>
              <WrapPanel>
                <Button x:Name="BtnCleanScan"  Content="Scan (dry run)" ToolTip="List what could be deleted and how much space it would free. Changes nothing." />
                <Button x:Name="BtnCleanApply" Content="Clean now" Margin="0,0,8,8" ToolTip="Delete regenerable caches and stale crash dumps. Never touches documents, Downloads or game installs. Needs admin." />
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Path Width="18" Height="18" Stretch="Uniform" Fill="#4FB8C0"
                      Data="M12 3 V14 M7.5 10 L12 14.5 L16.5 10 M4 17 V20 H20 V17"/>
                <TextBlock Text="Driver updates" Style="{StaticResource H}" Margin="10,0,0,0"/>
              </StackPanel>
              <TextBlock Style="{StaticResource Sub}"
                         Text="Checks Microsoft's catalogue only, so everything offered is WHQL-signed. Compares each offer against what is installed and flags downgrades. Nothing installs unless you pick it."/>
              <WrapPanel>
                <Button x:Name="BtnDriverScan"    Content="Check for updates"
                        ToolTip="Ask Windows Update what driver updates are available, compare each against the installed version, and flag any that would be a downgrade. Changes nothing."/>
                <Button x:Name="BtnDriverInstall" Content="Choose and install" Margin="0,0,8,8"
                        ToolTip="Same scan, then pick by number which updates to apply. Asks for confirmation before downloading. Needs administrator rights."/>
                <Button x:Name="BtnDriverAge"     Content="Installed by age" Margin="0,0,8,8"
                        ToolTip="List the installed third-party drivers oldest first. Age on its own is not a fault - many devices never get new drivers."/>
              </WrapPanel>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Path Width="18" Height="18" Stretch="Uniform" Fill="#9EA9B8"
                      Data="M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 M9 12 H16 M9 15.5 H16 M9 19 H13"/>
                <TextBlock Text="Report and tools" Style="{StaticResource H}" Margin="10,0,0,0"/>
              </StackPanel>
              <TextBlock Style="{StaticResource Sub}" Text="The written investigation, and the folder holding every script."/>
              <WrapPanel>
                <Button x:Name="BtnReport" Content="Open report" ToolTip="Open fault-report.html from the tools folder, if you have written one: what each fault was, how it was found, and what is still open. It is personal, so it is not part of the repo." />
                <Button x:Name="BtnFolder" Content="Open folder" Margin="0,0,8,8" ToolTip="Open the folder containing all of these scripts." />
              </WrapPanel>
            </StackPanel>
          </Border>

        </StackPanel>
      </ScrollViewer>
    </Grid>

    <!-- log -->
    <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,0,0,0" Padding="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
          <Path Width="15" Height="15" Stretch="Uniform" Fill="#78838F"
                Data="M4 5 H20 M4 10 H20 M4 15 H14 M4 20 H17"/>
          <TextBlock Text="Log" Style="{StaticResource H}" Margin="9,0,0,0" FontSize="12.5"/>
          <Button x:Name="BtnClearLog" Content="Clear" Padding="8,3" Margin="14,0,0,0" FontSize="11" ToolTip="Empty the log box below." />
          <Button x:Name="BtnCopyLog"  Content="Copy"  Padding="8,3" FontSize="11" ToolTip="Copy everything in the log to the clipboard, ready to paste." />
        </StackPanel>
        <TextBox Grid.Row="1" x:Name="TxtLog" IsReadOnly="True" TextWrapping="NoWrap"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 Background="#0F151D" Foreground="#D6DEE8" BorderBrush="#28313D"
                 FontFamily="Consolas" FontSize="11.5" Padding="8" ToolTip="Everything this panel does is recorded here, with timestamps. Copy it if you want to share what happened." />
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

# Pull every named element into a variable of the same name.
foreach ($n in @('TxtMachine','TxtCommit','TxtHead','TxtGpu','TxtFaults','BtnRefresh',
                 'RbVr','RbFlat','BtnPreClean','BtnPreBrowse','BtnPreWork','BtnPreNone',
                 'PnlProcs','BtnApply','BtnRescan','BtnRestoreVr','TxtSel',
                 'TxtFaultDetail','BtnFaultCount','BtnFaultBaseline','BtnFaultAnalyze',
                 'TxtMon','BtnVideoReport','BtnGpuMonitor',
                 'TxtDisk','BtnCleanScan','BtnCleanApply',
                 'BtnDriverScan','BtnDriverInstall','BtnDriverAge',
                 'BtnReport','BtnFolder','TxtLog','BtnClearLog','BtnCopyLog')) {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

# ------------------------------------------------------------------ utilities

# Windows PowerShell 5.1 has no ternary operator, and property setters for
# Brush / GridLength / Thickness do not reliably convert from strings here, so
# build them explicitly.
# Names here must not collide with built-in aliases: aliases resolve BEFORE
# functions, so a helper called "GL" silently becomes Get-Location.
$script:BrushConv = New-Object Windows.Media.BrushConverter
function New-Brush { param([string]$Hex) $script:BrushConv.ConvertFromString($Hex) }
function New-GridLength {
    param([string]$Spec)
    if ($Spec -eq '*') { New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star) }
    else               { New-Object Windows.GridLength ([double]$Spec) }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $tag = switch ($Level) { 'ok' { '  OK ' } 'warn' { ' WARN' } 'err' { ' ERR ' } default { '     ' } }
    $script:TxtLog.AppendText(('{0}{1}  {2}{3}' -f (Get-Date -Format 'HH:mm:ss'), $tag, $Message, [Environment]::NewLine))
    $script:TxtLog.ScrollToEnd()
}

# The status refresh runs on the UI thread every few seconds, so it must be
# fast. Get-Counter (~1 s), Win32_OperatingSystem (~0.3 s) and
# Get-ScheduledTask (~1.8 s each) together froze the window for ~5 s of every
# 6, which showed up as scroll lag. These native calls take milliseconds.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SysInfo {
  [StructLayout(LayoutKind.Sequential)]
  struct MEMORYSTATUSEX {
    public uint dwLength; public uint dwMemoryLoad;
    public ulong ullTotalPhys; public ulong ullAvailPhys;
    public ulong ullTotalPageFile; public ulong ullAvailPageFile;
    public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
  }
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
  // { committed bytes, commit limit } - the same values as the Memory counters.
  public static ulong[] Commit() {
    var m = new MEMORYSTATUSEX();
    m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
    if (!GlobalMemoryStatusEx(ref m)) return null;
    return new ulong[] { m.ullTotalPageFile - m.ullAvailPageFile, m.ullTotalPageFile };
  }
}
'@ -ErrorAction SilentlyContinue

function Get-Commit {
    try {
        $v = [SysInfo]::Commit()
        if (-not $v) { return $null }
        $c = [double]$v[0]; $l = [double]$v[1]
        [pscustomobject]@{ UsedGB = $c/1GB; LimitGB = $l/1GB; FreeGB = ($l-$c)/1GB; Pct = $c/$l*100 }
    } catch { $null }
}

# Task Scheduler over COM: ~15 ms per lookup instead of ~1.8 s for Get-ScheduledTask.
$script:TaskStates = @{ 0 = 'Unknown'; 1 = 'Disabled'; 2 = 'Queued'; 3 = 'Ready'; 4 = 'Running' }
$script:TaskFolder = $null
function Get-TaskState {
    param([string]$Name)
    try {
        if (-not $script:TaskFolder) {
            $svc = New-Object -ComObject Schedule.Service
            $svc.Connect()
            $script:TaskFolder = $svc.GetFolder('\')
        }
        $s = $script:TaskFolder.GetTask($Name).State
        if ($script:TaskStates.ContainsKey([int]$s)) { $script:TaskStates[[int]$s] } else { [string]$s }
    } catch { $null }   # GetTask throws when the task does not exist
}

$script:OsBuild = [Environment]::OSVersion.Version.Build

# A launched console - especially an elevated one - often opens behind this
# window, which makes it look as though nothing happened. Poll briefly for its
# window and pull it to the front. Done on a timer so the UI never blocks.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class FgWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
}
'@ -ErrorAction SilentlyContinue

function Show-LaunchedWindow {
    param([int]$ProcessId, [string]$ScriptName)
    $tries = 0
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(400)
    $t.Add_Tick({
        $script:__tries++
        $found = $null
        # An elevated relaunch spawns a *different* process, so look for any
        # console running this script rather than only the pid we started.
        try {
            $found = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -match [regex]::Escape($script:__scriptName) } |
                     Sort-Object CreationDate -Descending | Select-Object -First 1
        } catch { }
        if ($found) {
            $p = Get-Process -Id $found.ProcessId -ErrorAction SilentlyContinue
            if ($p -and $p.MainWindowHandle -ne 0) {
                [void][FgWin]::ShowWindow($p.MainWindowHandle, 9)
                [void][FgWin]::SetForegroundWindow($p.MainWindowHandle)
                $this.Stop()
                return
            }
        }
        if ($script:__tries -ge 15) { $this.Stop() }   # ~6 seconds, then give up
    })
    $script:__tries = 0
    $script:__scriptName = $ScriptName
    $t.Start()
}

function Start-Tool {
    param([string]$Script, [string[]]$Arguments = @(), [switch]$Elevated, [string]$Label)
    $path = Join-Path $Root $Script
    if (-not (Test-Path $path)) { Write-Log "missing: $Script" 'err'; return }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"{0}"' -f $path)) + $Arguments
    try {
        if ($Elevated) { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList | Out-Null }
        else           { Start-Process powershell.exe -ArgumentList $argList | Out-Null }
        $what = if ($Label) { $Label } else { $Script }
        Write-Log ("launched {0} - bringing its window to the front" -f $what) 'ok'
        Show-LaunchedWindow -ProcessId 0 -ScriptName $Script
    } catch {
        Write-Log ("could not launch {0}: {1}" -f $Script, $_.Exception.Message) 'err'
    }
}

# ------------------------------------------------------------- status refresh

$script:LastGpu = [datetime]::MinValue

function Update-Status {
    param([switch]$IncludeSlow)

    $c = Get-Commit
    if ($c) {
        $TxtCommit.Text = '{0:N1} / {1:N1} GB' -f $c.UsedGB, $c.LimitGB
        $TxtHead.Text   = '{0:N1} GB' -f $c.FreeGB
        $hex = if ($c.FreeGB -lt 12) { '#EA7A70' } elseif ($c.FreeGB -lt 18) { '#E0A93A' } else { '#5BC08C' }
        $TxtHead.Foreground = New-Brush $hex
    }

    try {
        $up = [TimeSpan]::FromMilliseconds([double][SysInfo]::GetTickCount64())
        $who = if ($script:Model) { '{0}   |   {1}' -f $env:COMPUTERNAME, $script:Model } else { $env:COMPUTERNAME }
        $TxtMachine.Text = '{0}   |   up {1:N0}h {2:N0}m   |   Win {3}' -f $who, [math]::Floor($up.TotalHours), $up.Minutes, $script:OsBuild
    } catch { }

    # Everything below touches the disk or other services. None of it changes
    # quickly, so read it every 30 s (or on Refresh) rather than every tick,
    # and keep the window responsive in between.
    if ($IncludeSlow -or ((Get-Date) - $script:LastSlow).TotalSeconds -ge 30) {
        $script:LastSlow = Get-Date
        Update-SlowStatus
    }

    # nvidia-smi spawns a process, so only poll it occasionally.
    if ($IncludeSlow -or ((Get-Date) - $script:LastGpu).TotalSeconds -gt 20) {
        $script:LastGpu = Get-Date
        try {
            $smi = 'C:\Windows\System32\nvidia-smi.exe'
            if (Test-Path $smi) {
                $r = (& $smi --query-gpu=temperature.gpu,power.draw,clocks.sm --format=csv,noheader,nounits 2>$null)
                if ($r) {
                    $p = ($r -split ',') | ForEach-Object { $_.Trim() }
                    $TxtGpu.Text = '{0}C  {1}W' -f $p[0], [math]::Round([double]$p[1])
                    $gHex = if ([int]$p[0] -ge 85) { '#EA7A70' } elseif ([int]$p[0] -ge 75) { '#E0A93A' } else { '#E7ECF3' }
                    $TxtGpu.Foreground = New-Brush $gHex
                }
            } else { Update-GpuLoad }
        } catch { }
    }
    # Pick up a background GPU-load sample that has finished since the last tick.
    Receive-GpuLoad
}

$script:LastSlow = [datetime]::MinValue

function Update-SlowStatus {
    # Kernel fault counts, read straight from the WER folders.
    try {
        $roots = @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                   "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")
        $counts = @{}
        foreach ($r in $roots) {
            if (-not (Test-Path $r)) { continue }
            Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'Kernel_*' } | ForEach-Object {
                    if ($_.Name -match '^Kernel_([0-9a-fA-F]+)_') {
                        $k = $matches[1].ToLower()
                        if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
                    }
                }
        }
        # Every bugcheck code counts, whatever this PC's problem happens to be.
        $total = 0; foreach ($v in $counts.Values) { $total += $v }

        # New since the baseline crash-count.ps1 saved, across all codes.
        $baseFile = Join-Path $Root 'crash-baseline.json'
        $newBy = @{}; $newTotal = 0; $hasBase = Test-Path $baseFile
        if ($hasBase) {
            $b = Get-Content $baseFile -Raw | ConvertFrom-Json
            foreach ($k in $counts.Keys) {
                $was = if ($b.PSObject.Properties[$k]) { [int]$b.$k } else { 0 }
                $d = $counts[$k] - $was
                if ($d -gt 0) { $newBy[$k] = $d; $newTotal += $d }
            }
        }

        $TxtFaults.Text = if ($newTotal) { '{0}  +{1} new' -f $total, $newTotal } else { [string]$total }
        $fHex = if ($newTotal) { '#EA7A70' } elseif ($total) { '#E0A93A' } else { '#5BC08C' }
        $TxtFaults.Foreground = New-Brush $fHex

        $nl = [Environment]::NewLine
        if (-not $total) {
            $detail = 'No kernel error reports recorded by Windows.'
        } else {
            $lines = foreach ($k in ($counts.Keys | Sort-Object { -$counts[$_] }, { $_ } | Select-Object -First 6)) {
                $name = if ($BugNames.ContainsKey($k)) { $BugNames[$k] } else { 'unrecognised code' }
                $tag  = if ($newBy.ContainsKey($k)) { '  (+{0} new)' -f $newBy[$k] } else { '' }
                '0x{0}  {1}: {2}{3}' -f $k.ToUpper(), $name, $counts[$k], $tag
            }
            $detail = ($lines -join $nl)
            if ($counts.Count -gt 6) { $detail += $nl + ('...and {0} more type(s)' -f ($counts.Count - 6)) }
        }
        if ($hasBase) {
            $detail += $nl + $(if ($newTotal) { '{0} new since the baseline.' -f $newTotal } else { 'Nothing new since the baseline.' })
        } else {
            $detail += $nl + 'No baseline yet - "Count vs baseline" saves one.'
        }
        $TxtFaultDetail.Text = $detail
    } catch { }

    # Monitoring task state.
    try {
        $w = Get-TaskState 'KernelDumpWatcher'
        $l = Get-TaskState 'VideoEngineLogger'
        $csv = Join-Path $Root 'diag\video-engine.csv'
        $rows = if (Test-Path $csv) { (Get-Content $csv -ErrorAction SilentlyContinue).Count - 1 } else { 0 }
        $wTxt = if ($w) { [string]$w } else { 'not installed' }
        $lTxt = if ($l) { [string]$l } else { 'not installed' }
        $TxtMon.Text = ('Dump watcher: {0}' -f $wTxt) + [Environment]::NewLine +
                       ('Video logger: {0}  ({1} rows)' -f $lTxt, $rows)
    } catch { }

    try {
        $d = New-Object IO.DriveInfo 'C'
        $used = $d.TotalSize - $d.AvailableFreeSpace
        $TxtDisk.Text = '{0:N0} GB free of {1:N0} GB  ({2:N0}% used)' -f ($d.AvailableFreeSpace/1GB), ($d.TotalSize/1GB), ($used/$d.TotalSize*100)
    } catch { }
}

# Without nvidia-smi, read 3D load from the Windows GPU counters (any vendor).
# That takes 1-3 s, so it runs in a background runspace and the result is
# collected on a later tick - the window never waits for it.
$script:GpuJob = $null
function Update-GpuLoad {
    if ($script:GpuJob) { return }   # previous sample still running
    $ps = [powershell]::Create().AddScript({
        $s = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples
        # Same method as Task Manager: sum each engine across processes, report the busiest.
        $eng = @{}
        foreach ($x in $s) {
            if ($x.InstanceName -match '^pid_\d+_(luid_.+_eng_\d+)_engtype_') {
                $eng[$matches[1]] = [double]$eng[$matches[1]] + $x.CookedValue
            }
        }
        if ($eng.Count) { [math]::Min(100, [math]::Round(($eng.Values | Measure-Object -Maximum).Maximum)) } else { -1 }
    })
    $script:GpuJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Receive-GpuLoad {
    $j = $script:GpuJob
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $script:GpuJob = $null
    try {
        $v = @($j.PS.EndInvoke($j.Handle))[0]
        if ($null -ne $v -and $v -ge 0) {
            $TxtGpu.Text = '3D {0}%' -f $v
            $TxtGpu.Foreground = New-Brush '#E7ECF3'
        } else { $TxtGpu.Text = 'n/a' }
    } catch { $TxtGpu.Text = 'n/a' }
    finally { $j.PS.Dispose() }
}

# ----------------------------------------------------------- process picker

$script:Rows = @()

function Build-ProcessList {
    $PnlProcs.Children.Clear()
    $script:Rows = @()

    $cands = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $Protected -notcontains $_.ProcessName } |
        Group-Object ProcessName |
        ForEach-Object {
            [pscustomobject]@{
                Name     = $_.Name
                Count    = $_.Count
                CommitMB = [math]::Round((($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum)/1MB)
                Ids      = @($_.Group | Select-Object -ExpandProperty Id)
            }
        } |
        Where-Object { $_.CommitMB -ge 150 } |
        Sort-Object CommitMB -Descending

    foreach ($c in $cands) {
        $isRec = $Recommend.ContainsKey($c.Name)
        $note  = if ($isRec) { $Recommend[$c.Name] }
                 elseif ($Caution.ContainsKey($c.Name)) { 'keep? ' + $Caution[$c.Name] }
                 else { '' }

        $g = New-Object Windows.Controls.Grid
        $g.Margin = New-Object Windows.Thickness 0, 3, 0, 3
        foreach ($w in @('26','210','60','90','*')) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = New-GridLength $w
            [void]$g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object Windows.Controls.CheckBox
        $cb.VerticalAlignment = 'Center'
        $cb.Tag = $c
        [void]$g.Children.Add($cb)
        [Windows.Controls.Grid]::SetColumn($cb, 0)

        # Per-row help: what it is, how much it would free, and whether it is
        # safe to close - so the list explains itself without a manual.
        $verdict = if ($isRec) {
            'Recommended to close: ' + $Recommend[$c.Name]
        } elseif ($Caution.ContainsKey($c.Name)) {
            'Not recommended: ' + $Caution[$c.Name]
        } else {
            'Not recognised, so not recommended. Close it only if you know what it is.'
        }
        $tip = ('{0} - {1} process(es), about {2} MB of commit.  {3}  ' -f `
                   $c.Name, $c.Count, $c.CommitMB, $verdict) +
               'Ticked apps are asked to close normally first, so unsaved work can be saved.'
        $g.ToolTip = $tip
        $g.Background = New-Brush '#00000000'   # hit-test surface so hover works across the row

        $mk = { param($txt,$col,$fs,$mono)
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = $txt
            $t.Foreground = New-Brush $col
            $t.FontSize = $fs
            $t.VerticalAlignment = 'Center'
            $t.TextTrimming = 'CharacterEllipsis'
            if ($mono) { $t.FontFamily = 'Consolas' }
            $t
        }
        $nameCol = if ($isRec) { '#5BC08C' } elseif ($Caution.ContainsKey($c.Name)) { '#E0A93A' } else { '#E7ECF3' }
        $t1 = & $mk ($(if ($isRec) { '* ' } else { '  ' }) + $c.Name) $nameCol 12 $true
        $t2 = & $mk ('x' + $c.Count) '#78838F' 11 $true
        $sz = if ($c.CommitMB -ge 1024) { '{0:N1} GB' -f ($c.CommitMB/1024) } else { '{0} MB' -f $c.CommitMB }
        $t3 = & $mk $sz '#9EA9B8' 11.5 $true
        $t4 = & $mk $note '#78838F' 11 $false
        $i = 1
        foreach ($t in @($t1,$t2,$t3,$t4)) {
            [void]$g.Children.Add($t)
            [Windows.Controls.Grid]::SetColumn($t, $i)
            $i++
        }

        [void]$PnlProcs.Children.Add($g)
        $script:Rows += [pscustomobject]@{ Box = $cb; Info = $c; Recommended = $isRec }
    }

    $cb_handler = { Update-SelectionText }
    foreach ($r in $script:Rows) {
        $r.Box.Add_Checked($cb_handler)
        $r.Box.Add_Unchecked($cb_handler)
    }
    Update-SelectionText
    Write-Log ("process list rebuilt - {0} entries over 150 MB" -f $script:Rows.Count)
}

function Update-SelectionText {
    $sel = @($script:Rows | Where-Object { $_.Box.IsChecked })
    $mb  = ($sel | ForEach-Object { $_.Info.CommitMB } | Measure-Object -Sum).Sum
    if (-not $mb) { $mb = 0 }
    $TxtSel.Text = '{0} selected, frees ~{1:N1} GB' -f $sel.Count, ($mb/1024)
}

function Set-Preset {
    param([string]$Name)
    $keep = $Presets[$Name]
    foreach ($r in $script:Rows) {
        $r.Box.IsChecked = ($r.Recommended -and ($keep -notcontains $r.Info.Name))
    }
    Update-SelectionText
    Write-Log ("preset '{0}' applied{1}" -f $Name, $(if ($keep.Count) { ' - keeping ' + ($keep -join ', ') } else { '' }))
}

# ------------------------------------------------------------------- actions

$BtnRefresh.Add_Click({ Update-Status -IncludeSlow; Write-Log 'readings refreshed' })
$BtnRescan.Add_Click({ Build-ProcessList })
$BtnPreClean.Add_Click({ Set-Preset 'clean' })
$BtnPreBrowse.Add_Click({ Set-Preset 'browse' })
$BtnPreWork.Add_Click({ Set-Preset 'work' })
$BtnPreNone.Add_Click({ foreach ($r in $script:Rows) { $r.Box.IsChecked = $false }; Update-SelectionText; Write-Log 'selection cleared' })

$BtnApply.Add_Click({
    $sel = @($script:Rows | Where-Object { $_.Box.IsChecked })
    $vr  = $RbVr.IsChecked

    # VR stack first - it needs elevation and may change what is running.
    $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
           Where-Object { ($_.Name -match 'OVR|Oculus|VirtualDesktop' -or $_.DisplayName -match 'Oculus|Virtual Desktop|SteamVR|Vive') -and $_.Name -notmatch 'LibraryService' }
    if ($svc) {
        $want = if ($vr) { 'Running' } else { 'Stopped' }
        $todo = @($svc | Where-Object { $_.State -ne $want })
        if (-not $todo) {
            Write-Log ("VR stack already {0}" -f $want.ToLower()) 'ok'
        } else {
            $names = ($todo | Select-Object -ExpandProperty Name) -join ','
            $verb  = if ($vr) { 'Start-Service' } else { 'Stop-Service -Force' }
            $cmd   = "`$ErrorActionPreference='SilentlyContinue'; '$names'.Split(',') | ForEach-Object { $verb -Name `$_ }"
            try {
                Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-Command', $cmd) -Wait
                Write-Log ("VR stack -> {0}  ({1})" -f $want.ToLower(), $names) 'ok'
            } catch {
                Write-Log 'VR change cancelled or failed (needs elevation)' 'warn'
            }
        }
    }

    if (-not $sel) { Write-Log 'nothing selected to close'; Update-Status -IncludeSlow; return }

    $before = Get-Commit
    foreach ($r in $sel) {
        $c = $r.Info
        foreach ($procId in $c.Ids) {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($p) { try { [void]$p.CloseMainWindow() } catch { } }
        }
    }
    Start-Sleep -Milliseconds 1800
    foreach ($r in $sel) {
        $left = @($r.Info.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        $still = @($r.Info.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count
        if ($still -eq 0) { Write-Log ("closed {0} (~{1} MB)" -f $r.Info.Name, $r.Info.CommitMB) 'ok' }
        else { Write-Log ("{0}: {1} process(es) would not close" -f $r.Info.Name, $still) 'warn' }
    }
    Start-Sleep -Milliseconds 800
    $after = Get-Commit
    if ($before -and $after) {
        Write-Log ("commit {0:N1} -> {1:N1} GB, headroom now {2:N1} GB" -f $before.UsedGB, $after.UsedGB, $after.FreeGB) 'ok'
        if ($after.FreeGB -lt 12) { Write-Log 'headroom under 12 GB - a demanding game can commit 10 GB on its own' 'warn' }
    }
    Build-ProcessList
    Update-Status -IncludeSlow
})

$BtnRestoreVr.Add_Click({ Start-Tool 'gaming-mode.ps1' @('-Restore') -Elevated -Label 'gaming-mode -Restore' })
$BtnFaultCount.Add_Click({ Start-Tool 'crash-count.ps1' -Label 'crash-count' })
$BtnFaultBaseline.Add_Click({ Start-Tool 'crash-count.ps1' @('-Reset') -Label 'crash-count -Reset' })
$BtnFaultAnalyze.Add_Click({ Start-Tool 'collect-crash.ps1' -Elevated -Label 'collect-crash' })
$BtnVideoReport.Add_Click({ Start-Tool 'log-video-engine.ps1' @('-Report') -Label 'video-engine report' })
$BtnGpuMonitor.Add_Click({ Start-Tool 'gpu-monitor.ps1' @('-Minutes','5') -Label 'gpu-monitor' })
$BtnDriverScan.Add_Click({ Start-Tool 'driver-check.ps1' -Label 'driver scan' })
$BtnDriverInstall.Add_Click({ Start-Tool 'driver-check.ps1' @('-Install') -Label 'driver install' })
$BtnDriverAge.Add_Click({ Start-Tool 'driver-check.ps1' @('-Inventory') -Label 'driver inventory' })
$BtnCleanScan.Add_Click({ Start-Tool 'cleanup.ps1' -Label 'cleanup (dry run)' })
$BtnCleanApply.Add_Click({ Start-Tool 'cleanup.ps1' @('-Apply','-IncludeSystem') -Elevated -Label 'cleanup -Apply' })

$BtnReport.Add_Click({
    $p = Join-Path $Root 'fault-report.html'
    if (Test-Path $p) { Start-Process $p; Write-Log 'opened fault-report.html' 'ok' }
    else { Write-Log 'no fault-report.html in the tools folder - it is a personal write-up and not part of the repo' 'warn' }
})
$BtnFolder.Add_Click({ Start-Process explorer.exe $Root; Write-Log 'opened tools folder' })
$BtnClearLog.Add_Click({ $TxtLog.Clear() })
$BtnCopyLog.Add_Click({
    try { Set-Clipboard -Value $TxtLog.Text; Write-Log 'log copied to clipboard' 'ok' }
    catch { Write-Log 'could not access clipboard' 'warn' }
})

# ---------------------------------------------------------------------- start

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(6)
$timer.Add_Tick({ try { Update-Status } catch { } })
$timer.Start()

$win.Add_Loaded({
    Write-Log 'control panel ready'
    Update-Status -IncludeSlow
    Build-ProcessList
})
$win.Add_Closed({ $timer.Stop() })

[void]$win.ShowDialog()
