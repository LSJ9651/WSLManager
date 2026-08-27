# WSLManager.GUI.ps1
# WSL 发行版管理工具 —— WPF 图形界面主程序
# 依赖：WSLManager.Engine.psm1（同目录）
# 兼容 PowerShell 5.1，主进程以普通权限运行（仅写操作按需提权）

# ========== 1. 加载程序集与引擎 ==========
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:EnginePath = Join-Path $PSScriptRoot "WSLManager.Engine.psm1"
# -DisableNameChecking：抑制"非标准动词"警告（Get-WSL* 等函数名是刻意命名，非错误）
Import-Module $script:EnginePath -Force -DisableNameChecking

# ========== 2. 全局状态 ==========
$script:SelectedInstance = $null
$script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:BgTasks = @{}
$script:IsBusy = $false
$script:ActiveProgress = $null

# ========== 3. 主题配色 ==========
$script:ThemeLight = @{
    WindowBg     = "#F3F4F6"
    CardBg       = "#FFFFFF"
    CardBorder   = "#E5E7EB"
    TextPrimary  = "#111827"
    TextSecondary = "#6B7280"
    Accent       = "#2563EB"
    AccentHover  = "#1D4ED8"
    Danger       = "#DC2626"
    DangerHover  = "#B91C1C"
    Success      = "#16A34A"
    Warning      = "#D97706"
    Running      = "#16A34A"
    Stopped      = "#9CA3AF"
    PanelBg      = "#FFFFFF"
    HoverBg      = "#F9FAFB"
    TitleBg      = "#FFFFFF"
}

$script:ThemeDark = @{
    WindowBg     = "#1E1F22"
    CardBg       = "#2B2D31"
    CardBorder   = "#3F4248"
    TextPrimary  = "#E8E8E8"
    TextSecondary = "#9CA3AF"
    Accent       = "#3B82F6"
    AccentHover  = "#2563EB"
    Danger       = "#EF4444"
    DangerHover  = "#DC2626"
    Success      = "#22C55E"
    Warning      = "#F59E0B"
    Running      = "#22C55E"
    Stopped      = "#6B7280"
    PanelBg      = "#2B2D31"
    HoverBg      = "#32353A"
    TitleBg      = "#2B2D31"
}

$script:Theme = $script:ThemeLight

function Get-IsDarkTheme {
    try {
        $v = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction Stop).AppsUseLightTheme
        return ($v -eq 0)
    } catch {
        return $false
    }
}

function ConvertTo-Brush {
    param([string]$Hex)
    $hex = "$Hex".TrimStart('#')
    # 防御性校验：长度不足/非十六进制时返回透明画刷，避免 Substring 越界刷屏
    if ($hex.Length -lt 6) {
        return [System.Windows.Media.Brushes]::Transparent
    }
    try {
        $r = [Convert]::ToByte($hex.Substring(0, 2), 16)
        $g = [Convert]::ToByte($hex.Substring(2, 2), 16)
        $b = [Convert]::ToByte($hex.Substring(4, 2), 16)
        $c = [System.Windows.Media.Color]::FromRgb($r, $g, $b)
        $brush = New-Object System.Windows.Media.SolidColorBrush($c)
        $brush.Freeze()
        return $brush
    } catch {
        return [System.Windows.Media.Brushes]::Transparent
    }
}

# ========== 4. XAML 主窗口 ==========
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WSL 系统管理器"
        Width="1000" Height="680" MinWidth="920" MinHeight="600"
        WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13"
        Background="#F3F4F6">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="58"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="30"/>
        </Grid.RowDefinitions>

        <!-- 顶部标题栏 -->
        <Border x:Name="TitleBar" Grid.Row="0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1">
            <Grid Margin="16,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="AppTitle" Text="WSL 系统管理器" FontSize="18" FontWeight="SemiBold" Foreground="#111827" VerticalAlignment="Center"/>
                    <Border x:Name="WslStatusBadge" CornerRadius="9" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Center" Background="#16A34A">
                        <TextBlock x:Name="WslStatusText" Text="WSL 就绪" Foreground="White" FontSize="11"/>
                    </Border>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnNew" Content="新增系统" Margin="4,0" Padding="14,7" Cursor="Hand"/>
                    <Button x:Name="BtnBackup" Content="备份" Margin="4,0" Padding="14,7" Cursor="Hand"/>
                    <Button x:Name="BtnRestore" Content="还原" Margin="4,0" Padding="14,7" Cursor="Hand"/>
                    <Button x:Name="BtnDelete" Content="删除" Margin="4,0" Padding="14,7" Cursor="Hand"/>
                    <Button x:Name="BtnSettings" Content="设置" Margin="4,0" Padding="14,7" Cursor="Hand"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 主体 -->
        <Grid Grid.Row="1" Margin="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="320"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- 左侧：实例列表 -->
            <Border x:Name="LeftPanel" Grid.Column="0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="0,0,1,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="16,14,16,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="LeftTitle" Text="我的系统" FontSize="15" FontWeight="SemiBold" Foreground="#111827" VerticalAlignment="Center"/>
                        <Button x:Name="BtnRefresh" Grid.Column="1" Content="刷新" Padding="10,4" Cursor="Hand"/>
                    </Grid>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                        <StackPanel x:Name="InstanceListPanel" Margin="10,0,10,10"/>
                    </ScrollViewer>
                </Grid>
            </Border>

            <!-- 右侧：统计 + 详情 + 进度 + 日志 -->
            <Grid Grid.Column="1" Margin="16">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- 统计卡片 -->
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Border x:Name="StatCard1" Grid.Column="0" CornerRadius="10" Padding="16,12" Margin="0,0,8,0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1">
                        <StackPanel>
                            <TextBlock x:Name="StatLabel1" Text="磁盘占用总量" FontSize="12" Foreground="#6B7280"/>
                            <TextBlock x:Name="StatTotalSize" Text="—" FontSize="20" FontWeight="Bold" Foreground="#111827" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                    <Border x:Name="StatCard2" Grid.Column="1" CornerRadius="10" Padding="16,12" Margin="0,0,8,0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1">
                        <StackPanel>
                            <TextBlock x:Name="StatLabel2" Text="系统模板" FontSize="12" Foreground="#6B7280"/>
                            <TextBlock x:Name="StatRepoCount" Text="—" FontSize="20" FontWeight="Bold" Foreground="#111827" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                    <Border x:Name="StatCard3" Grid.Column="2" CornerRadius="10" Padding="16,12" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1">
                        <StackPanel>
                            <TextBlock x:Name="StatLabel3" Text="快照数量" FontSize="12" Foreground="#6B7280"/>
                            <TextBlock x:Name="StatBackupCount" Text="—" FontSize="20" FontWeight="Bold" Foreground="#111827" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <!-- 详情面板 -->
                <Border x:Name="DetailCard" Grid.Row="1" CornerRadius="10" Padding="16,12" Margin="0,12,0,0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock x:Name="DetailTitle" Text="未选择系统" FontSize="16" FontWeight="SemiBold" Foreground="#111827"/>
                            <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                                <Border x:Name="DetailStateBadge" CornerRadius="9" Padding="8,2" Background="#9CA3AF">
                                    <TextBlock x:Name="DetailStateText" Text="—" Foreground="White" FontSize="11"/>
                                </Border>
                                <TextBlock x:Name="DetailMeta" Text="" FontSize="12" Foreground="#6B7280" Margin="10,0,0,0" VerticalAlignment="Center"/>
                            </StackPanel>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="BtnStart" Content="启动" Padding="16,8" Margin="0,0,6,0" Cursor="Hand"/>
                            <Button x:Name="BtnStop" Content="停止" Padding="16,8" Margin="0,0,6,0" Cursor="Hand"/>
                            <Button x:Name="BtnBackupNow" Content="立即备份" Padding="16,8" Cursor="Hand"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <!-- 进度条卡片（耗时操作时显示） -->
                <Border x:Name="ProgressCard" Grid.Row="2" CornerRadius="10" Padding="14,10" Margin="0,12,0,0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" Visibility="Collapsed">
                    <StackPanel>
                        <TextBlock x:Name="ProgressText" Text="" FontSize="12" Foreground="#111827" TextWrapping="Wrap"/>
                        <ProgressBar x:Name="ProgressBar" Height="6" Margin="0,8,0,0" Foreground="#2563EB" Background="#E5E7EB" BorderThickness="0" IsIndeterminate="True"/>
                        <Button x:Name="BtnCancelProgress" Content="取消操作" HorizontalAlignment="Right" Margin="0,8,0,0" Padding="12,4" FontSize="12" Cursor="Hand" Visibility="Collapsed"/>
                    </StackPanel>
                </Border>

                <!-- 日志面板 -->
                <Border x:Name="LogCard" Grid.Row="3" CornerRadius="10" Padding="12,10" Margin="0,12,0,0" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="0,0,0,6">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock x:Name="LogTitle" Text="操作日志" FontSize="13" FontWeight="SemiBold" Foreground="#111827"/>
                            <Button x:Name="BtnClearLog" Grid.Column="1" Content="清空" Padding="10,2" Cursor="Hand"/>
                        </Grid>
                        <ListBox x:Name="LogListBox" Grid.Row="1" BorderThickness="0" Background="Transparent" HorizontalContentAlignment="Stretch" ScrollViewer.VerticalScrollBarVisibility="Auto"/>
                    </Grid>
                </Border>
            </Grid>
        </Grid>

        <!-- 底部状态栏 -->
        <Border x:Name="StatusBar" Grid.Row="2" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
            <Grid Margin="16,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusRootPath" Text="数据存放位置：—" FontSize="11" Foreground="#6B7280" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="StatusAdmin" Grid.Column="1" Text="" FontSize="11" Foreground="#6B7280" VerticalAlignment="Center" Margin="12,0,0,0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)

# 获取控件引用
$TitleBar          = $window.FindName("TitleBar")
$WslStatusBadge    = $window.FindName("WslStatusBadge")
$WslStatusText     = $window.FindName("WslStatusText")
$BtnNew            = $window.FindName("BtnNew")
$BtnBackup         = $window.FindName("BtnBackup")
$BtnRestore        = $window.FindName("BtnRestore")
$BtnDelete         = $window.FindName("BtnDelete")
$BtnSettings       = $window.FindName("BtnSettings")
$BtnRefresh        = $window.FindName("BtnRefresh")
$InstanceListPanel = $window.FindName("InstanceListPanel")
$StatCard1         = $window.FindName("StatCard1")
$StatCard2         = $window.FindName("StatCard2")
$StatCard3         = $window.FindName("StatCard3")
$StatTotalSize     = $window.FindName("StatTotalSize")
$StatRepoCount     = $window.FindName("StatRepoCount")
$StatBackupCount   = $window.FindName("StatBackupCount")
$DetailCard        = $window.FindName("DetailCard")
$DetailTitle       = $window.FindName("DetailTitle")
$DetailStateBadge  = $window.FindName("DetailStateBadge")
$DetailStateText   = $window.FindName("DetailStateText")
$DetailMeta        = $window.FindName("DetailMeta")
$BtnStart          = $window.FindName("BtnStart")
$BtnStop           = $window.FindName("BtnStop")
$BtnBackupNow      = $window.FindName("BtnBackupNow")
$BtnClearLog       = $window.FindName("BtnClearLog")
$LogListBox        = $window.FindName("LogListBox")
$StatusRootPath    = $window.FindName("StatusRootPath")
$StatusAdmin       = $window.FindName("StatusAdmin")
$AppTitle          = $window.FindName("AppTitle")
$LeftPanel         = $window.FindName("LeftPanel")
$LeftTitle         = $window.FindName("LeftTitle")
$StatLabel1        = $window.FindName("StatLabel1")
$StatLabel2        = $window.FindName("StatLabel2")
$StatLabel3        = $window.FindName("StatLabel3")
$LogCard           = $window.FindName("LogCard")
$LogTitle          = $window.FindName("LogTitle")
$StatusBar         = $window.FindName("StatusBar")
$ProgressCard      = $window.FindName("ProgressCard")
$ProgressText      = $window.FindName("ProgressText")
$ProgressBar       = $window.FindName("ProgressBar")
$BtnCancelProgress = $window.FindName("BtnCancelProgress")

# ========== 5. 主题应用 ==========
function Apply-Theme {
    $t = $script:Theme

    $window.Background = ConvertTo-Brush $t.WindowBg
    $TitleBar.Background = ConvertTo-Brush $t.TitleBg
    $TitleBar.BorderBrush = ConvertTo-Brush $t.CardBorder
    $AppTitle.Foreground = ConvertTo-Brush $t.TextPrimary

    # 左侧面板
    $LeftPanel.Background = ConvertTo-Brush $t.CardBg
    $LeftPanel.BorderBrush = ConvertTo-Brush $t.CardBorder
    $LeftTitle.Foreground = ConvertTo-Brush $t.TextPrimary

    # 状态徽章
    $WslStatusText.Foreground = [System.Windows.Media.Brushes]::White

    # 统计卡片 + 详情卡片 + 日志卡片 + 进度卡片
    foreach ($c in @($StatCard1, $StatCard2, $StatCard3, $DetailCard, $LogCard, $ProgressCard)) {
        $c.Background = ConvertTo-Brush $t.CardBg
        $c.BorderBrush = ConvertTo-Brush $t.CardBorder
    }

    # 进度条
    $ProgressText.Foreground = ConvertTo-Brush $t.TextPrimary
    $ProgressBar.Foreground = ConvertTo-Brush $t.Accent
    $ProgressBar.Background = ConvertTo-Brush $t.CardBorder

    # 统计卡片标签与数值
    foreach ($lbl in @($StatLabel1, $StatLabel2, $StatLabel3)) {
        $lbl.Foreground = ConvertTo-Brush $t.TextSecondary
    }
    $StatTotalSize.Foreground = ConvertTo-Brush $t.TextPrimary
    $StatRepoCount.Foreground = ConvertTo-Brush $t.TextPrimary
    $StatBackupCount.Foreground = ConvertTo-Brush $t.TextPrimary

    # 详情面板
    $DetailTitle.Foreground = ConvertTo-Brush $t.TextPrimary
    $DetailMeta.Foreground = ConvertTo-Brush $t.TextSecondary

    # 日志面板
    $LogTitle.Foreground = ConvertTo-Brush $t.TextPrimary

    # 底部状态栏
    $StatusBar.Background = ConvertTo-Brush $t.TitleBg
    $StatusBar.BorderBrush = ConvertTo-Brush $t.CardBorder
    $StatusRootPath.Foreground = ConvertTo-Brush $t.TextSecondary
    $StatusAdmin.Foreground = ConvertTo-Brush $t.TextSecondary

    # 重新渲染实例列表以应用主题
    Render-InstanceList -KeepSelection $true
}

# ========== 6. 按钮样式 ==========
function Set-ButtonStyle {
    param($Button, [string]$BgHex, [string]$FgHex = "#FFFFFF", [string]$HoverHex = $null)

    # 显式传 $null 时 [string] 参数默认值不会生效，这里统一回退，避免 ConvertTo-Brush 收到空串
    if ([string]::IsNullOrWhiteSpace($BgHex)) { $BgHex = $script:Theme.Accent }
    if ([string]::IsNullOrWhiteSpace($FgHex)) { $FgHex = "#FFFFFF" }
    if ([string]::IsNullOrWhiteSpace($HoverHex)) { $HoverHex = $BgHex }

    $Button.Background = ConvertTo-Brush $BgHex
    $Button.Foreground = ConvertTo-Brush $FgHex
    $Button.BorderThickness = New-Object System.Windows.Thickness(0)
    $Button.FontWeight = "SemiBold"
    $Button.Padding = New-Object System.Windows.Thickness(14, 7, 14, 7)

    # 圆角模板
    $template = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
    <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="b" Property="Background" Value="#HOVER#"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="b" Property="Opacity" Value="0.8"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
            <Setter TargetName="b" Property="Opacity" Value="0.4"/>
        </Trigger>
    </ControlTemplate.Triggers>
</ControlTemplate>
'@
    if ($HoverHex) {
        $template = $template.Replace('#HOVER#', $HoverHex)
    } else {
        $template = $template.Replace('#HOVER#', $BgHex)
    }
    $ct = [System.Windows.Markup.XamlReader]::Parse($template)
    $Button.Template = $ct
}

function Apply-ButtonStyles {
    $t = $script:Theme
    Set-ButtonStyle $BtnNew       $t.Accent $null $t.AccentHover
    Set-ButtonStyle $BtnBackup    $t.Accent $null $t.AccentHover
    Set-ButtonStyle $BtnRestore   $t.Accent $null $t.AccentHover
    Set-ButtonStyle $BtnDelete    $t.Danger $null $t.DangerHover
    Set-ButtonStyle $BtnSettings  $t.TextSecondary "#FFFFFF" $t.TextPrimary
    Set-ButtonStyle $BtnStart     $t.Success $null $t.Success
    Set-ButtonStyle $BtnStop      $t.Stopped "#FFFFFF" $t.TextPrimary
    Set-ButtonStyle $BtnBackupNow $t.Accent $null $t.AccentHover
    Set-ButtonStyle $BtnCancelProgress $t.Danger $null $t.DangerHover

    # 次要按钮（刷新/清空）用描边样式
    foreach ($b in @($BtnRefresh, $BtnClearLog)) {
        $b.Background = [System.Windows.Media.Brushes]::Transparent
        $b.Foreground = ConvertTo-Brush $t.Accent
        $b.BorderThickness = New-Object System.Windows.Thickness(0)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
    }
}

# ========== 7. 实例列表渲染 ==========
function Render-InstanceList {
    param([bool]$KeepSelection = $false)

    $selectedName = $script:SelectedInstance
    $InstanceListPanel.Children.Clear()
    $t = $script:Theme

    $instances = Get-WSLInstances

    if ($instances.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = "暂无系统。点击右上角「新增系统」开始。"
        $empty.Foreground = ConvertTo-Brush $t.TextSecondary
        $empty.FontSize = 12
        $empty.TextWrapping = "Wrap"
        $empty.Margin = New-Object System.Windows.Thickness(8, 20, 8, 0)
        $InstanceListPanel.Children.Add($empty) | Out-Null
        $script:SelectedInstance = $null
        Update-DetailPanel
        return
    }

    foreach ($inst in $instances) {
        $card = New-InstanceCard $inst
        $InstanceListPanel.Children.Add($card) | Out-Null
    }

    # 保持选中
    if ($KeepSelection -and $selectedName) {
        $still = $instances | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
        if ($still) {
            $script:SelectedInstance = $selectedName
            Update-DetailPanel
            return
        }
    }
    $script:SelectedInstance = $null
    Update-DetailPanel
}

function New-InstanceCard {
    param($Inst)
    $t = $script:Theme

    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $card.Background = ConvertTo-Brush $t.CardBg
    $card.BorderBrush = ConvertTo-Brush $t.CardBorder
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.Padding = New-Object System.Windows.Thickness(12, 10, 12, 10)
    $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $card.Cursor = [System.Windows.Input.Cursors]::Hand
    $card.Tag = $Inst.Name

    $stack = New-Object System.Windows.Controls.StackPanel

    # 第一行：名称 + 状态徽章
    $row1 = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
    $row1.ColumnDefinitions.Add($c1) | Out-Null
    $row1.ColumnDefinitions.Add($c2) | Out-Null

    $nameText = New-Object System.Windows.Controls.TextBlock
    $nameText.Text = $Inst.Name
    $nameText.FontSize = 14
    $nameText.FontWeight = "SemiBold"
    $nameText.Foreground = ConvertTo-Brush $t.TextPrimary
    $nameText.TextTrimming = "CharacterEllipsis"
    $nameText.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($nameText, 0)
    $row1.Children.Add($nameText) | Out-Null

    $badge = New-Object System.Windows.Controls.Border
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $badge.Padding = New-Object System.Windows.Thickness(8, 2, 8, 2)
    $badge.Background = if ($Inst.IsRunning) { ConvertTo-Brush $t.Running } else { ConvertTo-Brush $t.Stopped }
    $badgeText = New-Object System.Windows.Controls.TextBlock
    $badgeText.Text = if ($Inst.IsRunning) { "运行中" } else { "已停止" }
    $badgeText.Foreground = [System.Windows.Media.Brushes]::White
    $badgeText.FontSize = 11
    $badge.Child = $badgeText
    [System.Windows.Controls.Grid]::SetColumn($badge, 1)
    $row1.Children.Add($badge) | Out-Null

    # 第二行：版本 + 大小
    $row2 = New-Object System.Windows.Controls.StackPanel
    $row2.Orientation = "Horizontal"
    $row2.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)

    $verText = New-Object System.Windows.Controls.TextBlock
    $verText.Text = "WSL $($Inst.Version)"
    $verText.FontSize = 11
    $verText.Foreground = ConvertTo-Brush $t.TextSecondary

    $sizeText = New-Object System.Windows.Controls.TextBlock
    $sizeText.FontSize = 11
    $sizeText.Foreground = ConvertTo-Brush $t.TextSecondary
    $sizeText.Margin = New-Object System.Windows.Thickness(12, 0, 0, 0)

    # 异步获取大小会导致卡顿，这里用快速同步获取（仅 vhdx 单文件）
    $wslRoot = Get-WSLRoot
    $vhdx = Join-Path $wslRoot "Instances\$($Inst.Name)\ext4.vhdx"
    if (Test-Path -LiteralPath $vhdx) {
        $sizeText.Text = Format-EngineSize (Get-Item -LiteralPath $vhdx).Length
    } else {
        $sizeText.Text = "大小未知"
    }

    $row2.Children.Add($verText) | Out-Null
    $row2.Children.Add($sizeText) | Out-Null

    $stack.Children.Add($row1) | Out-Null
    $stack.Children.Add($row2) | Out-Null
    $card.Child = $stack

    # 选中事件（用 sender 参数 $s，避免闭包捕获已失效的局部变量 $card）
    $card.Add_MouseLeftButtonUp({
        param($s, $e)
        $script:SelectedInstance = $s.Tag
        Update-DetailPanel
        Highlight-SelectedCard
    })

    return $card
}

function Highlight-SelectedCard {
    $t = $script:Theme
    foreach ($child in $InstanceListPanel.Children) {
        if ($child -is [System.Windows.Controls.Border] -and $child.Tag) {
            if ($child.Tag -eq $script:SelectedInstance) {
                $child.BorderBrush = ConvertTo-Brush $t.Accent
                $child.BorderThickness = New-Object System.Windows.Thickness(2)
            } else {
                $child.BorderBrush = ConvertTo-Brush $t.CardBorder
                $child.BorderThickness = New-Object System.Windows.Thickness(1)
            }
        }
    }
}

# ========== 8. 详情面板 ==========
function Update-DetailPanel {
    $t = $script:Theme

    if (-not $script:SelectedInstance) {
        $DetailTitle.Text = "未选择系统"
        $DetailStateBadge.Background = ConvertTo-Brush $t.Stopped
        $DetailStateText.Text = "—"
        $DetailMeta.Text = ""
        $BtnStart.IsEnabled = $false
        $BtnStop.IsEnabled = $false
        $BtnBackupNow.IsEnabled = $false
        return
    }

    $detail = Get-WSLInstanceDetail $script:SelectedInstance
    if (-not $detail.Success) {
        $DetailTitle.Text = $script:SelectedInstance
        $DetailStateBadge.Background = ConvertTo-Brush $t.Stopped
        $DetailStateText.Text = "—"
        $DetailMeta.Text = ""
        return
    }

    $d = $detail.Data
    $DetailTitle.Text = $d.Name
    $DetailStateBadge.Background = if ($d.IsRunning) { ConvertTo-Brush $t.Running } else { ConvertTo-Brush $t.Stopped }
    $DetailStateText.Text = if ($d.IsRunning) { "运行中" } else { "已停止" }
    $DetailMeta.Text = "WSL $($d.Version)  ·  磁盘占用 " + (Format-EngineSize $d.VhdxSize)

    $BtnStart.IsEnabled = $true
    $BtnStop.IsEnabled = $true
    $BtnBackupNow.IsEnabled = $true
}

# ========== 9. 日志面板 ==========
function Add-LogEntry {
    param([string]$Message, [string]$Level = "info")

    $t = $script:Theme
    $time = Get-Date -Format "HH:mm:ss"

    $line = New-Object System.Windows.Controls.TextBlock
    $line.Text = "[$time] $Message"
    $line.FontSize = 12
    $line.TextWrapping = "Wrap"
    $line.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)

    switch ($Level) {
        "success" { $line.Foreground = ConvertTo-Brush $t.Success }
        "warning" { $line.Foreground = ConvertTo-Brush $t.Warning }
        "error"   { $line.Foreground = ConvertTo-Brush $t.Danger }
        "danger"  { $line.Foreground = ConvertTo-Brush $t.Danger; $line.FontWeight = "SemiBold" }
        default   { $line.Foreground = ConvertTo-Brush $t.TextPrimary }
    }

    $LogListBox.Items.Add($line) | Out-Null
    $LogListBox.ScrollIntoView($line)
}

function Drain-LogQueue {
    $drained = $false
    $msg = $null
    while ($script:LogQueue.TryDequeue([ref]$msg)) {
        $drained = $true
        if ($msg -is [hashtable]) {
            Add-LogEntry -Message $msg.Message -Level $msg.Level
        }
    }
    # 有新日志说明任务在推进，刷新进度心跳
    if ($drained -and $null -ne $script:ActiveProgress) {
        $script:ActiveProgress.LastActivity = Get-Date
    }
}

# ========== 9.5 进度条 ==========
<#
.SYNOPSIS 显示进度条卡片
.PARAMETER Text 任务描述文字
.PARAMETER TarPattern 可选：备份导出时轮询此通配符下的最新 tar 文件大小，实时更新文字
#>
function Show-Progress {
    param([string]$Text, [string]$TarPattern = $null, [string]$CancelFile = $null)
    $script:ActiveProgress = @{ Text = $Text; TarPattern = $TarPattern; CancelFile = $CancelFile; Started = (Get-Date); LastActivity = (Get-Date) }
    $ProgressText.Text = $Text
    $ProgressBar.IsIndeterminate = $true
    $ProgressCard.Visibility = "Visible"
    # 仅可取消的任务（带 CancelFile）显示「取消操作」按钮
    $BtnCancelProgress.Visibility = if ($CancelFile) { "Visible" } else { "Collapsed" }
}

function Hide-Progress {
    if ($script:ActiveProgress -and $script:ActiveProgress.CancelFile) {
        Remove-Item -LiteralPath $script:ActiveProgress.CancelFile -Force -ErrorAction SilentlyContinue
    }
    $script:ActiveProgress = $null
    $ProgressCard.Visibility = "Collapsed"
    $BtnCancelProgress.Visibility = "Collapsed"
}

# 轮询备份导出文件大小，实时更新进度文字（真实数据，非假进度）
function Update-BackupProgress {
    if ($null -eq $script:ActiveProgress -or [string]::IsNullOrWhiteSpace($script:ActiveProgress.TarPattern)) {
        return
    }
    try {
        $latest = Get-ChildItem -Path $script:ActiveProgress.TarPattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latest) {
            $ProgressText.Text = "$($script:ActiveProgress.Text)  ·  已导出 $(Format-EngineSize $latest.Length)"
            $script:ActiveProgress.LastActivity = Get-Date
        }
    } catch {
        # 文件可能尚未创建，忽略
    }
}

# 下载/安装类任务可能长时间无日志输出（wsl 静默下载）：无文件可跟踪的阶段，
# 超过 15 秒无新进度时周期性更新已等待时长；可取消的任务提示可点「取消操作」
function Update-ProgressHeartbeat {
    if ($null -eq $script:ActiveProgress) {
        return
    }
    # 有 TarPattern 且目标文件已存在时，由 Update-BackupProgress 显示真实导出大小，心跳不覆盖
    if (-not [string]::IsNullOrWhiteSpace($script:ActiveProgress.TarPattern) -and (Test-Path -LiteralPath $script:ActiveProgress.TarPattern)) {
        return
    }
    $idleSeconds = ((Get-Date) - $script:ActiveProgress.LastActivity).TotalSeconds
    if ($idleSeconds -gt 15) {
        $elapsedMin = ((Get-Date) - $script:ActiveProgress.Started).TotalMinutes
        $wait = if ($elapsedMin -lt 1) { "已等待不到 1 分钟" } else { "已等待 $([math]::Floor($elapsedMin)) 分钟" }
        $suffix = if ($script:ActiveProgress.CancelFile) { "，仍无新进度可点「取消操作」中止" } else { "" }
        $ProgressText.Text = "$($script:ActiveProgress.Text)  ·  $wait，仍在进行中$suffix"
        $script:ActiveProgress.LastActivity = Get-Date
    }
}

# ========== 10. 统计刷新 ==========
function Update-Stats {
    $t = $script:Theme
    $stats = Get-WSLStats
    $StatTotalSize.Text = Format-EngineSize $stats.TotalSize
    $StatRepoCount.Text = [string]$stats.RepoCount
    $StatBackupCount.Text = [string]$stats.BackupCount
    $StatusRootPath.Text = "数据存放位置：" + $stats.WslRoot
}

# ========== 11. 系统状态检测 ==========
function Update-SystemStatus {
    $t = $script:Theme
    $avail = Test-WSLAvailability

    if (-not $avail.Success -or -not $avail.Data.WslInstalled) {
        $WslStatusBadge.Background = ConvertTo-Brush $t.Danger
        $WslStatusText.Text = "WSL 未启用"
    } elseif (-not $avail.Data.RootWritable) {
        $WslStatusBadge.Background = ConvertTo-Brush $t.Warning
        $WslStatusText.Text = "目录不可写"
    } else {
        $WslStatusBadge.Background = ConvertTo-Brush $t.Success
        $WslStatusText.Text = "WSL 就绪"
    }

    $StatusAdmin.Text = if ($avail.Data.IsAdmin) { "管理员权限" } else { "普通权限" }
}

# ========== 12. 异步任务 ==========
function Start-BgTask {
    param([string]$Key, [scriptblock]$Script, [object[]]$ArgumentList)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $null = $ps.AddScript($Script.ToString())
    foreach ($a in $ArgumentList) {
        $null = $ps.AddArgument($a)
    }
    $handle = $ps.BeginInvoke()
    $script:BgTasks[$Key] = [PSCustomObject]@{ Ps = $ps; Handle = $handle; Key = $Key }
    $script:IsBusy = $true
}

function Poll-BgTasks {
    $keys = @($script:BgTasks.Keys)
    foreach ($k in $keys) {
        $t = $script:BgTasks[$k]
        if ($t.Handle.IsCompleted) {
            $result = $null
            try {
                $result = $t.Ps.EndInvoke($t.Handle)
            } catch {
                Add-LogEntry "操作异常：$($_.Exception.Message)" "error"
            }
            $t.Ps.Dispose()
            $script:BgTasks.Remove($k)

            # 诊断：任务正常结束应返回 New-EngineResult；无输出/无结果说明被异常中断
            if ($null -eq $result -or @($result).Count -eq 0) {
                Add-LogEntry "后台任务 '$k' 已结束，但未返回结果对象（可能在引擎调用前被异常中断）。" "warning"
            }

            # 处理结果
            if ($result -is [System.Management.Automation.PSDataCollection[psobject]]) {
                foreach ($r in $result) {
                    Handle-BgResult $r
                }
            } elseif ($null -ne $result) {
                Handle-BgResult $result
            }

            $script:IsBusy = $false
            Hide-Progress
            Refresh-All
        }
    }
}

function Handle-BgResult {
    param($Result)
    if ($null -eq $Result) { return }
    if ($Result -is [psobject] -and $Result.PSObject.Properties['Success']) {
        if ($Result.PSObject.Properties['Cancelled'] -and $Result.Cancelled) {
            Add-LogEntry "已取消。" "warning"
        } elseif ($Result.Success) {
            Add-LogEntry $Result.Message "success"
        } else {
            Add-LogEntry $Result.Message "error"
        }
    }
}

function Refresh-All {
    Render-InstanceList -KeepSelection $true
    Update-Stats
}

# ========== 13. 向导：新增系统 ==========
function Show-NewInstanceWizard {
    $t = $script:Theme

    # 第一步：选择来源
    $step1 = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="8">
    <TextBlock Text="从哪里创建新系统？" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <RadioButton x:Name="RbStore" Content="微软商店在线安装" GroupName="src" IsChecked="True" Margin="0,4" FontSize="13"/>
    <TextBlock Text="从官方网络源直连下载（需联网，约 5-20 分钟，期间可能无进度显示）" FontSize="11" Foreground="#6B7280" Margin="20,0,0,8"/>
    <RadioButton x:Name="RbRepo" Content="本地系统模板" GroupName="src" Margin="0,4" FontSize="13"/>
    <TextBlock Text="用已有的模板快速复制出一个新系统" FontSize="11" Foreground="#6B7280" Margin="20,0,0,8"/>
    <RadioButton x:Name="RbTar" Content="自定义 .tar 文件" GroupName="src" Margin="0,4" FontSize="13"/>
    <TextBlock Text="从已有的 tar 存档导入系统" FontSize="11" Foreground="#6B7280" Margin="20,0,0,8"/>
</StackPanel>
'@

    $win = New-Object System.Windows.Window
    $win.Title = "新增系统"
    $win.Width = 460
    $win.Height = 380
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $panel = [System.Windows.Markup.XamlReader]::Parse($step1)
    $RbStore = $panel.FindName("RbStore")
    $RbRepo = $panel.FindName("RbRepo")
    $RbTar = $panel.FindName("RbTar")

    $btnNext = New-Object System.Windows.Controls.Button
    $btnNext.Content = "下一步"
    $btnNext.Width = 100
    $btnNext.Height = 34
    $btnNext.HorizontalAlignment = "Right"
    $btnNext.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    Set-ButtonStyle $btnNext $t.Accent $null $t.AccentHover

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"
    $btnCancel.Width = 100
    $btnCancel.Height = 34
    $btnCancel.HorizontalAlignment = "Right"
    $btnCancel.Margin = New-Object System.Windows.Thickness(0, 16, 8, 0)
    Set-ButtonStyle $btnCancel $t.Stopped "#FFFFFF" $t.TextPrimary

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnNext) | Out-Null

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(20)
    $root.Children.Add($panel) | Out-Null
    $root.Children.Add($btnRow) | Out-Null

    $win.Content = $root

    # 对话框状态放脚本级变量（事件脚本块无法访问函数局部变量，必须用 $script:）
    $script:Dlg = @{
        Result = $null
        Window = $win
        RbStore = $RbStore
        RbRepo = $RbRepo
        RbTar = $RbTar
    }

    $btnCancel.Add_Click({ $script:Dlg.Result = $null; $script:Dlg.Window.Close() })

    $btnNext.Add_Click({
        if ($script:Dlg.RbStore.IsChecked) { $script:Dlg.Result = "store" }
        elseif ($script:Dlg.RbRepo.IsChecked) { $script:Dlg.Result = "repo" }
        else { $script:Dlg.Result = "tar" }
        $script:Dlg.Window.Close()
    })

    $win.ShowDialog() | Out-Null

    $sourceChoice = $script:Dlg.Result

    # 第二步：选择具体项
    switch ($sourceChoice) {
        "store" {
            # Show-StoreDistroPicker 返回发行版名称字符串（不是对象，勿用 .Name）
            $distroName = Show-StoreDistroPicker
            if (-not $distroName) { return }
            # 第三步：命名 + 版本
            $instanceName = Show-NameVersionDialog -DefaultName $distroName -Title "命名新系统"
            if (-not $instanceName) { return }
            Run-CreateFromStore $distroName $instanceName
        }
        "repo" {
            $repo = Show-RepoPicker
            if (-not $repo) { return }
            $defaultName = "$($repo.Name)_$(Get-Date -Format 'yyyyMMdd')"
            $instanceName = Show-NameVersionDialog -DefaultName $defaultName -Title "命名新系统"
            if (-not $instanceName) { return }
            Run-CreateFromRepo $repo.Tar $instanceName
        }
        "tar" {
            $tarPath = Show-TarFilePicker
            if (-not $tarPath) { return }
            $distroName = [System.IO.Path]::GetFileNameWithoutExtension($tarPath)
            $defaultName = "${distroName}_$(Get-Date -Format 'yyyyMMdd')"
            $instanceName = Show-NameVersionDialog -DefaultName $defaultName -Title "命名新系统"
            if (-not $instanceName) { return }
            Run-CreateFromTar $tarPath $instanceName
        }
    }
}

function Fill-StoreDistroList {
    param($List, $Result, $TipText)
    $List.Items.Clear()
    if ($Result -and $Result.Success -and $Result.Data -and @($Result.Data).Count -gt 0) {
        foreach ($d in $Result.Data) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Content = "$($d.Name)  （$($d.FriendlyName)）"
            $item.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
            $item.Tag = $d.Name
            $List.Items.Add($item) | Out-Null
        }
        if ($TipText) { $TipText.Text = "共 $(@($Result.Data).Count) 个发行版可安装" }
    } else {
        $empty = New-Object System.Windows.Controls.ListBoxItem
        if ($Result) { $empty.Content = "获取失败：$($Result.Message)" } else { $empty.Content = "未能获取商店列表（可能需要网络或已启用 WSL）" }
        $empty.IsEnabled = $false
        $List.Items.Add($empty) | Out-Null
        if ($TipText) { $TipText.Text = "" }
    }
}

function Show-StoreDistroPicker {
    $t = $script:Theme
    $distros = Get-WSLStoreDistros

    $win = New-Object System.Windows.Window
    $win.Title = "选择发行版"
    $win.Width = 420
    $win.Height = 480
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    # 提示条（缓存来源 / 刷新结果）
    $tip = New-Object System.Windows.Controls.TextBlock
    $tip.Margin = New-Object System.Windows.Thickness(20, 14, 20, 4)
    $tip.Foreground = ConvertTo-Brush $t.TextSecondary
    $tip.FontSize = 11
    $tip.TextWrapping = "Wrap"
    $tip.Text = if ($distros.Message) { $distros.Message } else { "" }

    $list = New-Object System.Windows.Controls.ListBox
    $list.Margin = New-Object System.Windows.Thickness(20, 0, 20, 0)
    $list.BorderThickness = New-Object System.Windows.Thickness(0)

    Fill-StoreDistroList -List $list -Result $distros -TipText $tip

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(20, 12, 20, 0)

    $btnRefresh = New-Object System.Windows.Controls.Button
    $btnRefresh.Content = "刷新列表"
    $btnRefresh.Width = 90; $btnRefresh.Height = 32
    $btnRefresh.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    Set-ButtonStyle $btnRefresh $t.Stopped "#FFFFFF" $t.TextPrimary

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"
    $btnCancel.Width = 90; $btnCancel.Height = 32
    Set-ButtonStyle $btnCancel $t.Stopped "#FFFFFF" $t.TextPrimary

    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "确定"
    $btnOk.Width = 90; $btnOk.Height = 32
    $btnOk.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnOk $t.Accent $null $t.AccentHover

    $btnRow.Children.Add($btnRefresh) | Out-Null
    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnOk) | Out-Null

    # 用 Grid 布局而非 StackPanel：列表行占 * 剩余高度，ListBox 高度受约束后才会出现滚动条
    $rootGrid = New-Object System.Windows.Controls.Grid
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $r3 = New-Object System.Windows.Controls.RowDefinition; $r3.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
    $rootGrid.RowDefinitions.Add($r1) | Out-Null
    $rootGrid.RowDefinitions.Add($r2) | Out-Null
    $rootGrid.RowDefinitions.Add($r3) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($tip, 0)
    [System.Windows.Controls.Grid]::SetRow($list, 1)
    [System.Windows.Controls.Grid]::SetRow($btnRow, 2)
    $rootGrid.Children.Add($tip) | Out-Null
    $rootGrid.Children.Add($list) | Out-Null
    $rootGrid.Children.Add($btnRow) | Out-Null
    $win.Content = $rootGrid

    $script:Dlg = @{ Result = $null; Window = $win; List = $list; TipText = $tip }
    $btnRefresh.Add_Click({
        $r = Get-WSLStoreDistros -ForceRefresh
        Fill-StoreDistroList -List $script:Dlg.List -Result $r -TipText $script:Dlg.TipText
        Add-LogEntry "商店列表已刷新。" "info"
    })
    $btnOk.Add_Click({
        if ($script:Dlg.List.SelectedItem) { $script:Dlg.Result = $script:Dlg.List.SelectedItem.Tag } else { $script:Dlg.Result = $null }
        $script:Dlg.Window.Close()
    })
    $btnCancel.Add_Click({ $script:Dlg.Result = $null; $script:Dlg.Window.Close() })

    $win.ShowDialog() | Out-Null
    return $script:Dlg.Result
}

function Show-RepoPicker {
    $t = $script:Theme
    $repos = Get-WSLRepositories

    $win = New-Object System.Windows.Window
    $win.Title = "选择系统模板"
    $win.Width = 420
    $win.Height = 460
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $list = New-Object System.Windows.Controls.ListBox
    $list.Margin = New-Object System.Windows.Thickness(20, 16, 20, 0)
    $list.BorderThickness = New-Object System.Windows.Thickness(0)

    if ($repos.Count -gt 0) {
        foreach ($r in $repos) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Content = "$($r.Name)  （$(Format-EngineSize $r.Size)）"
            $item.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
            $item.Tag = $r
            $list.Items.Add($item) | Out-Null
        }
    } else {
        $empty = New-Object System.Windows.Controls.ListBoxItem
        $empty.Content = "暂无可用模板。请先用「微软商店」方式创建一个系统，它会自动保存为模板。"
        $empty.IsEnabled = $false
        $list.Items.Add($empty) | Out-Null
    }

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(20, 12, 20, 0)

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"; $btnCancel.Width = 90; $btnCancel.Height = 32
    Set-ButtonStyle $btnCancel $t.Stopped "#FFFFFF" $t.TextPrimary

    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "确定"; $btnOk.Width = 90; $btnOk.Height = 32
    $btnOk.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnOk $t.Accent $null $t.AccentHover

    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnOk) | Out-Null

    # Grid 布局：列表行占 * 剩余高度，保证 ListBox 可滚动
    $rootGrid = New-Object System.Windows.Controls.Grid
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
    $rootGrid.RowDefinitions.Add($r1) | Out-Null
    $rootGrid.RowDefinitions.Add($r2) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($list, 0)
    [System.Windows.Controls.Grid]::SetRow($btnRow, 1)
    $rootGrid.Children.Add($list) | Out-Null
    $rootGrid.Children.Add($btnRow) | Out-Null
    $win.Content = $rootGrid

    $script:Dlg = @{ Result = $null; Window = $win; List = $list }
    $btnOk.Add_Click({
        if ($script:Dlg.List.SelectedItem) { $script:Dlg.Result = $script:Dlg.List.SelectedItem.Tag } else { $script:Dlg.Result = $null }
        $script:Dlg.Window.Close()
    })
    $btnCancel.Add_Click({ $script:Dlg.Result = $null; $script:Dlg.Window.Close() })

    $win.ShowDialog() | Out-Null
    return $script:Dlg.Result
}

function Show-TarFilePicker {
    $t = $script:Theme
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = "选择 .tar 文件"
    $dlg.Filter = "tar 存档 (*.tar)|*.tar|所有文件 (*.*)|*.*"
    if ($dlg.ShowDialog() -eq $true) {
        return $dlg.FileName
    }
    return $null
}

function Show-NameVersionDialog {
    param([string]$DefaultName, [string]$Title = "命名")

    $t = $script:Theme
    $config = Get-WSLConfig
    $defaultVersion = [int]$config.DefaultWSLVersion

    $win = New-Object System.Windows.Window
    $win.Title = $Title
    $win.Width = 400
    $win.Height = 240
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = New-Object System.Windows.Thickness(20)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = "系统名称"
    $lbl.FontWeight = "SemiBold"
    $lbl.Foreground = ConvertTo-Brush $t.TextPrimary

    $txt = New-Object System.Windows.Controls.TextBox
    $txt.Text = $DefaultName
    $txt.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    $txt.Padding = New-Object System.Windows.Thickness(6, 4, 6, 4)

    $verStack = New-Object System.Windows.Controls.StackPanel
    $verStack.Orientation = "Horizontal"
    $verStack.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)

    $verLbl = New-Object System.Windows.Controls.TextBlock
    $verLbl.Text = "WSL 版本："
    $verLbl.VerticalAlignment = "Center"
    $verLbl.Foreground = ConvertTo-Brush $t.TextPrimary

    $rb1 = New-Object System.Windows.Controls.RadioButton
    $rb1.Content = "WSL 1"; $rb1.GroupName = "ver"; $rb1.IsChecked = ($defaultVersion -eq 1)
    $rb1.VerticalAlignment = "Center"; $rb1.Margin = New-Object System.Windows.Thickness(0, 0, 12, 0)

    $rb2 = New-Object System.Windows.Controls.RadioButton
    $rb2.Content = "WSL 2"; $rb2.GroupName = "ver"; $rb2.IsChecked = ($defaultVersion -eq 2)
    $rb2.VerticalAlignment = "Center"

    $verStack.Children.Add($verLbl) | Out-Null
    $verStack.Children.Add($rb1) | Out-Null
    $verStack.Children.Add($rb2) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(0, 20, 0, 0)

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"; $btnCancel.Width = 90; $btnCancel.Height = 32
    Set-ButtonStyle $btnCancel $t.Stopped "#FFFFFF" $t.TextPrimary

    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "确定"; $btnOk.Width = 90; $btnOk.Height = 32
    $btnOk.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnOk $t.Accent $null $t.AccentHover

    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnOk) | Out-Null

    $stack.Children.Add($lbl) | Out-Null
    $stack.Children.Add($txt) | Out-Null
    $stack.Children.Add($verStack) | Out-Null
    $stack.Children.Add($btnRow) | Out-Null
    $win.Content = $stack

    $script:Dlg = @{ Result = $null; Window = $win; Txt = $txt; Rb1 = $rb1; Rb2 = $rb2 }
    $btnOk.Add_Click({
        $name = $script:Dlg.Txt.Text.Trim()
        if (-not $name) {
            Add-LogEntry "系统名称不能为空。" "warning"
            return
        }
        $ver = if ($script:Dlg.Rb1.IsChecked) { 1 } else { 2 }
        $script:Dlg.Result = [PSCustomObject]@{ Name = $name; Version = $ver }
        $script:Dlg.Window.Close()
    })
    $btnCancel.Add_Click({ $script:Dlg.Result = $null; $script:Dlg.Window.Close() })

    $win.ShowDialog() | Out-Null
    return $script:Dlg.Result
}

# ========== 15. 创建执行 ==========
function Run-CreateFromStore {
    param([string]$DistroName, $NameVer)
    $cancelFile = Join-Path $env:TEMP "wslmgr_cancel_$([guid]::NewGuid().ToString('N')).txt"
    $tarPattern = Join-Path (Get-WSLRoot) "Repositories\$DistroName\base.tar"
    Add-LogEntry "开始直连下载安装 '$DistroName'（约 1-2 GB，下载阶段可能长时间无输出属正常，可点「取消操作」中止）..." "info"
    Show-Progress -Text "正在直连下载安装 '$DistroName'（约 1-2 GB，下载时可能无进度显示，可点「取消操作」中止）..." -TarPattern $tarPattern -CancelFile $cancelFile
    $script = [scriptblock]::Create(@"
param(`$enginePath, `$distro, `$name, `$version, `$queue, `$cancelFile)
Import-Module `$enginePath -Force
`$cb = { param(`$Entry) `$queue.Enqueue(`$Entry) }
New-WSLInstanceFromStore -DistroName `$distro -InstanceName `$name -Version `$version -LogCallback `$cb -CancelFile `$cancelFile
"@)
    Start-BgTask "create_store_$DistroName" $script @($script:EnginePath, $DistroName, $NameVer.Name, $NameVer.Version, $script:LogQueue, $cancelFile)
}

function Run-CreateFromRepo {
    param([string]$TarPath, $NameVer)
    $cancelFile = Join-Path $env:TEMP "wslmgr_cancel_$([guid]::NewGuid().ToString('N')).txt"
    Add-LogEntry "开始从模板创建系统 '$($NameVer.Name)'..." "info"
    Show-Progress -Text "正在从模板创建系统 '$($NameVer.Name)'（导入虚拟磁盘，通常需要 1-3 分钟，可点「取消操作」中止）..." -CancelFile $cancelFile
    $script = [scriptblock]::Create(@"
param(`$enginePath, `$tar, `$name, `$version, `$queue, `$cancelFile)
Import-Module `$enginePath -Force
`$cb = { param(`$Entry) `$queue.Enqueue(`$Entry) }
New-WSLInstanceFromRepo -RepoTarPath `$tar -InstanceName `$name -Version `$version -LogCallback `$cb -CancelFile `$cancelFile
"@)
    Start-BgTask "create_repo_$($NameVer.Name)" $script @($script:EnginePath, $TarPath, $NameVer.Name, $NameVer.Version, $script:LogQueue, $cancelFile)
}

function Run-CreateFromTar {
    param([string]$TarPath, $NameVer)
    $cancelFile = Join-Path $env:TEMP "wslmgr_cancel_$([guid]::NewGuid().ToString('N')).txt"
    Add-LogEntry "开始从 tar 文件导入系统 '$($NameVer.Name)'..." "info"
    Show-Progress -Text "正在从 tar 文件导入系统 '$($NameVer.Name)'（复制模板并导入，通常需要 1-3 分钟，可点「取消操作」中止）..." -CancelFile $cancelFile
    $script = [scriptblock]::Create(@"
param(`$enginePath, `$tar, `$name, `$version, `$queue, `$cancelFile)
Import-Module `$enginePath -Force
`$cb = { param(`$Entry) `$queue.Enqueue(`$Entry) }
New-WSLInstanceFromTar -TarPath `$tar -InstanceName `$name -Version `$version -LogCallback `$cb -CancelFile `$cancelFile
"@)
    Start-BgTask "create_tar_$($NameVer.Name)" $script @($script:EnginePath, $TarPath, $NameVer.Name, $NameVer.Version, $script:LogQueue, $cancelFile)
}

# ========== 16. 备份 ==========
function Start-Backup {
    if (-not $script:SelectedInstance) {
        Add-LogEntry "请先在左侧选择一个系统。" "warning"
        return
    }
    $name = $script:SelectedInstance

    # 磁盘空间预检
    $precheck = Test-BackupSpace
    if ($precheck -eq "cancel") { return }

    Add-LogEntry "开始备份系统 '$name'（约需 1-3 分钟，请耐心等待）..." "info"
    # 备份进度：轮询导出中的 tar 文件大小，显示真实导出数据量
    $wslRoot = Get-WSLRoot
    $tarPattern = Join-Path $wslRoot "Backups\$name\full_*.tar"
    Show-Progress -Text "正在备份系统 '$name'..." -TarPattern $tarPattern
    $script = [scriptblock]::Create(@"
param(`$enginePath, `$name, `$queue)
Import-Module `$enginePath -Force
`$cb = { param(`$Entry) `$queue.Enqueue(`$Entry) }
Backup-WSLInstance -InstanceName `$name -LogCallback `$cb
"@)
    Start-BgTask "backup_$name" $script @($script:EnginePath, $name, $script:LogQueue)
}

function Test-BackupSpace {
    # 返回 "ok" 表示继续，"cancel" 表示取消
    $wslRoot = Get-WSLRoot
    $backupRoot = Join-Path $wslRoot "Backups"
    Ensure-Directory $backupRoot
    $driveName = [System.IO.Path]::GetPathRoot($backupRoot).TrimEnd('\').TrimEnd(':')
    $driveInfo = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    $freeSpace = if ($null -ne $driveInfo) { $driveInfo.Free / 1GB } else { 0 }

    if ($freeSpace -gt 0 -and $freeSpace -lt 5) {
        $t = $script:Theme
        $win = New-Object System.Windows.Window
        $win.Title = "磁盘空间不足"
        $win.Width = 420
        $win.Height = 200
        $win.WindowStartupLocation = "CenterScreen"
        $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
        $win.FontSize = 13
        $win.Background = ConvertTo-Brush $t.CardBg

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Margin = New-Object System.Windows.Thickness(20)
        $msg = New-Object System.Windows.Controls.TextBlock
        $msg.Text = "磁盘可用空间不足 5GB（当前约 $([math]::Round($freeSpace, 2))GB），备份可能失败。是否继续？"
        $msg.TextWrapping = "Wrap"
        $msg.Foreground = ConvertTo-Brush $t.TextPrimary
        $stack.Children.Add($msg) | Out-Null

        $btnRow = New-Object System.Windows.Controls.StackPanel
        $btnRow.Orientation = "Horizontal"
        $btnRow.HorizontalAlignment = "Right"
        $btnRow.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
        $btnNo = New-Object System.Windows.Controls.Button
        $btnNo.Content = "取消"; $btnNo.Width = 90; $btnNo.Height = 32
        Set-ButtonStyle $btnNo $t.Stopped "#FFFFFF" $t.TextPrimary
        $btnYes = New-Object System.Windows.Controls.Button
        $btnYes.Content = "继续备份"; $btnYes.Width = 100; $btnYes.Height = 32
        $btnYes.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        Set-ButtonStyle $btnYes $t.Accent $null $t.AccentHover
        $btnRow.Children.Add($btnNo) | Out-Null
        $btnRow.Children.Add($btnYes) | Out-Null
        $stack.Children.Add($btnRow) | Out-Null
        $win.Content = $stack

        $script:Dlg = @{ Result = "cancel"; Window = $win }
        $btnYes.Add_Click({ $script:Dlg.Result = "ok"; $script:Dlg.Window.Close() })
        $btnNo.Add_Click({ $script:Dlg.Result = "cancel"; $script:Dlg.Window.Close() })
        $win.ShowDialog() | Out-Null
        return $script:Dlg.Result
    }
    return "ok"
}

# ========== 17. 还原 ==========
function Show-RestoreDialog {
    $t = $script:Theme
    $backups = Get-WSLBackups

    $win = New-Object System.Windows.Window
    $win.Title = "还原系统"
    $win.Width = 560
    $win.Height = 480
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = New-Object System.Windows.Thickness(20)

    $tip = New-Object System.Windows.Controls.TextBlock
    $tip.Text = "选择要还原的快照（按时间倒序）："
    $tip.FontWeight = "SemiBold"
    $tip.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($tip) | Out-Null

    $list = New-Object System.Windows.Controls.ListBox
    $list.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
    $list.MaxHeight = 260
    $list.BorderThickness = New-Object System.Windows.Thickness(0)

    if ($backups.Count -gt 0) {
        foreach ($b in $backups) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Content = "[$($b.InstanceName)]  $($b.FileName)  ·  $(Format-EngineSize $b.Size)  ·  $($b.Time.ToString('yyyy-MM-dd HH:mm:ss'))"
            $item.Padding = New-Object System.Windows.Thickness(10, 6, 10, 6)
            $item.Tag = $b
            $list.Items.Add($item) | Out-Null
        }
    } else {
        $empty = New-Object System.Windows.Controls.ListBoxItem
        $empty.Content = "暂无任何快照。"
        $empty.IsEnabled = $false
        $list.Items.Add($empty) | Out-Null
    }
    $stack.Children.Add($list) | Out-Null

    $modeStack = New-Object System.Windows.Controls.StackPanel
    $modeStack.Orientation = "Horizontal"
    $modeStack.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)
    $modeLbl = New-Object System.Windows.Controls.TextBlock
    $modeLbl.Text = "还原方式："
    $modeLbl.VerticalAlignment = "Center"
    $modeLbl.Foreground = ConvertTo-Brush $t.TextPrimary
    $rbOverwrite = New-Object System.Windows.Controls.RadioButton
    $rbOverwrite.Content = "覆盖原系统"; $rbOverwrite.GroupName = "mode"; $rbOverwrite.IsChecked = $true
    $rbOverwrite.VerticalAlignment = "Center"; $rbOverwrite.Margin = New-Object System.Windows.Thickness(0, 0, 14, 0)
    $rbNew = New-Object System.Windows.Controls.RadioButton
    $rbNew.Content = "创建新系统"; $rbNew.GroupName = "mode"
    $rbNew.VerticalAlignment = "Center"
    $modeStack.Children.Add($modeLbl) | Out-Null
    $modeStack.Children.Add($rbOverwrite) | Out-Null
    $modeStack.Children.Add($rbNew) | Out-Null
    $stack.Children.Add($modeStack) | Out-Null

    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = "注意：选择「覆盖原系统」会替换该系统的全部数据，且不可撤销。"
    $warn.Foreground = ConvertTo-Brush $t.Danger
    $warn.FontSize = 11
    $warn.TextWrapping = "Wrap"
    $warn.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
    $stack.Children.Add($warn) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"; $btnCancel.Width = 90; $btnCancel.Height = 32
    Set-ButtonStyle $btnCancel $t.Stopped "#FFFFFF" $t.TextPrimary
    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "开始还原"; $btnOk.Width = 100; $btnOk.Height = 32
    $btnOk.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnOk $t.Accent $null $t.AccentHover
    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnOk) | Out-Null
    $stack.Children.Add($btnRow) | Out-Null
    $win.Content = $stack

    $script:Dlg = @{ Result = $null; Window = $win; List = $list; RbOverwrite = $rbOverwrite }
    $btnOk.Add_Click({
        if (-not $script:Dlg.List.SelectedItem) {
            Add-LogEntry "请先选择一个快照。" "warning"
            return
        }
        $bk = $script:Dlg.List.SelectedItem.Tag
        $mode = if ($script:Dlg.RbOverwrite.IsChecked) { "overwrite" } else { "new" }
        $script:Dlg.Result = [PSCustomObject]@{ Backup = $bk; Mode = $mode; Target = $bk.InstanceName }
        $script:Dlg.Window.Close()
    })
    $btnCancel.Add_Click({ $script:Dlg.Result = $null; $script:Dlg.Window.Close() })

    $win.ShowDialog() | Out-Null

    $action = $script:Dlg.Result

    if ($action) {
        if ($action.Mode -eq "new") {
            # 命名对话框放在函数主体执行（避免事件脚本块内嵌套对话框）
            $nameVer = Show-NameVersionDialog -DefaultName "$($action.Backup.InstanceName)_restore" -Title "新系统命名"
            if (-not $nameVer) { return }
            $action.Target = $nameVer.Name
        }
        if ($action.Mode -eq "overwrite") {
            $confirm = Confirm-Danger "即将用快照覆盖系统 '$($action.Target)'。原系统数据将被替换，此操作不可撤销！确定继续吗？"
            if (-not $confirm) { return }
        }
        Run-Restore $action.Backup.Path $action.Target $action.Mode
    }
}

function Run-Restore {
    param([string]$BackupPath, [string]$TargetName, [string]$Mode)
    Add-LogEntry "开始还原系统 '$TargetName'（约需 1-3 分钟）..." "info"
    Show-Progress -Text "正在还原系统 '$TargetName'（导入虚拟磁盘，通常需要 1-3 分钟）..."
    $config = Get-WSLConfig
    $version = [int]$config.DefaultWSLVersion
    $script = [scriptblock]::Create(@"
param(`$enginePath, `$backup, `$target, `$mode, `$version, `$queue)
Import-Module `$enginePath -Force
`$cb = { param(`$Entry) `$queue.Enqueue(`$Entry) }
Restore-WSLInstance -BackupPath `$backup -TargetInstanceName `$target -Mode `$mode -Version `$version -LogCallback `$cb
"@)
    Start-BgTask "restore_$TargetName" $script @($script:EnginePath, $BackupPath, $TargetName, $Mode, $version, $script:LogQueue)
}

# ========== 18. 删除 ==========
function Show-DeleteDialog {
    if (-not $script:SelectedInstance) {
        Add-LogEntry "请先在左侧选择一个系统。" "warning"
        return
    }
    $name = $script:SelectedInstance
    $t = $script:Theme

    $win = New-Object System.Windows.Window
    $win.Title = "删除系统"
    $win.Width = 480
    $win.Height = 480
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = New-Object System.Windows.Thickness(20)

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = "删除系统：$name"
    $title.FontSize = 16
    $title.FontWeight = "Bold"
    $title.Foreground = ConvertTo-Brush $t.Danger
    $stack.Children.Add($title) | Out-Null

    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = "此操作不可恢复！请选择清理级别："
    $warn.Margin = New-Object System.Windows.Thickness(0, 8, 0, 8)
    $warn.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($warn) | Out-Null

    $rb1 = New-Object System.Windows.Controls.RadioButton
    $rb1.Content = "仅移除系统记录（保留快照和模板）"; $rb1.GroupName = "lvl"; $rb1.IsChecked = $true; $rb1.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    $rb2 = New-Object System.Windows.Controls.RadioButton
    $rb2.Content = "移除记录 + 删除快照"; $rb2.GroupName = "lvl"; $rb2.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    $rb3 = New-Object System.Windows.Controls.RadioButton
    $rb3.Content = "移除记录 + 删除快照 + 删除模板"; $rb3.GroupName = "lvl"; $rb3.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    $rb4 = New-Object System.Windows.Controls.RadioButton
    $rb4.Content = "全量清理（删除所有相关文件）"; $rb4.GroupName = "lvl"; $rb4.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    $stack.Children.Add($rb1) | Out-Null
    $stack.Children.Add($rb2) | Out-Null
    $stack.Children.Add($rb3) | Out-Null
    $stack.Children.Add($rb4) | Out-Null

    $confirmLbl = New-Object System.Windows.Controls.TextBlock
    $confirmLbl.Text = "请输入系统完整名称以确认删除："
    $confirmLbl.Margin = New-Object System.Windows.Thickness(0, 16, 0, 6)
    $confirmLbl.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($confirmLbl) | Out-Null

    $txt = New-Object System.Windows.Controls.TextBox
    $txt.Padding = New-Object System.Windows.Thickness(6, 4, 6, 4)
    $stack.Children.Add($txt) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(0, 20, 0, 0)
    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"; $btnCancel.Width = 90; $btnCancel.Height = 32
    Set-ButtonStyle $btnCancel $t.Stopped "#FFFFFF" $t.TextPrimary
    $btnDelete = New-Object System.Windows.Controls.Button
    $btnDelete.Content = "确认删除"; $btnDelete.Width = 100; $btnDelete.Height = 32
    $btnDelete.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnDelete $t.Danger $null $t.DangerHover
    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnDelete) | Out-Null
    $stack.Children.Add($btnRow) | Out-Null
    $win.Content = $stack

    $script:Dlg = @{ Result = $null; Window = $win; Txt = $txt; Name = $name; Rb1 = $rb1; Rb2 = $rb2; Rb3 = $rb3; Rb4 = $rb4 }
    $btnDelete.Add_Click({
        if ($script:Dlg.Txt.Text -ne $script:Dlg.Name) {
            Add-LogEntry "名称不匹配，已取消删除。" "warning"
            return
        }
        $lvl = if ($script:Dlg.Rb1.IsChecked) { 1 } elseif ($script:Dlg.Rb2.IsChecked) { 2 } elseif ($script:Dlg.Rb3.IsChecked) { 3 } else { 4 }
        $script:Dlg.Result = $lvl
        $script:Dlg.Window.Close()
    })
    $btnCancel.Add_Click({ $script:Dlg.Result = $null; $script:Dlg.Window.Close() })

    $win.ShowDialog() | Out-Null

    $action = $script:Dlg.Result

    if ($action) {
        Run-Delete $name $action
    }
}

function Run-Delete {
    param([string]$Name, [int]$Level)
    Add-LogEntry "开始删除系统 '$Name'（清理级别 $Level），即将弹出管理员授权..." "danger"
    Show-Progress -Text "正在删除系统 '$Name'（注销并清理文件）..."
    $script = [scriptblock]::Create(@"
param(`$enginePath, `$name, `$level, `$queue)
Import-Module `$enginePath -Force
`$cb = { param(`$Entry) `$queue.Enqueue(`$Entry) }
Remove-WSLInstance -InstanceName `$name -CleanupLevel `$level -LogCallback `$cb
"@)
    Start-BgTask "delete_$Name" $script @($script:EnginePath, $Name, $Level, $script:LogQueue)
}

# ========== 19. 设置 ==========
function Show-SettingsDialog {
    $t = $script:Theme
    $config = Get-WSLConfig

    $win = New-Object System.Windows.Window
    $win.Title = "设置"
    $win.Width = 520
    $win.Height = 460
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = New-Object System.Windows.Thickness(20)

    # 数据根目录
    $lbl1 = New-Object System.Windows.Controls.TextBlock
    $lbl1.Text = "数据存放位置（留空 = 工具目录下的 Data 文件夹）"
    $lbl1.FontWeight = "SemiBold"
    $lbl1.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($lbl1) | Out-Null

    $rootRow = New-Object System.Windows.Controls.Grid
    $rootRow.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    $rc1 = New-Object System.Windows.Controls.ColumnDefinition; $rc1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $rc2 = New-Object System.Windows.Controls.ColumnDefinition; $rc2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
    $rootRow.ColumnDefinitions.Add($rc1) | Out-Null
    $rootRow.ColumnDefinitions.Add($rc2) | Out-Null

    $txtRoot = New-Object System.Windows.Controls.TextBox
    $txtRoot.Text = $config.WSLRoot
    $txtRoot.Padding = New-Object System.Windows.Thickness(6, 4, 6, 4)
    [System.Windows.Controls.Grid]::SetColumn($txtRoot, 0)
    $rootRow.Children.Add($txtRoot) | Out-Null

    $btnBrowse = New-Object System.Windows.Controls.Button
    $btnBrowse.Content = "浏览..."
    $btnBrowse.Width = 80; $btnBrowse.Height = 28
    $btnBrowse.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnBrowse $t.Stopped "#FFFFFF" $t.TextPrimary
    [System.Windows.Controls.Grid]::SetColumn($btnBrowse, 1)
    $rootRow.Children.Add($btnBrowse) | Out-Null
    $stack.Children.Add($rootRow) | Out-Null

    # 默认 WSL 版本
    $lbl2 = New-Object System.Windows.Controls.TextBlock
    $lbl2.Text = "默认 WSL 版本"
    $lbl2.FontWeight = "SemiBold"
    $lbl2.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    $lbl2.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($lbl2) | Out-Null

    $verRow = New-Object System.Windows.Controls.StackPanel
    $verRow.Orientation = "Horizontal"
    $verRow.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    $rbv1 = New-Object System.Windows.Controls.RadioButton
    $rbv1.Content = "WSL 1"; $rbv1.GroupName = "dver"; $rbv1.IsChecked = ([int]$config.DefaultWSLVersion -eq 1)
    $rbv2 = New-Object System.Windows.Controls.RadioButton
    $rbv2.Content = "WSL 2"; $rbv2.GroupName = "dver"; $rbv2.IsChecked = ([int]$config.DefaultWSLVersion -eq 2)
    $rbv2.Margin = New-Object System.Windows.Thickness(16, 0, 0, 0)
    $verRow.Children.Add($rbv1) | Out-Null
    $verRow.Children.Add($rbv2) | Out-Null
    $stack.Children.Add($verRow) | Out-Null

    # 备份保留数
    $lbl3 = New-Object System.Windows.Controls.TextBlock
    $lbl3.Text = "每个系统保留的快照数量（0 = 不自动清理）"
    $lbl3.FontWeight = "SemiBold"
    $lbl3.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    $lbl3.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($lbl3) | Out-Null

    $txtRetention = New-Object System.Windows.Controls.TextBox
    $txtRetention.Text = [string]$config.BackupRetentionCount
    $txtRetention.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    $txtRetention.Width = 100
    $txtRetention.HorizontalAlignment = "Left"
    $txtRetention.Padding = New-Object System.Windows.Thickness(6, 4, 6, 4)
    $stack.Children.Add($txtRetention) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(0, 20, 0, 0)
    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"; $btnCancel.Width = 90; $btnCancel.Height = 32
    Set-ButtonStyle $btnCancel $t.Stopped "#FFFFFF" $t.TextPrimary
    $btnSave = New-Object System.Windows.Controls.Button
    $btnSave.Content = "保存"; $btnSave.Width = 90; $btnSave.Height = 32
    $btnSave.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnSave $t.Accent $null $t.AccentHover
    $btnRow.Children.Add($btnCancel) | Out-Null
    $btnRow.Children.Add($btnSave) | Out-Null
    $stack.Children.Add($btnRow) | Out-Null
    $win.Content = $stack

    $script:Dlg = @{
        Window       = $win
        TxtRoot      = $txtRoot
        TxtRetention = $txtRetention
        Rbv1         = $rbv1
        Config       = $config
    }

    $btnBrowse.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = "选择数据存放目录（任选一个文件以定位目录）"
        $dlg.Filter = "所有文件 (*.*)|*.*"
        $dlg.CheckFileExists = $false
        $dlg.FileName = "选择文件夹"
        if ($dlg.ShowDialog() -eq $true) {
            $dir = [System.IO.Path]::GetDirectoryName($dlg.FileName)
            $script:Dlg.TxtRoot.Text = $dir
        }
    })

    $btnSave.Add_Click({
        $retention = 0
        try { $retention = [int]$script:Dlg.TxtRetention.Text } catch { $retention = [int]$script:Dlg.Config.BackupRetentionCount }

        $newConfig = [PSCustomObject]@{
            WSLRoot              = $script:Dlg.TxtRoot.Text.Trim()
            DefaultWSLVersion    = if ($script:Dlg.Rbv1.IsChecked) { 1 } else { 2 }
            BackupRetentionCount = $retention
        }
        Set-WSLConfig -Config $newConfig
        Add-LogEntry "设置已保存。" "success"
        $script:Dlg.Window.Close()
        Update-Stats
        Update-SystemStatus
    })
    $btnCancel.Add_Click({ $script:Dlg.Window.Close() })

    $win.ShowDialog() | Out-Null
}

# ========== 20. 危险确认 ==========
function Confirm-Danger {
    param([string]$Message)
    $t = $script:Theme

    $win = New-Object System.Windows.Window
    $win.Title = "危险操作确认"
    $win.Width = 440
    $win.Height = 200
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = New-Object System.Windows.Thickness(20)
    $msg = New-Object System.Windows.Controls.TextBlock
    $msg.Text = $Message
    $msg.TextWrapping = "Wrap"
    $msg.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($msg) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    $btnNo = New-Object System.Windows.Controls.Button
    $btnNo.Content = "取消"; $btnNo.Width = 90; $btnNo.Height = 32
    Set-ButtonStyle $btnNo $t.Stopped "#FFFFFF" $t.TextPrimary
    $btnYes = New-Object System.Windows.Controls.Button
    $btnYes.Content = "继续"; $btnYes.Width = 90; $btnYes.Height = 32
    $btnYes.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    Set-ButtonStyle $btnYes $t.Danger $null $t.DangerHover
    $btnRow.Children.Add($btnNo) | Out-Null
    $btnRow.Children.Add($btnYes) | Out-Null
    $stack.Children.Add($btnRow) | Out-Null
    $win.Content = $stack

    $script:Dlg = @{ Result = $false; Window = $win }
    $btnYes.Add_Click({ $script:Dlg.Result = $true; $script:Dlg.Window.Close() })
    $btnNo.Add_Click({ $script:Dlg.Result = $false; $script:Dlg.Window.Close() })
    $win.ShowDialog() | Out-Null
    return $script:Dlg.Result
}

# ========== 21. 首次启动引导 ==========
function Show-FirstRunGuide {
    $t = $script:Theme
    $avail = Test-WSLAvailability

    $win = New-Object System.Windows.Window
    $win.Title = "欢迎使用 WSL 系统管理器"
    $win.Width = 520
    $win.Height = 380
    $win.WindowStartupLocation = "CenterScreen"
    $win.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI")
    $win.FontSize = 13
    $win.Background = ConvertTo-Brush $t.CardBg

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = New-Object System.Windows.Thickness(24)

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = "欢迎使用 WSL 系统管理器"
    $title.FontSize = 18
    $title.FontWeight = "Bold"
    $title.Foreground = ConvertTo-Brush $t.TextPrimary
    $stack.Children.Add($title) | Out-Null

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = "本工具帮助你在 Windows 上轻松创建、备份、还原和管理 Linux 系统。"
    $desc.TextWrapping = "Wrap"
    $desc.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    $desc.Foreground = ConvertTo-Brush $t.TextSecondary
    $stack.Children.Add($desc) | Out-Null

    $safety = New-Object System.Windows.Controls.TextBlock
    $safety.Text = "安全承诺：不联网 · 不写注册表 · 不创建服务 · 文件仅保存在数据目录内 · 删除需二次确认。"
    $safety.TextWrapping = "Wrap"
    $safety.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    $safety.Foreground = ConvertTo-Brush $t.Success
    $safety.FontSize = 12
    $stack.Children.Add($safety) | Out-Null

    # WSL 状态
    $status = New-Object System.Windows.Controls.TextBlock
    $status.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)
    $status.TextWrapping = "Wrap"
    if (-not $avail.Success -or -not $avail.Data.WslInstalled) {
        $status.Text = "⚠ 未检测到 WSL。请点击下方按钮启用（会弹出管理员授权，并需要重启电脑）。"
        $status.Foreground = ConvertTo-Brush $t.Danger
        $stack.Children.Add($status) | Out-Null

        $btnInstall = New-Object System.Windows.Controls.Button
        $btnInstall.Content = "一键启用 WSL（wsl --install）"
        $btnInstall.Height = 36
        $btnInstall.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
        Set-ButtonStyle $btnInstall $t.Accent $null $t.AccentHover
        $btnInstall.Add_Click({
            $scriptText = @"
wsl.exe --install 2>&1 | Out-String
Write-Output ("__DONE__ 安装命令已执行。请按提示操作，完成后重启电脑。退出码：" + `$LASTEXITCODE)
"@
            $exec = Invoke-ElevatedScript -ScriptText $scriptText -ProgressCallback {
                param($Line)
                Add-LogEntry $Line "info"
            }
            if ($exec.Success) {
                Add-LogEntry "WSL 安装命令已执行。请重启电脑后重新打开本工具。" "info"
            } else {
                Add-LogEntry "启用 WSL 失败：$($exec.Output)" "error"
            }
        })
        $stack.Children.Add($btnInstall) | Out-Null
    } else {
        $status.Text = "✓ WSL 已就绪。"
        $status.Foreground = ConvertTo-Brush $t.Success
        $stack.Children.Add($status) | Out-Null
    }

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = New-Object System.Windows.Thickness(0, 20, 0, 0)
    $btnStart = New-Object System.Windows.Controls.Button
    $btnStart.Content = "开始使用"; $btnStart.Width = 110; $btnStart.Height = 34
    Set-ButtonStyle $btnStart $t.Accent $null $t.AccentHover
    $script:Dlg = @{ Window = $win }
    $btnStart.Add_Click({ $script:Dlg.Window.Close() })
    $btnRow.Children.Add($btnStart) | Out-Null
    $stack.Children.Add($btnRow) | Out-Null
    $win.Content = $stack

    $win.ShowDialog() | Out-Null
}

# ========== 22. 事件绑定 ==========
$BtnNew.Add_Click({ Show-NewInstanceWizard })
$BtnBackup.Add_Click({ Start-Backup })
$BtnRestore.Add_Click({ Show-RestoreDialog })
$BtnDelete.Add_Click({ Show-DeleteDialog })
$BtnSettings.Add_Click({ Show-SettingsDialog })
$BtnRefresh.Add_Click({ Refresh-All; Update-SystemStatus; Add-LogEntry "已刷新。" "info" })
$BtnClearLog.Add_Click({ $LogListBox.Items.Clear() })
$BtnStart.Add_Click({
    if ($script:SelectedInstance) {
        $r = Start-WSLInstance $script:SelectedInstance
        if ($r.Success) { Add-LogEntry $r.Message "success" } else { Add-LogEntry $r.Message "error" }
    }
})
$BtnStop.Add_Click({
    if ($script:SelectedInstance) {
        $r = Stop-WSLInstance $script:SelectedInstance
        if ($r.Success) { Add-LogEntry $r.Message "success" } else { Add-LogEntry $r.Message "error" }
        Refresh-All
    }
})
$BtnBackupNow.Add_Click({ Start-Backup })

# 取消当前后台操作：写入取消文件，提权进程内的监视器检测到后终止 wsl 下载/导入
$BtnCancelProgress.Add_Click({
    if ($script:ActiveProgress -and $script:ActiveProgress.CancelFile) {
        try {
            [System.IO.File]::WriteAllText($script:ActiveProgress.CancelFile, "cancel")
            Add-LogEntry "正在取消当前操作（将终止提权进程）..." "warning"
        } catch {
            Add-LogEntry "取消失败：$($_.Exception.Message)" "error"
        }
    }
})

# ========== 23. 定时器 ==========
# 实例刷新（5 秒）
$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(5)
$refreshTimer.Add_Tick({
    if (-not $script:IsBusy) {
        Render-InstanceList -KeepSelection $true
        Update-Stats
    }
})
$refreshTimer.Start()

# 后台任务/日志轮询（300ms）
$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$pollTimer.Add_Tick({
    Drain-LogQueue
    Poll-BgTasks
    Update-BackupProgress
    Update-ProgressHeartbeat
})
$pollTimer.Start()

# ========== 24. 初始化与启动 ==========
# 深浅主题跟随系统
if (Get-IsDarkTheme) { $script:Theme = $script:ThemeDark } else { $script:Theme = $script:ThemeLight }

Initialize-WSLDirectories
Apply-ButtonStyles
Apply-Theme
Update-Stats
Update-SystemStatus
Render-InstanceList
Add-LogEntry "WSL 系统管理器已启动。" "info"

# 首次启动引导（仅在 WSL 未就绪时显示）
$avail = Test-WSLAvailability
if (-not $avail.Success -or -not $avail.Data.WslInstalled) {
    $window.Add_ContentRendered({ Show-FirstRunGuide })
}

$window.ShowDialog() | Out-Null
