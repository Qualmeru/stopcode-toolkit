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
$Presets = @{
    'clean'  = @()
    'browse' = @('chrome')
    'work'   = @('chrome','msedge','firefox','Code')
}

# --------------------------------------------------------------------- layout

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZenBook Control Panel" Height="820" Width="1200"
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
            <TextBlock Text="ZenBook Control Panel" Foreground="#E7ECF3" FontSize="17" FontWeight="Bold"/>
            <TextBlock x:Name="TxtMachine" Text="" Foreground="#78838F" FontSize="11" FontFamily="Consolas"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" Margin="0,0,8,0" ToolTip="Memory committed against the total available (RAM plus pagefile). When this reaches the limit, programs stop being able to allocate and the desktop can collapse - which has happened twice on this machine.">
            <StackPanel>
              <TextBlock Text="COMMIT" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtCommit" Text="--" Foreground="#E7ECF3" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" Margin="0,0,8,0" ToolTip="How much commit is still free. Witcher 3 on its own needs about 10 GB. Green is comfortable, amber is tight, red means a demanding game is likely to cause problems.">
            <StackPanel>
              <TextBlock Text="HEADROOM" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtHead" Text="--" Foreground="#5BC08C" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" Margin="0,0,8,0" ToolTip="Current temperature and power draw of an NVIDIA GPU, read from nvidia-smi. Turns amber above 75 degrees and red above 85. Shows n/a when there is no NVIDIA GPU.">
            <StackPanel>
              <TextBlock Text="GPU" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtGpu" Text="--" Foreground="#E7ECF3" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
          <Border Background="#11202A" CornerRadius="4" Padding="12,7" ToolTip="Kernel faults recorded by Windows, shown as 0x141 / 0x193 / 0xA. The 0x141 engine timeouts come from Intel's display driver and are the long-running problem on this machine.">
            <StackPanel>
              <TextBlock Text="FAULTS" Foreground="#78838F" FontSize="9" FontFamily="Consolas"/>
              <TextBlock x:Name="TxtFaults" Text="--" Foreground="#E0A93A" FontSize="13" FontFamily="Consolas"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <Button Grid.Column="2" x:Name="BtnRefresh" Margin="12,0,0,0" ToolTip="Re-read every value on this panel now, including the GPU (which is otherwise only polled every 20 seconds).">
          <StackPanel Orientation="Horizontal">
            <Path Width="13" Height="13" Stretch="Uniform" Fill="#E7ECF3"
                  Data="M12 4 A8 8 0 1 0 20 12 M12 4 L12 0.5 M12 4 L15.5 7"/>
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
            <RadioButton x:Name="RbVr"   Content="VR session"  GroupName="mode" ToolTip="VR session: start the Oculus runtime and Virtual Desktop services. Needs administrator rights, so expect a UAC prompt when you press Apply." />
            <RadioButton x:Name="RbFlat" Content="Flat / non-VR" GroupName="mode" IsChecked="True" ToolTip="Flat session: stop the VR services. They start with Windows and keep using CPU even when no headset is connected." />
            <Rectangle Width="1" Fill="#28313D" Margin="6,2,14,2"/>
            <Button x:Name="BtnPreClean"  Content="Clean" ToolTip="Tick every recommended app. Frees the most memory, but closes your browser too." />
            <Button x:Name="BtnPreBrowse" Content="Browse" ToolTip="Tick everything recommended except Chrome, so you can still look things up while playing." />
            <Button x:Name="BtnPreWork"   Content="Work" ToolTip="Keep Chrome, Edge, Firefox and VS Code open. Frees the least - check the headroom reading before using this with a demanding game." />
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
                <Button x:Name="BtnVideoReport" Content="Video-engine report" ToolTip="Show which programs have been using each GPU's video engines. Intel's video engine is where the 0x141 faults happen, so this shows what might be triggering them." />
                <Button x:Name="BtnGpuMonitor"  Content="GPU monitor (5 min)" Margin="0,0,8,8" ToolTip="Watch the GPU for five minutes (temperature, power and throttling on NVIDIA; engine load and memory on other GPUs), and report whether any new faults occurred." />
                <Button x:Name="BtnMonRemove"   Content="Remove monitoring" Margin="0,0,8,8"
                        ToolTip="Unregister both background tasks. Collected data in diag is left alone. Installing is offered automatically when a tool needs a task that is missing."/>
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
                <Button x:Name="BtnReport" Content="Open report" ToolTip="Open the written investigation: what each fault was, how it was found, and what is still open." />
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
                 'TxtMon','BtnVideoReport','BtnGpuMonitor','BtnMonRemove',
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

# Names that have proved they will not close, remembered between runs so the
# presets stop wasting attempts on them. Shared with gaming-mode.ps1.
$script:WontCloseFile = Join-Path $Root 'diag\wont-close.txt'

function Get-WontClose {
    if (Test-Path $script:WontCloseFile) {
        return @(Get-Content $script:WontCloseFile -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return @()
}

function Add-WontClose {
    param([string]$Name)
    $all = @(Get-WontClose) + $Name | Select-Object -Unique
    New-Item -ItemType Directory -Path (Split-Path $script:WontCloseFile) -Force | Out-Null
    Set-Content -LiteralPath $script:WontCloseFile -Value $all -Encoding utf8
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-ServiceProcessMap {
    $m = @{}
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -gt 0 } |
        ForEach-Object { $m[[int]$_.ProcessId] = $_.Name }
    return $m
}

function Get-Commit {
    try {
        $s = (Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit' -ErrorAction Stop).CounterSamples
        $c = ($s | Where-Object { $_.Path -match 'Committed' }).CookedValue
        $l = ($s | Where-Object { $_.Path -match 'Limit' }).CookedValue
        [pscustomobject]@{ UsedGB = $c/1GB; LimitGB = $l/1GB; FreeGB = ($l-$c)/1GB; Pct = $c/$l*100 }
    } catch { $null }
}

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
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $up = ((Get-Date) - $os.LastBootUpTime)
        $TxtMachine.Text = '{0}   |   up {1:N0}h {2:N0}m   |   Win {3}' -f $env:COMPUTERNAME, $up.TotalHours, $up.Minutes, $os.BuildNumber
    } catch { }

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
        $g141 = if ($counts.ContainsKey('141')) { $counts['141'] } else { 0 }
        $g193 = if ($counts.ContainsKey('193')) { $counts['193'] } else { 0 }
        $gA   = if ($counts.ContainsKey('a'))   { $counts['a'] }   else { 0 }
        $TxtFaults.Text = '{0} / {1} / {2}' -f $g141, $g193, $gA

        $baseFile = Join-Path $Root 'crash-baseline.json'
        $deltaTxt = ''
        if (Test-Path $baseFile) {
            $b = Get-Content $baseFile -Raw | ConvertFrom-Json
            $b141 = if ($b.'141') { [int]$b.'141' } else { 0 }
            $d = $g141 - $b141
            $deltaTxt = if ($d -gt 0) { "  ({0} new 0x141 since baseline)" -f $d } else { '  (no new 0x141 since baseline)' }
        }
        $TxtFaultDetail.Text = ('0x141 engine timeout: {0}' -f $g141) + [Environment]::NewLine +
                               ('0x193 dxgkrnl livedump: {0}' -f $g193) + [Environment]::NewLine +
                               ('0xA bugcheck: {0}' -f $gA) + $deltaTxt
    } catch { }

    # Monitoring task state.
    try {
        $w = (Get-ScheduledTask -TaskName 'KernelDumpWatcher' -ErrorAction SilentlyContinue).State
        $l = (Get-ScheduledTask -TaskName 'VideoEngineLogger' -ErrorAction SilentlyContinue).State
        $csv = Join-Path $Root 'diag\video-engine.csv'
        $rows = if (Test-Path $csv) { (Get-Content $csv -ErrorAction SilentlyContinue).Count - 1 } else { 0 }
        $wTxt = if ($w) { [string]$w } else { 'not installed' }
        $lTxt = if ($l) { [string]$l } else { 'not installed' }
        $TxtMon.Text = ('Dump watcher: {0}' -f $wTxt) + [Environment]::NewLine +
                       ('Video logger: {0}  ({1} rows)' -f $lTxt, $rows)
    } catch { }

    try {
        $d = Get-PSDrive C -ErrorAction Stop
        $TxtDisk.Text = '{0:N0} GB free of {1:N0} GB  ({2:N0}% used)' -f ($d.Free/1GB), (($d.Free+$d.Used)/1GB), ($d.Used/($d.Free+$d.Used)*100)
    } catch { }

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
            } else { $TxtGpu.Text = 'n/a' }
        } catch { }
    }
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

    $stubborn = @(Get-WontClose)
    $svcMapUi = Get-ServiceProcessMap

    foreach ($c in $cands) {
        $isStubborn = $stubborn -contains $c.Name
        $isService  = @($c.Ids | Where-Object { $svcMapUi.ContainsKey($_) }).Count -gt 0
        $isRec = $Recommend.ContainsKey($c.Name) -and -not $isStubborn
        $note  = if ($isStubborn) { 'skipped - would not close before' }
                 elseif ($isService) { 'service - needs the panel run as admin' }
                 elseif ($isRec) { $Recommend[$c.Name] }
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
        $nameCol = if ($isStubborn) { '#78838F' }
                   elseif ($isService) { '#4FB8C0' }
                   elseif ($isRec) { '#5BC08C' }
                   elseif ($Caution.ContainsKey($c.Name)) { '#E0A93A' }
                   else { '#E7ECF3' }
        $prefix = if ($isRec) { '* ' } elseif ($isStubborn) { 'x ' } else { '  ' }
        $t1 = & $mk ($prefix + $c.Name) $nameCol 12 $true
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
    $svcMap = Get-ServiceProcessMap
    $admin  = Test-Admin

    # Service-backed processes cannot be closed with Stop-Process; separate them
    # out before wasting an attempt and reporting a failure that was never going
    # to succeed.
    $plain = @()
    foreach ($r in $sel) {
        $svcNames = @($r.Info.Ids | Where-Object { $svcMap.ContainsKey($_) } | ForEach-Object { $svcMap[$_] } | Select-Object -Unique)
        if (-not $svcNames) { $plain += $r; continue }
        if (-not $admin) {
            Write-Log ("{0} is a service ({1}) - skipped, needs an elevated run" -f $r.Info.Name, ($svcNames -join ', ')) 'warn'
            continue
        }
        foreach ($s in $svcNames) {
            try {
                Stop-Service -Name $s -Force -ErrorAction Stop
                Write-Log ("stopped service {0} ({1}, ~{2} MB)" -f $s, $r.Info.Name, $r.Info.CommitMB) 'ok'
            } catch {
                Write-Log ("could not stop service {0}" -f $s) 'warn'
                Add-WontClose $r.Info.Name
            }
        }
    }

    foreach ($r in $plain) {
        foreach ($procId in $r.Info.Ids) {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($p) { try { [void]$p.CloseMainWindow() } catch { } }
        }
    }
    Start-Sleep -Milliseconds 1800
    foreach ($r in $plain) {
        $left = @($r.Info.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    # Let Windows reap them before counting. Checking immediately reported
    # failures for apps that were in fact closing.
    Start-Sleep -Milliseconds 900
    foreach ($r in $plain) {
        $still = @($r.Info.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count
        if ($still -eq 0) {
            Write-Log ("closed {0} (~{1} MB)" -f $r.Info.Name, $r.Info.CommitMB) 'ok'
            continue
        }
        if (@(Get-Process -Name $r.Info.Name -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Log ("{0} respawns immediately - skipping it from now on" -f $r.Info.Name) 'warn'
        } else {
            Write-Log ("{0}: {1} process(es) refused to close" -f $r.Info.Name, $still) 'warn'
        }
        Add-WontClose $r.Info.Name
    }
    Start-Sleep -Milliseconds 800
    $after = Get-Commit
    if ($before -and $after) {
        Write-Log ("commit {0:N1} -> {1:N1} GB, headroom now {2:N1} GB" -f $before.UsedGB, $after.UsedGB, $after.FreeGB) 'ok'
        if ($after.FreeGB -lt 12) { Write-Log 'headroom under 12 GB - Witcher 3 alone commits ~10 GB' 'warn' }
    }
    Build-ProcessList
    Update-Status -IncludeSlow
})

$BtnRestoreVr.Add_Click({ Start-Tool 'gaming-mode.ps1' @('-Restore') -Elevated -Label 'gaming-mode -Restore' })
$BtnFaultCount.Add_Click({ Start-Tool 'crash-count.ps1' -Label 'crash-count' })
$BtnFaultBaseline.Add_Click({ Start-Tool 'crash-count.ps1' @('-Reset') -Label 'crash-count -Reset' })
$BtnFaultAnalyze.Add_Click({
    # Same pattern as the video report: offer the missing piece rather than
    # letting the user find out later that nothing was being recorded.
    if (-not (Get-ScheduledTask -TaskName 'KernelDumpWatcher' -ErrorAction SilentlyContinue)) {
        Write-Log 'dump watcher is not installed' 'warn'
        $answer = [System.Windows.MessageBox]::Show(
            ("The dump watcher is not installed." + [Environment]::NewLine + [Environment]::NewLine +
             "It parses each new crash dump and tells you which driver faulted, and records live kernel events with the time they happened. Without it, a fault leaves little you can act on - and the evidence expires at the next restart." + [Environment]::NewLine + [Environment]::NewLine +
             "Install it now? It starts at logon and needs one UAC prompt." + [Environment]::NewLine + [Environment]::NewLine +
             "Choosing No still collects whatever dumps already exist."),
            'Watcher not installed',
            [System.Windows.MessageBoxButton]::YesNoCancel,
            [System.Windows.MessageBoxImage]::Question)

        if ($answer -eq [System.Windows.MessageBoxResult]::Cancel) { Write-Log 'cancelled'; return }
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            Start-Tool 'watch-dumps.ps1' @('-Install') -Label 'watcher install'
            return
        }
    }
    Start-Tool 'collect-crash.ps1' -Elevated -Label 'collect-crash'
})
# The report is only meaningful if something has been logging, so check the
# task exists before opening a window that would just say "no log yet".
$BtnVideoReport.Add_Click({
    $task = Get-ScheduledTask -TaskName 'VideoEngineLogger' -ErrorAction SilentlyContinue
    $csv  = Join-Path $Root 'diag\video-engine.csv'
    $rows = 0
    if (Test-Path $csv) { $rows = [Math]::Max(0, (Get-Content $csv -ErrorAction SilentlyContinue).Count - 1) }

    if (-not $task) {
        Write-Log 'video-engine logger is not installed' 'warn'
        $answer = [System.Windows.MessageBox]::Show(
            ("The video-engine logger is not installed, so there is nothing to report on yet." + [Environment]::NewLine + [Environment]::NewLine +
             "It records which process uses which GPU's video engines, every 20 seconds. That is what identifies whatever is driving Intel's video engine when a 0x141 fault happens." + [Environment]::NewLine + [Environment]::NewLine +
             "Install it now? It starts at logon and needs one UAC prompt."),
            'Logger not installed',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question)

        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            Start-Tool 'log-video-engine.ps1' @('-Install') -Label 'logger install'
            Write-Log 'once installed, give it a while to collect before asking for a report'
        } else {
            Write-Log 'logger not installed - report skipped'
        }
        return
    }

    if ($task.State -ne 'Running') {
        Write-Log ("logger task exists but is {0} - the report may be stale" -f $task.State) 'warn'
    }
    if ($rows -eq 0) {
        Write-Log 'logger is installed but has recorded nothing yet - try again later' 'warn'
        return
    }

    Write-Log ("opening report over {0} recorded samples" -f $rows)
    Start-Tool 'log-video-engine.ps1' @('-Report') -Label 'video-engine report'
})
$BtnGpuMonitor.Add_Click({ Start-Tool 'gpu-monitor.ps1' @('-Minutes','5') -Label 'gpu-monitor' })

$BtnMonRemove.Add_Click({
    Write-Log 'removing both monitoring tasks - collected data in diag is kept' 'warn'
    Start-Tool 'watch-dumps.ps1'      @('-Uninstall') -Label 'watcher remove'
    Start-Tool 'log-video-engine.ps1' @('-Uninstall') -Label 'logger remove'
})
$BtnDriverScan.Add_Click({ Start-Tool 'driver-check.ps1' -Label 'driver scan' })
$BtnDriverInstall.Add_Click({ Start-Tool 'driver-check.ps1' @('-Install') -Label 'driver install' })
$BtnDriverAge.Add_Click({ Start-Tool 'driver-check.ps1' @('-Inventory') -Label 'driver inventory' })
$BtnCleanScan.Add_Click({ Start-Tool 'cleanup.ps1' -Label 'cleanup (dry run)' })
$BtnCleanApply.Add_Click({ Start-Tool 'cleanup.ps1' @('-Apply','-IncludeSystem') -Elevated -Label 'cleanup -Apply' })

$BtnReport.Add_Click({
    $p = Join-Path $Root 'fault-report.html'
    if (Test-Path $p) { Start-Process $p; Write-Log 'opened fault-report.html' 'ok' }
    else { Write-Log 'fault-report.html not found' 'err' }
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
