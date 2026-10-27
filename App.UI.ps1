# ============================================================
#  界面层 / 命令行入口
#  说明：本文件由「build.ps1」拼接在 ShareManager.Core.ps1 之后，
#        合并为单个可独立运行的脚本，再编译成单文件 exe。
# ============================================================

# ============================================================
# 零、后台任务入口（由界面以子进程方式拉起，见「二·五」）
# ============================================================
if ($Task) {
    $ok = $false
    switch ($Task) {
        'InstallProtocol'     { $ok = [bool](Install-Protocol     -Key $TaskArg) }
        'RemoveShareProtocol' { $ok = [bool](Remove-ShareProtocol -Name $TaskArg -Protocol $TaskArg2) }
        'RebuildSites'        { $ok = [bool](Rebuild-Sites) }
        default {
            Write-Op "未知后台任务：$Task" 'ERR'
            $ok = $false
        }
    }
    if ($ok) { exit 0 } else { exit 1 }
}

# ============================================================
# 一、命令行模式（无界面）
# ============================================================
if ($Install -or $Restore -or $Check) {

    $buf = @()

    if ($Install) {
        $ok = Install-Environment
        if ($ok) { $buf += '一键安装：成功' } else { $buf += '一键安装：失败（详见 ops.log）' }
        $buf += ''
    }
    if ($Restore) {
        $ok = Remove-Environment
        if ($ok) { $buf += '回滚清理：成功' } else { $buf += '回滚清理：失败（详见 ops.log）' }
        $buf += ''
    }
    if ($Check) {
        $cfg = Get-Config
        $buf += '=== WinShareManager 环境体检 ==='
        $buf += ("管理员身份 : {0}" -f (Test-Admin))
        $buf += ("共享根目录 : {0}（存在={1}）" -f $cfg.RootBase, (Test-Path $cfg.RootBase))
        $buf += ("WebDAV 端口: {0}    FTP 端口: {1}" -f $cfg.WebDavPort, $cfg.FtpPort)
        $buf += ''
        $buf += '--- 协议状态 ---'
        foreach ($p in (Get-ProtocolList)) {
            $buf += ("{0,-7} 端口 {1,-6} {2,-10} {3}" -f $p.Name, $p.Port, $p.StateText, $p.Detail)
        }
        $buf += ''
        $buf += '--- 已登记共享 ---'
        $shares = @(Get-ShareList)
        if ($shares.Count -eq 0) { $buf += '(空)' }
        foreach ($s in $shares) {
            $buf += ("{0,-14} {1,-16} {2}" -f $s.Name, (@($s.Protocols) -join '+'), $s.Path)
        }
        $buf += ''
        $buf += '--- 本地用户 ---'
        foreach ($u in (Get-UserList)) {
            $st = '启用'
            if (-not $u.Enabled) { $st = '禁用' }
            $buf += ("{0,-18} {1}" -f $u.Name, $st)
        }
    }

    $text = ($buf -join "`r`n")

    try {
        Initialize-Store
        $rp = Join-Path $script:ConfigDir 'last-report.txt'
        [System.IO.File]::WriteAllText($rp, $text, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }

    # 有控制台就打印，没有（GUI 子系统 exe）就弹窗
    $hasConsole = $true
    try {
        $cw = [Console]::WindowWidth
        if ($cw -le 0) { $hasConsole = $false }
    } catch { $hasConsole = $false }
    if ($env:WSM_FORCE_NO_UI -eq '1') { $hasConsole = $true }

    if ($hasConsole) {
        # GUI 子系统 exe 没有控制台宿主时，Write-Host 可能抛错，兜住即可
        try { Write-Host $text } catch { }
    } else {
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
        [void][System.Windows.Forms.MessageBox]::Show($text, '共享管理器', 'OK', 'Information')
    }
    exit 0
}

# ============================================================
# 二、提权守卫（仅直接运行 .ps1 时生效；exe 由清单直接请求管理员）
# ============================================================
if (-not (Test-Admin)) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    if ($self -and (Test-Path -LiteralPath $self) -and $self -match '\.ps1$') {
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"' + $self + '"')
            ) -ErrorAction Stop
            exit 0
        } catch {
            # 用户取消提权：降级为只读模式继续
        }
    }
}

# ============================================================
# 二·五、后台任务（长耗时操作不阻塞界面）
# ============================================================
# 问题：Add-WindowsCapability / appcmd / New-SmbShare 这些调用会把 UI 线程占住几分钟，
#       期间窗口收不到消息，Windows 就给它挂上「未响应」。
# 做法：把这类操作丢给「自己」的子进程执行（exe 模式起自己，ps1 模式起 powershell -File），
#       父进程只负责轮询 + 刷新进度条，消息泵一直是活的。

# 拿到「再次启动自己」所需的命令行前缀
function Get-SelfLauncher {
    $exe = ''
    try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if (-not $exe) { try { $exe = [Environment]::GetCommandLineArgs()[0] } catch { } }

    if ($exe -match '(?i)(powershell|pwsh)(_ise)?\.exe$') {
        $ps1 = $PSCommandPath
        if (-not $ps1 -and $MyInvocation.MyCommand.Path) { $ps1 = $MyInvocation.MyCommand.Path }
        if ($ps1 -and (Test-Path -LiteralPath $ps1)) {
            return [pscustomobject]@{
                File   = $exe
                Prefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $ps1)
            }
        }
    }
    return [pscustomobject]@{ File = $exe; Prefix = @() }
}

# 把后台任务写进日志的进度对话框。返回 $true / $false / 'bg'（用户选择转到后台）
function Show-TaskProgress {
    param(
        $Proc,
        [string]$Title = '正在执行',
        [string]$SubTitle = ''
    )

    $dlg                 = New-DialogBase -Title $Title -W 588 -H 430
    $dlg.ControlBox      = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.Tag             = 'wait'

    # 标题已在窗口标题栏上，这里不再重复画一遍大字，省下的高度留给日志
    $lSub           = New-Object System.Windows.Forms.Label
    $lSub.Text      = $SubTitle
    $lSub.Font      = $fontSmall
    $lSub.ForeColor = $clrSub
    $lSub.AutoSize  = $false
    $lSub.AutoEllipsis = $true
    $lSub.Location  = New-Object System.Drawing.Point(24, 20)
    $lSub.Size      = New-Object System.Drawing.Size(524, 20)

    # 自绘细进度条（系统 ProgressBar 的跑马灯太方，跟整体风格不搭）
    $track           = New-Object System.Windows.Forms.Panel
    $track.BackColor = $clrBg
    $track.Location  = New-Object System.Drawing.Point(24, 48)
    $track.Size      = New-Object System.Drawing.Size(524, 6)
    $track.Tag       = @{ Offset = -0.34; Step = 0.022 }
    $track.Add_Paint({
        param($s, $e)
        $st = $s.Tag
        $g  = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(229, 229, 234))
        $p1 = Get-RoundRect -X 0 -Y 0 -W $s.Width -H $s.Height -R 3
        $g.FillPath($bg, $p1)
        $bg.Dispose(); $p1.Dispose()

        $bw = [int]($s.Width * 0.32)
        $bx = [int]($st.Offset * $s.Width)
        if ($bx -gt $s.Width)  { $bx = $s.Width }
        if (($bx + $bw) -lt 6) { return }
        $fw = [Math]::Min($bw, $s.Width - $bx)
        if ($fw -lt 6) { $fw = 6 }

        $fb = New-Object System.Drawing.SolidBrush($clrAccent)
        $p2 = Get-RoundRect -X $bx -Y 0 -W $fw -H $s.Height -R 3
        $g.FillPath($fb, $p2)
        $fb.Dispose(); $p2.Dispose()
    })

    $txtLog             = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline   = $true
    $txtLog.ReadOnly    = $true
    $txtLog.ScrollBars  = 'Vertical'
    $txtLog.BorderStyle = 'FixedSingle'
    $txtLog.BackColor   = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $txtLog.ForeColor   = [System.Drawing.Color]::FromArgb(62, 62, 68)
    $txtLog.Font        = $fontMono
    $txtLog.Location    = New-Object System.Drawing.Point(24, 66)
    $txtLog.Size        = New-Object System.Drawing.Size(524, 268)
    $txtLog.Text        = ''

    $btnBg = New-Pill -Text '转到后台' -Width 106 -Height 32 -Kind 'ghost'
    $btnBg.Location = New-Object System.Drawing.Point(24, 346)
    $btnBg.Tag      = $dlg
    $btnBg.Add_Click({
        $d = $this.Tag
        $d.Tag = 'bg'
        $d.Close()
    })

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = '窗口现在可以正常响应，不会再「未响应」。'
    $lHint.Font      = $fontSmall
    $lHint.ForeColor = $clrSub
    $lHint.AutoSize  = $true
    $lHint.Location  = New-Object System.Drawing.Point(144, 354)

    $dlg.Controls.AddRange(@($lSub, $track, $txtLog, $btnBg, $lHint))
    $dlg.AcceptButton = $null

    # ---- 轮询：每 180ms 把新增日志喂进文本框，同时看子进程是否退出 ----
    $state = @{ Seen = 0; Text = '' }

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 180
    $timer.Tag      = @{ Dlg = $dlg; Proc = $Proc; Track = $track; Box = $txtLog; State = $state }
    $timer.Add_Tick({
        $ctx = $timer.Tag
        if ($ctx.Dlg.IsDisposed) { $timer.Stop(); return }

        # 进度条动画
        $st = $ctx.Track.Tag
        $st.Offset += $st.Step
        if ($st.Offset -gt 1.0) { $st.Offset = -0.34 }
        $ctx.Track.Invalidate()

        # 追加子进程新写的日志
        try {
            if (Test-Path -LiteralPath $script:LogFile) {
                $fs = [System.IO.File]::Open($script:LogFile, 'Open', 'Read', 'ReadWrite')
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $all = $sr.ReadToEnd()
                $sr.Dispose(); $fs.Dispose()

                if ($all.Length -gt $ctx.State.Text.Length) {
                    $delta = $all.Substring($ctx.State.Text.Length)
                    $ctx.State.Text = $all
                    $ctx.Box.AppendText($delta)
                    $ctx.Box.SelectionStart = $ctx.Box.TextLength
                    $ctx.Box.ScrollToCaret()
                }
            }
        } catch { }

        if ($ctx.Proc.HasExited) {
            $timer.Stop()
            $ctx.Dlg.Tag = 'done'
            $ctx.Dlg.Close()
        }
    })

    $timer.Start()

    # 仅在开发核对时启用：把对话框挪到屏幕外，中途截一张图
    if ($env:WSM_TASK_SHOT) {
        try {
            $dlg.StartPosition = 'Manual'
            $dlg.Location      = New-Object System.Drawing.Point(-5000, -5000)
            $dlg.ShowInTaskbar = $false

            $shot          = New-Object System.Windows.Forms.Timer
            $shot.Interval = 500
            $shot.Tag      = @{ Dlg = $dlg; Path = [string]$env:WSM_TASK_SHOT }
            $shot.Add_Tick({
                $shot.Stop()
                $info = $shot.Tag
                try {
                    $bmp = New-Object System.Drawing.Bitmap($info.Dlg.Width, $info.Dlg.Height)
                    $rc  = New-Object System.Drawing.Rectangle(0, 0, $info.Dlg.Width, $info.Dlg.Height)
                    $info.Dlg.DrawToBitmap($bmp, $rc)
                    $bmp.Save([string]$info.Path, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose()
                } catch { }
            })
            $shot.Start()
        } catch { }
    }

    [void]$dlg.ShowDialog($form)
    $timer.Stop()
    $timer.Dispose()
    $outcome = [string]$dlg.Tag
    $dlg.Dispose()

    if ($outcome -eq 'bg') { return 'bg' }

    try { return ($Proc.ExitCode -eq 0) } catch { return $false }
}

# 统一入口：启动子进程 → 显示进度 → 返回结果
function Invoke-LongTask {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$Arg1 = '',
        [string]$Arg2 = '',
        [string]$Title = '正在执行',
        [string]$SubTitle = ''
    )

    $launch = Get-SelfLauncher
    if (-not $launch.File) {
        Write-Op '无法定位程序自身，已改为前台执行（界面可能短暂卡顿）。' 'WARN'
        return $false
    }

    $argv = @()
    $argv += $launch.Prefix
    $argv += @('-Task', $Task)
    if ($Arg1) { $argv += @('-TaskArg', $Arg1) }
    if ($Arg2) { $argv += @('-TaskArg2', $Arg2) }

    $quoted = foreach ($a in $argv) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }

    $psi                 = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $launch.File
    $psi.Arguments       = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Op "后台任务启动失败：$($_.Exception.Message)" 'ERR'
        return $false
    }

    $r = Show-TaskProgress -Proc $proc -Title $Title -SubTitle $SubTitle
    Sync-LogView
    return $r
}

# 子进程写日志到文件，父进程的日志框要重新读一遍才不会缺行
function Sync-LogView {
    try {
        if (-not (Test-Path -LiteralPath $script:LogFile)) { return }
        $fs = [System.IO.File]::Open($script:LogFile, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $all = $sr.ReadToEnd()
        $sr.Dispose(); $fs.Dispose()

        $lines = @($all -split "`r?`n")
        if ($lines.Count -gt 2000) { $lines = $lines[($lines.Count - 2000)..($lines.Count - 1)] }
        $script:LogBox.Text = ($lines -join "`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    } catch { }
}

# ============================================================
# 三、程序集 / 配色 / 绘图工具
# ============================================================
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Data')

$isAdmin = Test-Admin

# ---- 用户列表可见性 ----
# Windows 自带的服务账户 / 工具创建的沙箱账户，实际不会被用来登录共享，
# 默认隐藏，避免把真正有用的账户淹没掉。工具栏「显示系统账户」可随时切换。
$script:ShowAllUsers = $false
$script:SysUserExact = @('admin', 'DefaultAccount', 'WDAGUtilityAccount', 'Default')
$script:SysUserPrefix = @('CodexSandbox', 'defaultuser', 'DefaultAccount')

function Test-SysUser {
    param([string]$Name)
    if (-not $Name) { return $false }
    foreach ($e in $script:SysUserExact) {
        if ($Name -eq $e) { return $true }
    }
    foreach ($p in $script:SysUserPrefix) {
        if ($Name -like ($p + '*')) { return $true }
    }
    return $false
}

# ---- iOS / macOS 系统色 ----
$clrBg         = [System.Drawing.Color]::FromArgb(242, 242, 247)
$clrCard       = [System.Drawing.Color]::White
$clrSep        = [System.Drawing.Color]::FromArgb(229, 229, 234)
$clrText       = [System.Drawing.Color]::FromArgb(28, 28, 30)
$clrText2      = [System.Drawing.Color]::FromArgb(60, 60, 67)
$clrSub        = [System.Drawing.Color]::FromArgb(142, 142, 147)
$clrAccent     = [System.Drawing.Color]::FromArgb(0, 122, 255)
$clrAccentSoft = [System.Drawing.Color]::FromArgb(233, 241, 255)
$clrGreen      = [System.Drawing.Color]::FromArgb(36, 168, 74)
$clrGreenSoft  = [System.Drawing.Color]::FromArgb(233, 248, 237)
$clrRed        = [System.Drawing.Color]::FromArgb(255, 59, 48)
$clrRedSoft    = [System.Drawing.Color]::FromArgb(255, 236, 234)
$clrOrange     = [System.Drawing.Color]::FromArgb(200, 112, 0)
$clrOrangeSoft = [System.Drawing.Color]::FromArgb(255, 246, 232)
$clrSeg        = [System.Drawing.Color]::FromArgb(233, 233, 235)
$clrHead       = [System.Drawing.Color]::FromArgb(247, 247, 250)

$fontUI    = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$fontName  = New-Object System.Drawing.Font('Microsoft YaHei UI', 11.5, [System.Drawing.FontStyle]::Bold)
$fontBold  = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$fontMono  = New-Object System.Drawing.Font('Consolas', 9)

function Get-RoundRect {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($W -le 0 -or $H -le 0) { return $p }
    $d = $R * 2
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    if ($d -le 0) {
        $p.AddRectangle((New-Object System.Drawing.Rectangle($X, $Y, $W, $H)))
        return $p
    }
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Set-Round {
    param($Ctrl, [int]$Radius = 10)
    if ($null -eq $Ctrl) { return }
    if ($Ctrl.Width -le 0 -or $Ctrl.Height -le 0) { return }
    $path = Get-RoundRect -X 0 -Y 0 -W $Ctrl.Width -H $Ctrl.Height -R $Radius
    $old  = $Ctrl.Region
    try {
        $Ctrl.Region = New-Object System.Drawing.Region($path)
    } catch { }
    if ($null -ne $old) { try { $old.Dispose() } catch { } }
}

# 拖动缩放窗口时，自绘控件没有双缓冲会留下残影线条。
# DoubleBuffered 是 Control 的受保护属性，脚本里只能通过反射打开。
function Enable-DoubleBuffer {
    param($Ctrl)
    if ($null -eq $Ctrl) { return }
    try {
        $pi = [System.Windows.Forms.Control].GetProperty(
            'DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance, NonPublic, Public')
        if ($pi) { $pi.SetValue($Ctrl, $true, $null) }
    } catch { }
}

function Enable-DoubleBufferTree {
    param($Ctrl)
    if ($null -eq $Ctrl) { return }
    Enable-DoubleBuffer -Ctrl $Ctrl
    try {
        foreach ($c in $Ctrl.Controls) { Enable-DoubleBufferTree -Ctrl $c }
    } catch { }
}

function New-Card {
    param([int]$Radius = 14)
    $c           = New-Object System.Windows.Forms.Panel
    $c.BackColor = $clrCard
    $c.Add_Resize({ Set-Round -Ctrl $this -Radius 14 })
    $c.Add_Paint({
        param($s, $e)
        if ($s.Width -lt 4 -or $s.Height -lt 4) { return }
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $pen = New-Object System.Drawing.Pen($clrSep, 1)
        $p   = Get-RoundRect -X 1 -Y 1 -W ($s.Width - 2) -H ($s.Height - 2) -R 14
        $e.Graphics.DrawPath($pen, $p)
        $pen.Dispose(); $p.Dispose()
    })
    return $c
}

# ---- 圆角面自绘 ----
# Control.Region 是按像素做的 1 位裁剪，没有抗锯齿，胶囊按钮两端会出现毛边。
# 这里改成自绘：先用「表面色」铺满整个控件，再抗锯齿填充圆角形状，最后居中画文字。
# 半径与表面色记在 AccessibleDefaultActionDescription 里（格式 "半径|ARGB"，ARGB=-1 表示取父容器底色）。
function Enable-RoundSurface {
    param($Ctrl, [int]$Radius = -1, $Surface = $null)
    if ($null -eq $Ctrl) { return }
    $argb = -1
    if ($null -ne $Surface) { $argb = $Surface.ToArgb() }
    $Ctrl.AccessibleDefaultActionDescription = "$Radius|$argb"
    $Ctrl.Add_Paint({
        param($s, $e)
        if ($s.Width -lt 2 -or $s.Height -lt 2) { return }

        $rad      = 0
        $surfArgb = -1
        $spec     = [string]$s.AccessibleDefaultActionDescription
        if ($spec) {
            $parts = $spec.Split('|')
            if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$rad) }
            if ($parts.Count -ge 2) { [void][int]::TryParse($parts[1], [ref]$surfArgb) }
        }

        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        if ($surfArgb -ne -1) {
            $surface = [System.Drawing.Color]::FromArgb($surfArgb)
        } elseif ($null -ne $s.Parent) {
            $surface = $s.Parent.BackColor
        } else {
            $surface = $clrBg
        }
        $g.Clear($surface)

        $w = $s.Width - 1
        $h = $s.Height - 1
        if ($rad -lt 0) { $rad = [int]($h / 2) }
        $path  = Get-RoundRect -X 0 -Y 0 -W $w -H $h -R $rad
        $brush = New-Object System.Drawing.SolidBrush($s.BackColor)
        $g.FillPath($brush, $path)
        $brush.Dispose()
        $path.Dispose()

        $text = [string]$s.AccessibleName
        if ($text) {
            $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::NoPrefix
            $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $s.Font, $rect, $s.ForeColor, $flags)
        }
    })
}

function Set-CtrlText {
    param($Ctrl, [string]$Text)
    if ($null -eq $Ctrl) { return }
    $Ctrl.AccessibleName = $Text
    $Ctrl.Invalidate()
}

# ---- 胶囊按钮 ----
# Kind: primary 强调 / soft 浅强调 / ghost 普通 / danger 危险 / ok 正向
function Set-PillColors {
    param($Btn, [string]$State = 'normal')
    if ($null -eq $Btn) { return }
    $kind = [string]$Btn.AccessibleDescription

    if ($State -eq 'disabled') {
        $Btn.BackColor = [System.Drawing.Color]::FromArgb(238, 238, 243)
        $Btn.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 168)
        return
    }
    if ($State -eq 'hover') {
        switch ($kind) {
            'primary' { $Btn.BackColor = [System.Drawing.Color]::FromArgb(0, 105, 220); $Btn.ForeColor = [System.Drawing.Color]::White; return }
            'soft'    { $Btn.BackColor = [System.Drawing.Color]::FromArgb(214, 229, 255); $Btn.ForeColor = $clrAccent; return }
            'danger'  { $Btn.BackColor = [System.Drawing.Color]::FromArgb(246, 223, 220); $Btn.ForeColor = $clrRed; return }
            'ok'      { $Btn.BackColor = [System.Drawing.Color]::FromArgb(215, 241, 223); $Btn.ForeColor = $clrGreen; return }
            default   { $Btn.BackColor = [System.Drawing.Color]::FromArgb(219, 219, 227); $Btn.ForeColor = $clrText; return }
        }
    }
    switch ($kind) {
        'primary' { $Btn.BackColor = $clrAccent;     $Btn.ForeColor = [System.Drawing.Color]::White }
        'soft'    { $Btn.BackColor = $clrAccentSoft; $Btn.ForeColor = $clrAccent }
        # 普通态与危险态都用「比页面底色 #F2F2F7 明显深一档」的灰，否则在白卡片与页面底上都不成形
        'danger'  { $Btn.BackColor = [System.Drawing.Color]::FromArgb(251, 235, 233); $Btn.ForeColor = $clrRed }
        'ok'      { $Btn.BackColor = $clrGreenSoft;  $Btn.ForeColor = $clrGreen }
        default   { $Btn.BackColor = [System.Drawing.Color]::FromArgb(230, 230, 236); $Btn.ForeColor = $clrText2 }
    }
}

function New-Pill {
    param(
        [string]$Text,
        [int]$Width = 96,
        [int]$Height = 32,
        [string]$Kind = 'ghost',
        $Surface = $null
    )
    $b                          = New-Object System.Windows.Forms.Button
    $b.Text                     = ''
    $b.AccessibleName           = $Text
    $b.Size                     = New-Object System.Drawing.Size($Width, $Height)
    $b.FlatStyle                = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor                   = 'Hand'
    $b.Font                     = $fontUI
    $b.UseVisualStyleBackColor  = $false
    $b.AccessibleDescription    = $Kind

    Set-PillColors -Btn $b -State 'normal'
    Enable-RoundSurface -Ctrl $b -Radius -1 -Surface $Surface

    $b.Add_MouseEnter({
        if ($this.Enabled) { Set-PillColors -Btn $this -State 'hover' }
    })
    $b.Add_MouseLeave({
        if ($this.Enabled) { Set-PillColors -Btn $this -State 'normal' }
    })
    $b.Add_EnabledChanged({
        if ($this.Enabled) { Set-PillColors -Btn $this -State 'normal' }
        else { Set-PillColors -Btn $this -State 'disabled' }
    })
    return $b
}

# ---- 滑块开关（替代「启动 / 停止」两个按钮）----
# 一个控件表达一个二态，比并排两个按钮更直观：开着是绿色轨道 + 滑钮靠右。
# 状态存在 Tag 里（哈希表是引用类型，事件和 Paint 共享同一份）。
function New-Toggle {
    param([int]$Width = 54, [int]$Height = 28, [string]$Key = '', [string]$Tip = '')

    $t                        = New-Object System.Windows.Forms.Button
    $t.Text                   = ''
    $t.Size                   = New-Object System.Drawing.Size($Width, $Height)
    $t.FlatStyle              = 'Flat'
    $t.FlatAppearance.BorderSize = 0
    $t.UseVisualStyleBackColor = $false
    $t.BackColor              = $clrCard
    $t.Cursor                 = 'Hand'
    $t.TabStop                = $false
    $t.AccessibleDescription  = 'toggle'
    $t.Tag                    = @{ Key = $Key; On = $false }

    $t.Add_Paint({
        param($s, $e)

        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $surface = $clrCard
        if ($null -ne $s.Parent) { $surface = $s.Parent.BackColor }
        $g.Clear($surface)

        $st  = $s.Tag
        $on  = [bool]$st.On
        $dis = -not $s.Enabled

        $w = $s.Width - 1
        $h = $s.Height - 1
        if ($w -lt 8 -or $h -lt 8) { return }

        if ($dis) {
            $track = [System.Drawing.Color]::FromArgb(232, 232, 237)
            $knob  = [System.Drawing.Color]::FromArgb(247, 247, 250)
        } elseif ($on) {
            $track = [System.Drawing.Color]::FromArgb(52, 199, 89)
            $knob  = [System.Drawing.Color]::White
        } else {
            $track = [System.Drawing.Color]::FromArgb(205, 205, 212)
            $knob  = [System.Drawing.Color]::White
        }

        $tp = Get-RoundRect -X 0 -Y 0 -W $w -H $h -R ([int]($h / 2))
        $tb = New-Object System.Drawing.SolidBrush($track)
        $g.FillPath($tb, $tp)
        $tb.Dispose(); $tp.Dispose()

        $pad = 3
        $d   = $h - $pad * 2
        $kx  = $pad
        if ($on) { $kx = $w - $pad - $d }

        $kb = New-Object System.Drawing.SolidBrush($knob)
        $g.FillEllipse($kb, $kx, $pad, $d, $d)
        $kb.Dispose()

        # 滑钮描一圈极淡的边，白钮落在浅灰轨道上才有形状
        if (-not $on -and -not $dis) {
            $kp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(24, 0, 0, 0), 1)
            $g.DrawEllipse($kp, $kx, $pad, $d, $d)
            $kp.Dispose()
        }
    })

    $t.Add_EnabledChanged({ $this.Invalidate() })
    $t.Add_MouseEnter({ $this.Cursor = 'Hand' })
    return $t
}

function Set-ToggleState {
    param($Toggle, [bool]$On, [bool]$Enabled = $true)
    if ($null -eq $Toggle) { return }
    $st     = $Toggle.Tag
    $st.On  = $On
    if ($Toggle.Enabled -ne $Enabled) { $Toggle.Enabled = $Enabled }
    if ($Enabled) { $Toggle.Cursor = 'Hand' } else { $Toggle.Cursor = 'Default' }
    $Toggle.Invalidate()
}

# ---- 胶囊徽章（状态标记）----
function New-Badge {
    param([string]$Text = '', [int]$Width = 74, [int]$Height = 22, $Surface = $null)
    $l                = New-Object System.Windows.Forms.Label
    $l.Text           = ''
    $l.AccessibleName = $Text
    $l.Size           = New-Object System.Drawing.Size($Width, $Height)
    $l.AutoSize       = $false
    $l.TextAlign      = 'MiddleCenter'
    $l.Font           = $fontSmall
    $l.BackColor      = $clrSeg
    $l.ForeColor      = $clrSub
    Enable-RoundSurface -Ctrl $l -Radius -1 -Surface $Surface
    return $l
}

# ---- 链接图标（仓库入口：不放明文地址，画一个链环，点一下打开浏览器）----
# 颜色一律塞进 Tag：事件处理器的执行作用域拿不到定义处的局部变量。
# GitHub 官方标志（mark-github，octocat 剪影，viewBox 0 0 16 16）
$script:GithubMarkD = 'M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.03 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.28.82 2.15 0 3.06-1.86 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z'

# 把 SVG path 数据转成 GDI+ GraphicsPath（支持 M C S L H V A Z 及其小写相对形式）。
# 数字解析按 SVG 规范：".4.07" = 0.4 和 0.07 两个数。
function Convert-SvgPathToGraphicsPath {
    param([Parameter(Mandatory = $true)][string]$D)

    $path   = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tokens = @([regex]::Matches($D, '[MmZzLlHhVvCcSsQqTtAa]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?') |
                ForEach-Object { $_.Value })
    $n   = $tokens.Count
    $idx = 0
    $cx = [double]0; $cy = [double]0; $sx = [double]0; $sy = [double]0
    $lx = [double]0; $ly = [double]0
    $cmd = ''

    while ($idx -lt $n) {
        if ($tokens[$idx] -match '^[A-Za-z]$') { $cmd = $tokens[$idx]; $idx++ }
        if ($cmd -in @('Z', 'z')) { $path.CloseFigure(); $cx = $sx; $cy = $sy; continue }

        $arity = switch -CaseSensitive ($cmd) {
            'M' { 2 } 'm' { 2 } 'L' { 2 } 'l' { 2 }
            'H' { 1 } 'h' { 1 } 'V' { 1 } 'v' { 1 }
            'C' { 6 } 'c' { 6 } 'S' { 4 } 's' { 4 }
            'Q' { 4 } 'q' { 4 } 'T' { 2 } 't' { 2 }
            'A' { 7 } 'a' { 7 }
            default { 0 }
        }
        $vals = @()
        for ($k = 0; $k -lt $arity -and $idx -lt $n; $k++) {
            if ($tokens[$idx] -match '^[A-Za-z]$') { break }
            $vals += [double]$tokens[$idx]; $idx++
        }
        if ($vals.Count -lt $arity) { break }

        switch -CaseSensitive ($cmd) {
            'M' { $cx = $vals[0]; $cy = $vals[1]; $sx = $cx; $sy = $cy; $path.StartFigure(); $cmd = 'L' }
            'm' { $cx += $vals[0]; $cy += $vals[1]; $sx = $cx; $sy = $cy; $path.StartFigure(); $cmd = 'l' }
            'L' { $path.AddLine([single]$cx, [single]$cy, [single]$vals[0], [single]$vals[1]); $cx = $vals[0]; $cy = $vals[1] }
            'l' { $nx = $cx + $vals[0]; $ny = $cy + $vals[1]; $path.AddLine([single]$cx, [single]$cy, [single]$nx, [single]$ny); $cx = $nx; $cy = $ny }
            'H' { $path.AddLine([single]$cx, [single]$cy, [single]$vals[0], [single]$cy); $cx = $vals[0] }
            'h' { $nx = $cx + $vals[0]; $path.AddLine([single]$cx, [single]$cy, [single]$nx, [single]$cy); $cx = $nx }
            'V' { $path.AddLine([single]$cx, [single]$cy, [single]$cx, [single]$vals[0]); $cy = $vals[0] }
            'v' { $ny = $cy + $vals[0]; $path.AddLine([single]$cx, [single]$cy, [single]$cx, [single]$ny); $cy = $ny }
            'C' {
                $path.AddBezier([single]$cx, [single]$cy, [single]$vals[0], [single]$vals[1], [single]$vals[2], [single]$vals[3], [single]$vals[4], [single]$vals[5])
                $lx = $vals[2]; $ly = $vals[3]; $cx = $vals[4]; $cy = $vals[5]
            }
            'c' {
                $c1x = $cx + $vals[0]; $c1y = $cy + $vals[1]
                $c2x = $cx + $vals[2]; $c2y = $cy + $vals[3]
                $ex  = $cx + $vals[4]; $ey  = $cy + $vals[5]
                $path.AddBezier([single]$cx, [single]$cy, [single]$c1x, [single]$c1y, [single]$c2x, [single]$c2y, [single]$ex, [single]$ey)
                $lx = $c2x; $ly = $c2y; $cx = $ex; $cy = $ey
            }
            'S' {
                $c1x = 2 * $cx - $lx; $c1y = 2 * $cy - $ly
                $c2x = $vals[0]; $c2y = $vals[1]
                $path.AddBezier([single]$cx, [single]$cy, [single]$c1x, [single]$c1y, [single]$c2x, [single]$c2y, [single]$vals[2], [single]$vals[3])
                $lx = $c2x; $ly = $c2y; $cx = $vals[2]; $cy = $vals[3]
            }
            's' {
                $c1x = 2 * $cx - $lx; $c1y = 2 * $cy - $ly
                $c2x = $cx + $vals[0]; $c2y = $cy + $vals[1]
                $ex  = $cx + $vals[2]; $ey  = $cy + $vals[3]
                $path.AddBezier([single]$cx, [single]$cy, [single]$c1x, [single]$c1y, [single]$c2x, [single]$c2y, [single]$ex, [single]$ey)
                $lx = $c2x; $ly = $c2y; $cx = $ex; $cy = $ey
            }
            'Q' {
                # 二次贝塞尔升阶成三次
                $c1x = $cx + 2.0 / 3.0 * ($vals[0] - $cx); $c1y = $cy + 2.0 / 3.0 * ($vals[1] - $cy)
                $c2x = $vals[2] + 2.0 / 3.0 * ($vals[0] - $vals[2]); $c2y = $vals[3] + 2.0 / 3.0 * ($vals[1] - $vals[3])
                $path.AddBezier([single]$cx, [single]$cy, [single]$c1x, [single]$c1y, [single]$c2x, [single]$c2y, [single]$vals[2], [single]$vals[3])
                $lx = $vals[0]; $ly = $vals[1]; $cx = $vals[2]; $cy = $vals[3]
            }
            'A' {
                $x1 = $cx; $y1 = $cy
                $rx = [Math]::Abs($vals[0]); $ry = [Math]::Abs($vals[1])
                $phi = $vals[2] * [Math]::PI / 180.0
                $x2 = $vals[5]; $y2 = $vals[6]
                if ($rx -eq 0 -or $ry -eq 0) {
                    $path.AddLine([single]$x1, [single]$y1, [single]$x2, [single]$y2)
                } else {
                    $cosP = [Math]::Cos($phi); $sinP = [Math]::Sin($phi)
                    $dx2 = ($x1 - $x2) / 2.0; $dy2 = ($y1 - $y2) / 2.0
                    $X1p =  $cosP * $dx2 + $sinP * $dy2
                    $Y1p = -$sinP * $dx2 + $cosP * $dy2
                    $lam = ($X1p / $rx) * ($X1p / $rx) + ($Y1p / $ry) * ($Y1p / $ry)
                    if ($lam -gt 1) {
                        $s = [Math]::Sqrt($lam); $rx *= $s; $ry *= $s
                    }
                    $sign = 1.0; if ($vals[3] -eq $vals[4]) { $sign = -1.0 }
                    $num = $rx * $rx * $ry * $ry - $rx * $rx * $Y1p * $Y1p - $ry * $ry * $X1p * $X1p
                    $den = $rx * $rx * $Y1p * $Y1p + $ry * $ry * $X1p * $X1p
                    $co = $sign * [Math]::Sqrt([Math]::Max(0.0, $num / $den))
                    $Cxp =  $co *  $rx * $Y1p / $ry
                    $Cyp = -$co *  $ry * $X1p / $rx
                    $ccx = $cosP * $Cxp - $sinP * $Cyp + ($x1 + $x2) / 2.0
                    $ccy = $sinP * $Cxp + $cosP * $Cyp + ($y1 + $y2) / 2.0

                    $ux = ($X1p - $Cxp) / $rx; $uy = ($Y1p - $Cyp) / $ry
                    $vx = (-$X1p - $Cxp) / $rx; $vy = (-$Y1p - $Cyp) / $ry
                    $t1 = [Math]::Acos([Math]::Max(-1.0, [Math]::Min(1.0, $ux / [Math]::Sqrt($ux * $ux + $uy * $uy))))
                    if ($uy -lt 0) { $t1 = -$t1 }
                    $dt = [Math]::Acos([Math]::Max(-1.0, [Math]::Min(1.0, ($ux * $vx + $uy * $vy) /
                               ([Math]::Sqrt($ux * $ux + $uy * $uy) * [Math]::Sqrt($vx * $vx + $vy * $vy)))))
                    if ($ux * $vy - $uy * $vx -lt 0) { $dt = -$dt }
                    if ($vals[4] -eq 0 -and $dt -gt 0) { $dt -= 2 * [Math]::PI }
                    if ($vals[4] -eq 1 -and $dt -lt 0) { $dt += 2 * [Math]::PI }

                    $seg = [Math]::Ceiling([Math]::Abs($dt) / ([Math]::PI / 2.0))
                    $delta = $dt / $seg
                    $kappa = 4.0 / 3.0 * [Math]::Tan($delta / 4.0)
                    for ($k = 0; $k -lt $seg; $k++) {
                        $a1 = $t1 + $delta * $k
                        $a2 = $a1 + $delta
                        $p0x = $ccx + $rx * [Math]::Cos($a1) * $cosP - $ry * [Math]::Sin($a1) * $sinP
                        $p0y = $ccy + $rx * [Math]::Cos($a1) * $sinP + $ry * [Math]::Sin($a1) * $cosP
                        $p3x = $ccx + $rx * [Math]::Cos($a2) * $cosP - $ry * [Math]::Sin($a2) * $sinP
                        $p3y = $ccy + $rx * [Math]::Cos($a2) * $sinP + $ry * [Math]::Sin($a2) * $cosP
                        $d0x = -$rx * [Math]::Sin($a1) * $cosP - $ry * [Math]::Cos($a1) * $sinP
                        $d0y = -$rx * [Math]::Sin($a1) * $sinP + $ry * [Math]::Cos($a1) * $cosP
                        $d3x = -$rx * [Math]::Sin($a2) * $cosP - $ry * [Math]::Cos($a2) * $sinP
                        $d3y = -$rx * [Math]::Sin($a2) * $sinP + $ry * [Math]::Cos($a2) * $cosP
                        $path.AddBezier(
                            [single]$p0x, [single]$p0y,
                            [single]($p0x + $kappa * $d0x), [single]($p0y + $kappa * $d0y),
                            [single]($p3x - $kappa * $d3x), [single]($p3y - $kappa * $d3y),
                            [single]$p3x, [single]$p3y)
                    }
                }
                $cx = $x2; $cy = $y2
            }
        }
    }
    return $path
}

function New-LinkIcon {
    param([string]$Url = '', [string]$Tip = '', [int]$Size = 24)

    if (-not $script:Tip) {
        $script:Tip = New-Object System.Windows.Forms.ToolTip
        $script:Tip.ShowAlways   = $true
        $script:Tip.InitialDelay = 300
        $script:Tip.ReshowDelay  = 100
        $script:Tip.AutoPopDelay = 8000
    }

    $p           = New-Object System.Windows.Forms.Label
    $p.Size      = New-Object System.Drawing.Size($Size, $Size)
    $p.AutoSize  = $false
    $p.BackColor = $clrBg
    $p.Cursor    = 'Hand'
    $p.Tag       = @{
        Url        = $Url
        Hover      = $false
        Color      = $clrAccent
        ColorHover = [System.Drawing.Color]::FromArgb(0, 90, 200)
    }

    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($s.BackColor)

        $st  = $s.Tag
        $col = if ($st.Hover) { $st.ColorHover } else { $st.Color }

        # GitHub octocat 标志剪影（16x16 路径缓存，绘制时缩放铺满控件）
        if (-not $script:GhMarkPath) {
            $script:GhMarkPath = Convert-SvgPathToGraphicsPath -D $script:GithubMarkD
        }
        $scale = [single]($s.Width / 16.0)
        $gs = $g.Save()
        $g.TranslateTransform([single](($s.Width  - 16.0 * $scale) / 2.0),
                              [single](($s.Height - 16.0 * $scale) / 2.0))
        $g.ScaleTransform($scale, $scale)
        $brush = New-Object System.Drawing.SolidBrush($col)
        $g.FillPath($brush, $script:GhMarkPath)
        $brush.Dispose()
        $g.Restore($gs)
    })

    $p.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true;  $s.Invalidate() })
    $p.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Invalidate() })
    $p.Add_Click({
        param($s, $e)
        $u = [string]$s.Tag.Url
        if ($u) { try { Start-Process -FilePath $u } catch { } }
    })

    if ($Tip) { $script:Tip.SetToolTip($p, $Tip) }
    return $p
}

function Set-BadgeStyle {
    param($Badge, [string]$Style)
    switch ($Style) {
        'run'  { $Badge.BackColor = $clrGreenSoft;  $Badge.ForeColor = $clrGreen }
        'warn' { $Badge.BackColor = $clrOrangeSoft; $Badge.ForeColor = $clrOrange }
        'stop' { $Badge.BackColor = $clrSeg;        $Badge.ForeColor = $clrSub }
        'err'  { $Badge.BackColor = $clrRedSoft;    $Badge.ForeColor = $clrRed }
    }
}

function New-Grid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock                            = 'Fill'
    $g.AllowUserToAddRows              = $false
    $g.AllowUserToDeleteRows           = $false
    $g.AllowUserToResizeRows           = $false
    $g.ReadOnly                        = $true
    $g.RowHeadersVisible               = $false
    $g.SelectionMode                   = 'FullRowSelect'
    $g.MultiSelect                     = $false
    $g.AutoSizeColumnsMode             = 'Fill'
    $g.BackgroundColor                 = $clrCard
    $g.BorderStyle                     = 'None'
    $g.CellBorderStyle                 = 'SingleHorizontal'
    $g.GridColor                       = $clrSep
    $g.EnableHeadersVisualStyles       = $false
    $g.ColumnHeadersBorderStyle        = 'None'
    $g.ColumnHeadersHeight             = 36
    $g.RowTemplate.Height              = 38
    $g.ColumnHeadersDefaultCellStyle.BackColor          = $clrHead
    $g.ColumnHeadersDefaultCellStyle.ForeColor          = $clrSub
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $clrHead
    $g.ColumnHeadersDefaultCellStyle.SelectionForeColor = $clrSub
    $g.ColumnHeadersDefaultCellStyle.Font               = $fontSmall
    $g.ColumnHeadersDefaultCellStyle.Padding            = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $g.DefaultCellStyle.BackColor          = $clrCard
    $g.DefaultCellStyle.ForeColor          = $clrText
    $g.DefaultCellStyle.SelectionBackColor = $clrAccentSoft
    $g.DefaultCellStyle.SelectionForeColor = $clrText
    $g.DefaultCellStyle.Padding            = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $g.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 254)
    return $g
}

# ============================================================
# 三·一、启动计时（设 WSM_TRACE=1 后会把各阶段耗时写进日志，用于排查「启动慢」）
# ============================================================
$script:StartSw = [Diagnostics.Stopwatch]::StartNew()
function Trace-Startup {
    param([string]$Stage)
    if (-not $env:WSM_TRACE) { return }
    Write-Op ("启动阶段 {0,6} ms  {1}" -f $script:StartSw.ElapsedMilliseconds, $Stage) 'INFO'
}
Trace-Startup '界面层开始'

# ============================================================
# 三·五、程序图标（标题栏 / 任务栏 / Alt-Tab）
# ============================================================
# WinForms 窗体不显式设置 Icon 时，会退回一个通用默认图标 —— 跟 exe 资源里
# 编进去的图标毫无关系，于是标题栏和任务栏都显示成「某个普通 Windows 程序」。
# 这里按优先级取：
#   1) 构建时注入的多尺寸 ICO（base64，含 16/32/48/64/256 帧，各尺寸单独绘制）
#   2) 脚本同目录的 app.ico（开发时直接跑 ps1 的情况）
#   3) 进程自身 exe 的关联图标（兜底）
$script:IconB64 = '@@ICON_B64@@'

function Get-AppIcon {
    if ($script:IconB64 -and $script:IconB64 -notlike '@@*') {
        try {
            $bytes = [Convert]::FromBase64String($script:IconB64)
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $ic = New-Object System.Drawing.Icon($ms)
            $ms.Dispose()
            if ($ic) { return $ic }
        } catch { }
    }

    $cands = @()
    try { if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot 'app.ico') } } catch { }
    try { $cands += (Join-Path (Split-Path -Parent ([System.Windows.Forms.Application]::ExecutablePath)) 'app.ico') } catch { }

    foreach ($p in $cands) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try { return (New-Object System.Drawing.Icon($p)) } catch { }
        }
    }

    try {
        $exe = [System.Windows.Forms.Application]::ExecutablePath
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
            if ($ic) { return $ic }
        }
    } catch { }

    return $null
}

# ============================================================
# 四、主窗体骨架
# ============================================================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "共享管理器 v$($script:AppVersion)"
$form.Size            = New-Object System.Drawing.Size(1040, 748)
$form.MinimumSize     = New-Object System.Drawing.Size(940, 660)
$form.StartPosition   = 'CenterScreen'
$form.Font            = $fontUI
$form.BackColor       = $clrBg
$form.ShowIcon        = $true

$appIcon = Get-AppIcon
if ($appIcon) { $form.Icon = $appIcon }

# ---- 标题区 ----
$header           = New-Object System.Windows.Forms.Panel
$header.Dock      = 'Top'
$header.Height    = 74
$header.BackColor = $clrBg

$lblTitle           = New-Object System.Windows.Forms.Label
$lblTitle.Text      = '共享管理器'
$lblTitle.Font      = $fontTitle
$lblTitle.ForeColor = $clrText
$lblTitle.AutoSize  = $true
$lblTitle.Location  = New-Object System.Drawing.Point(28, 20)

# 版本徽标：紧跟在标题右侧，位置在下面统一排
$lblVer           = New-Badge -Text "v$($script:AppVersion)" -Width 62 -Height 22
$lblVer.Font      = $fontSmall
$lblVer.BackColor = $clrAccentSoft
$lblVer.ForeColor = $clrAccent
$lblVer.Invalidate()

$lblWho           = New-Badge -Text '' -Width 132 -Height 26
$lblWho.Font      = $fontSmall
$lblWho.Anchor    = 'Top, Right'
$lblWho.Location  = New-Object System.Drawing.Point(872, 24)
if ($isAdmin) {
    Set-CtrlText -Ctrl $lblWho -Text '管理员模式'
    $lblWho.BackColor = $clrGreenSoft
    $lblWho.ForeColor = $clrGreen
} else {
    Set-CtrlText -Ctrl $lblWho -Text '只读（未提权）'
    $lblWho.BackColor = $clrOrangeSoft
    $lblWho.ForeColor = $clrOrange
}
$lblWho.Invalidate()

# 仓库入口：图标而不是明文地址（版本号右边那个链环）
$lnkRepo = New-LinkIcon -Url $script:AppRepoUrl -Size 24 `
           -Tip ("打开 GitHub 仓库 {0}`n{1}" -f $script:AppRepoName, $script:AppReleaseUrl)

$header.Controls.AddRange(@($lblTitle, $lblVer, $lnkRepo, $lblWho))
$header.Add_Resize({
    $lblWho.Left   = $header.ClientSize.Width - $lblWho.Width - 28
    $lblVer.Left   = $lblTitle.Right + 10
    $lnkRepo.Left  = $lblVer.Right + 8
})
$lblVer.Location  = New-Object System.Drawing.Point(($lblTitle.Right + 10), ($lblTitle.Top + 6))
$lnkRepo.Location = New-Object System.Drawing.Point(($lblVer.Right + 8), ($lblTitle.Top + 4))

# ---- 分段导航（胶囊）----
$segWrap           = New-Object System.Windows.Forms.Panel
$segWrap.Dock      = 'Top'
$segWrap.Height    = 56
$segWrap.BackColor = $clrBg

$segHost           = New-Object System.Windows.Forms.Panel
$segHost.Location  = New-Object System.Drawing.Point(26, 6)
$segHost.Size      = New-Object System.Drawing.Size(470, 42)
$segHost.BackColor = $clrBg
# 槽体也自绘，避免 Region 裁剪导致外圈直角有毛边
$segHost.Add_Paint({
    param($s, $e)
    if ($s.Width -lt 4 -or $s.Height -lt 4) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($clrBg)
    $p  = Get-RoundRect -X 0 -Y 0 -W ($s.Width - 1) -H ($s.Height - 1) -R 12
    $br = New-Object System.Drawing.SolidBrush($clrSeg)
    $g.FillPath($br, $p)
    $br.Dispose(); $p.Dispose()
})

$script:SegBtns = @()
$segLabels = @('协议', '共享', '用户', '权限', '日志')
for ($i = 0; $i -lt $segLabels.Count; $i++) {
    $sb                        = New-Object System.Windows.Forms.Button
    $sb.Text                   = ''
    $sb.AccessibleName         = $segLabels[$i]
    $sb.Size                   = New-Object System.Drawing.Size(90, 34)
    $sb.Location               = New-Object System.Drawing.Point((4 + $i * 92), 4)
    $sb.FlatStyle              = 'Flat'
    $sb.FlatAppearance.BorderSize = 0
    $sb.BackColor              = $clrSeg
    $sb.ForeColor              = $clrText2
    $sb.Font                   = $fontUI
    $sb.Cursor                 = 'Hand'
    $sb.UseVisualStyleBackColor = $false
    $sb.Tag                    = $i
    # 表面色显式指定为分段槽底色，这样按钮圆角外的部分不会露出页面底色
    Enable-RoundSurface -Ctrl $sb -Radius 9 -Surface $clrSeg
    $sb.Add_Click({
        Show-Page -Index ([int]$this.Tag)
    })
    $script:SegBtns += $sb
    $segHost.Controls.Add($sb)
}

$segWrap.Controls.Add($segHost)

# ---- 内容区 ----
$content           = New-Object System.Windows.Forms.Panel
$content.Dock      = 'Fill'
$content.BackColor = $clrBg
$content.Padding   = New-Object System.Windows.Forms.Padding(26, 4, 26, 16)

# ============================================================
# 五、页面 1 —— 协议
# ============================================================
$pageProto           = New-Object System.Windows.Forms.Panel
$pageProto.Dock      = 'Fill'
$pageProto.BackColor = $clrBg
$pageProto.Visible   = $false

$barProto           = New-Object System.Windows.Forms.Panel
$barProto.Dock      = 'Top'
$barProto.Height    = 52
$barProto.BackColor = $clrBg

$btnSettings = New-Pill -Text '管理设置'      -Width 96
$btnRebuild  = New-Pill -Text '重建 IIS 站点' -Width 120
$btnRefreshP = New-Pill -Text '刷新状态'      -Width 92
$btnSettings.Location = New-Object System.Drawing.Point(0, 6)
$btnRebuild.Location  = New-Object System.Drawing.Point(104, 6)
$btnRefreshP.Location = New-Object System.Drawing.Point(232, 6)

$barProto.Controls.AddRange(@($btnSettings, $btnRebuild, $btnRefreshP))

$script:Cards = @{}

function New-ProtocolCard {
    param([string]$Key, [string]$Title, [string]$Hint)

    $card        = New-Card
    $card.Dock   = 'Fill'
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)

    $lblName           = New-Object System.Windows.Forms.Label
    $lblName.Text      = $Title
    $lblName.Font      = $fontName
    $lblName.ForeColor = $clrText
    $lblName.AutoSize  = $true
    $lblName.Location  = New-Object System.Drawing.Point(20, 14)

    $badge = New-Badge -Text '检测中' -Width 78 -Height 22
    $badge.Location = New-Object System.Drawing.Point(20, 48)

    $lblHint           = New-Object System.Windows.Forms.Label
    $lblHint.Text      = $Hint
    $lblHint.ForeColor = $clrSub
    $lblHint.AutoSize  = $false
    $lblHint.AutoEllipsis = $true
    $lblHint.Location  = New-Object System.Drawing.Point(104, 48)
    $lblHint.Size      = New-Object System.Drawing.Size(420, 22)
    $lblHint.Tag       = 'grow'

    $lblAddr           = New-Object System.Windows.Forms.Label
    $lblAddr.Text      = ''
    $lblAddr.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 128)
    $lblAddr.AutoSize  = $false
    $lblAddr.AutoEllipsis = $true
    $lblAddr.Font      = $fontSmall
    $lblAddr.Location  = New-Object System.Drawing.Point(20, 74)
    $lblAddr.Size      = New-Object System.Drawing.Size(504, 20)
    $lblAddr.Tag       = 'grow'

    $bInstall = New-Pill -Text '安装组件' -Width 100 -Kind 'soft'
    $bGuide   = New-Pill -Text '访问方式' -Width 96  -Kind 'soft'
    $bToggle  = New-Toggle -Width 54 -Height 28 -Key $Key
    $bInstall.Tag = $Key
    $bGuide.Tag   = $Key

    # 开关旁边给个短标签，光一个滑块含义不够明确
    $lblSw           = New-Object System.Windows.Forms.Label
    $lblSw.Text      = '服务'
    $lblSw.Font      = $fontSmall
    $lblSw.ForeColor = $clrSub
    $lblSw.AutoSize  = $true
    $lblSw.Location  = New-Object System.Drawing.Point(0, 0)

    $card.Controls.AddRange(@($lblName, $badge, $lblHint, $lblAddr, $bInstall, $lblSw, $bToggle, $bGuide))
    # 按钮必须在标签之上，否则标签的不透明底色会盖住按钮
    $bInstall.BringToFront(); $bToggle.BringToFront()
    $bGuide.BringToFront();   $lblSw.BringToFront()

    # 按钮直接在卡片内右对齐定位（不再用覆盖面板，否则会盖住卡片右圆角）
    $card.Tag = @{
        Install = $bInstall
        Toggle  = $bToggle
        SwLabel = $lblSw
        Guide   = $bGuide
        Hint    = $lblHint
        Addr    = $lblAddr
    }

    $card.Add_Resize({
        $refs = $this.Tag
        if (-not $refs) { return }
        $w = $this.ClientSize.Width
        if ($w -lt 700) { $w = 700 }

        $top      = 42
        $gap      = 12
        $rightPad = 20

        $refs.Guide.Left   = $w - $rightPad - $refs.Guide.Width
        $refs.Guide.Top    = $top

        # 开关与「服务」标签紧挨着，整体贴在「访问方式」左边
        $swLeft = $refs.Guide.Left - 22 - $refs.Toggle.Width
        $refs.Toggle.Left = $swLeft
        $refs.Toggle.Top  = $top + 2

        $refs.SwLabel.Left = $swLeft - 6 - $refs.SwLabel.Width
        $refs.SwLabel.Top  = $top + 7

        $refs.Install.Left = $refs.SwLabel.Left - $gap - $refs.Install.Width
        $refs.Install.Top  = $top

        # 关键：标签宽度必须从「标签自己的左边界」算到按钮左边界，
        # 之前漏算了 Hint 的 x=104，多算 64px 正好压在「安装组件」上。
        $hintW = $refs.Install.Left - 104 - 14
        if ($hintW -lt 120) { $hintW = 120 }
        $refs.Hint.Width = $hintW

        $addrW = $refs.Install.Left - 20 - 14
        if ($addrW -lt 120) { $addrW = 120 }
        $refs.Addr.Width = $addrW
    })

    $script:Cards[$Key] = [pscustomobject]@{
        Key     = $Key
        Badge   = $badge
        Hint    = $lblHint
        Addr    = $lblAddr
        Install = $bInstall
        Toggle  = $bToggle
        Guide   = $bGuide
    }

    return $card
}

$tlp               = New-Object System.Windows.Forms.TableLayoutPanel
$tlp.Dock          = 'Fill'
$tlp.ColumnCount   = 1
$tlp.RowCount      = 5
$tlp.AutoScroll    = $true
$tlp.BackColor     = $clrBg
for ($i = 0; $i -lt 5; $i++) {
    $rs = New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 116)
    [void]$tlp.RowStyles.Add($rs)
}

[void]$tlp.Controls.Add((New-ProtocolCard -Key 'SMB'    -Title 'SMB'    -Hint 'Windows 网络共享，资源管理器直接映射'), 0, 0)
[void]$tlp.Controls.Add((New-ProtocolCard -Key 'WebDAV' -Title 'WebDAV' -Hint '浏览器 / 手机 / 跨平台客户端挂载'),   0, 1)
[void]$tlp.Controls.Add((New-ProtocolCard -Key 'FTP'    -Title 'FTP'    -Hint '传统设备、扫描仪、老式终端接入'),       0, 2)
[void]$tlp.Controls.Add((New-ProtocolCard -Key 'SFTP'   -Title 'SFTP'   -Hint 'SSH 加密通道，走 OpenSSH Server'),      0, 3)
[void]$tlp.Controls.Add((New-ProtocolCard -Key 'DLNA'   -Title 'DLNA'   -Hint '电视 / 机顶盒 / 手机自动发现，内置媒体服务器'), 0, 4)

$pageProto.Controls.Add($tlp)
$pageProto.Controls.Add($barProto)

# ============================================================
# 六、页面 2 —— 共享
# ============================================================
$pageShare           = New-Object System.Windows.Forms.Panel
$pageShare.Dock      = 'Fill'
$pageShare.BackColor = $clrBg
$pageShare.Visible   = $false

$barShare           = New-Object System.Windows.Forms.Panel
$barShare.Dock      = 'Top'
$barShare.Height    = 52
$barShare.BackColor = $clrBg

$btnAddShare     = New-Pill -Text '新增共享' -Width 100 -Kind 'primary'
$btnDelShare     = New-Pill -Text '删除整条共享' -Width 116 -Kind 'danger'
$btnOpenShare    = New-Pill -Text '打开目录' -Width 100
$btnRefreshShare = New-Pill -Text '刷新'     -Width 76
$btnAddShare.Location     = New-Object System.Drawing.Point(0, 6)
$btnDelShare.Location     = New-Object System.Drawing.Point(108, 6)
$btnOpenShare.Location    = New-Object System.Drawing.Point(234, 6)
$btnRefreshShare.Location = New-Object System.Drawing.Point(342, 6)
$barShare.Controls.AddRange(@($btnAddShare, $btnDelShare, $btnOpenShare, $btnRefreshShare))

$wrapShareGrid = New-Card
$wrapShareGrid.Dock    = 'Fill'
$wrapShareGrid.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 14)

$gridShare = New-Grid
$wrapShareGrid.Controls.Add($gridShare)

$pageShare.Controls.Add($wrapShareGrid)
$pageShare.Controls.Add($barShare)

# ============================================================
# 七、页面 3 —— 用户
# ============================================================
$pageUser           = New-Object System.Windows.Forms.Panel
$pageUser.Dock      = 'Fill'
$pageUser.BackColor = $clrBg
$pageUser.Visible   = $false

$barUser           = New-Object System.Windows.Forms.Panel
$barUser.Dock      = 'Top'
$barUser.Height    = 52
$barUser.BackColor = $clrBg

$btnNewUser     = New-Pill -Text '新建用户'    -Width 100 -Kind 'primary'
$btnPwdUser     = New-Pill -Text '设置密码'    -Width 100
$btnToggleUser  = New-Pill -Text '启用 / 禁用' -Width 112
$btnDelUser     = New-Pill -Text '删除用户'    -Width 100 -Kind 'danger'
$btnRefreshUser = New-Pill -Text '刷新'        -Width 76
$btnShowSys     = New-Pill -Text '显示系统账户' -Width 124
$btnNewUser.Location     = New-Object System.Drawing.Point(0, 6)
$btnPwdUser.Location     = New-Object System.Drawing.Point(108, 6)
$btnToggleUser.Location  = New-Object System.Drawing.Point(216, 6)
$btnDelUser.Location     = New-Object System.Drawing.Point(336, 6)
$btnRefreshUser.Location = New-Object System.Drawing.Point(444, 6)
$btnShowSys.Location     = New-Object System.Drawing.Point(528, 6)
$barUser.Controls.AddRange(@($btnNewUser, $btnPwdUser, $btnToggleUser, $btnDelUser, $btnRefreshUser, $btnShowSys))

$wrapUserGrid = New-Card
$wrapUserGrid.Dock    = 'Fill'
$wrapUserGrid.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 14)

$gridUser = New-Grid
$wrapUserGrid.Controls.Add($gridUser)

$pageUser.Controls.Add($wrapUserGrid)
$pageUser.Controls.Add($barUser)

# ============================================================
# 八、页面 4 —— 权限
# ============================================================
$pagePerm           = New-Object System.Windows.Forms.Panel
$pagePerm.Dock      = 'Fill'
$pagePerm.BackColor = $clrBg
$pagePerm.Visible   = $false

$cardPerm        = New-Card
$cardPerm.Dock   = 'Fill'

$lblSharePick           = New-Object System.Windows.Forms.Label
$lblSharePick.Text      = '共享目录'
$lblSharePick.ForeColor = $clrText2
$lblSharePick.AutoSize  = $true
$lblSharePick.Location  = New-Object System.Drawing.Point(24, 24)

$cmbPermShare               = New-Object System.Windows.Forms.ComboBox
$cmbPermShare.Location      = New-Object System.Drawing.Point(96, 20)
$cmbPermShare.Size          = New-Object System.Drawing.Size(280, 28)
$cmbPermShare.DropDownStyle = 'DropDownList'
$cmbPermShare.FlatStyle     = 'Flat'
$cmbPermShare.BackColor     = [System.Drawing.Color]::FromArgb(247, 247, 250)

$lblUserPick           = New-Object System.Windows.Forms.Label
$lblUserPick.Text      = '用户'
$lblUserPick.ForeColor = $clrText2
$lblUserPick.AutoSize  = $true
$lblUserPick.Location  = New-Object System.Drawing.Point(398, 24)

$cmbPermUser               = New-Object System.Windows.Forms.ComboBox
$cmbPermUser.Location      = New-Object System.Drawing.Point(442, 20)
$cmbPermUser.Size          = New-Object System.Drawing.Size(200, 28)
$cmbPermUser.DropDownStyle = 'DropDownList'
$cmbPermUser.FlatStyle     = 'Flat'
$cmbPermUser.BackColor     = [System.Drawing.Color]::FromArgb(247, 247, 250)

$lblLevel           = New-Object System.Windows.Forms.Label
$lblLevel.Text      = '权限级别'
$lblLevel.ForeColor = $clrText2
$lblLevel.AutoSize  = $true
$lblLevel.Location  = New-Object System.Drawing.Point(24, 74)

$script:PermLevel = 'Read'

function Set-PermLevel {
    param([string]$Level)
    $script:PermLevel = $Level
    $map = @{ 'Read' = $btnLvRead; 'Write' = $btnLvWrite; 'Full' = $btnLvFull }
    foreach ($k in @('Read', 'Write', 'Full')) {
        $b = $map[$k]
        if ($k -eq $Level) {
            $b.BackColor = $clrAccentSoft
            $b.ForeColor = $clrAccent
            $b.Font      = $fontBold
        } else {
            $b.BackColor = $clrCard
            $b.ForeColor = $clrText2
            $b.Font      = $fontUI
        }
    }
}

$btnLvRead  = New-Pill -Text '只读'     -Width 92 -Kind 'soft'
$btnLvWrite = New-Pill -Text '读写'     -Width 92
$btnLvFull  = New-Pill -Text '完全控制' -Width 104
$btnLvRead.Location  = New-Object System.Drawing.Point(96, 68)
$btnLvWrite.Location = New-Object System.Drawing.Point(196, 68)
$btnLvFull.Location  = New-Object System.Drawing.Point(296, 68)
$btnLvRead.Add_Click({  Set-PermLevel -Level 'Read' })
$btnLvWrite.Add_Click({ Set-PermLevel -Level 'Write' })
$btnLvFull.Add_Click({  Set-PermLevel -Level 'Full' })

$btnApplyPerm  = New-Pill -Text '应用权限' -Width 104 -Kind 'primary'
$btnRevokePerm = New-Pill -Text '撤销授权' -Width 104
$btnApplyPerm.Location  = New-Object System.Drawing.Point(24, 118)
$btnRevokePerm.Location = New-Object System.Drawing.Point(136, 118)

$lblAclTitle           = New-Object System.Windows.Forms.Label
$lblAclTitle.Text      = '当前目录授权 · NTFS ACL（一套权限同时作用于四种协议）'
$lblAclTitle.ForeColor = $clrText2
$lblAclTitle.Font      = $fontBold
$lblAclTitle.AutoSize  = $true
$lblAclTitle.Location  = New-Object System.Drawing.Point(24, 162)

$lblAclNote           = New-Object System.Windows.Forms.Label
$lblAclNote.Text      = '先在左侧选择一个共享，下面会列出该目录的 NTFS 授权。'
$lblAclNote.ForeColor = $clrSub
$lblAclNote.Font      = $fontSmall
$lblAclNote.AutoSize  = $false
$lblAclNote.AutoEllipsis = $true
$lblAclNote.Location  = New-Object System.Drawing.Point(24, 186)
$lblAclNote.Size      = New-Object System.Drawing.Size(940, 20)

$gridAcl = New-Grid
$gridAcl.Dock        = 'None'
$gridAcl.BorderStyle = 'None'
$gridAcl.Location    = New-Object System.Drawing.Point(24, 212)
$gridAcl.Size        = New-Object System.Drawing.Size(940, 282)

$cardPerm.Controls.AddRange(@($lblSharePick, $cmbPermShare, $lblUserPick, $cmbPermUser,
                              $lblLevel, $btnLvRead, $btnLvWrite, $btnLvFull,
                              $btnApplyPerm, $btnRevokePerm, $lblAclTitle, $lblAclNote, $gridAcl))

$cardPerm.Add_Resize({
    $w = $this.ClientSize.Width - 48
    $h = $this.ClientSize.Height - 212 - 16
    if ($w -lt 200) { $w = 200 }
    if ($h -lt 80)  { $h = 80 }
    $lblAclNote.Width = $w
    $gridAcl.Width  = $w
    $gridAcl.Height = $h
})

$pagePerm.Controls.Add($cardPerm)

# ============================================================
# 九、页面 5 —— 日志
# ============================================================
$pageLog           = New-Object System.Windows.Forms.Panel
$pageLog.Dock      = 'Fill'
$pageLog.BackColor = $clrBg
$pageLog.Visible   = $false

$cardLog         = New-Card
$cardLog.Dock    = 'Fill'
$cardLog.Padding = New-Object System.Windows.Forms.Padding(20, 14, 10, 14)

$txtLog             = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline   = $true
$txtLog.ScrollBars  = 'Vertical'
$txtLog.Dock        = 'Fill'
$txtLog.ReadOnly    = $true
$txtLog.BorderStyle = 'None'
$txtLog.BackColor   = [System.Drawing.Color]::FromArgb(250, 250, 252)
$txtLog.ForeColor   = [System.Drawing.Color]::FromArgb(62, 62, 68)
$txtLog.Font        = $fontMono

$cardLog.Controls.Add($txtLog)
$pageLog.Controls.Add($cardLog)

$script:LogBox = $txtLog

# ---- 汇总页面 ----
$script:Pages      = @($pageProto, $pageShare, $pageUser, $pagePerm, $pageLog)
$script:ActivePage = 0
foreach ($p in $script:Pages) { $content.Controls.Add($p) }

# ---- 状态栏 ----
$statusBar               = New-Object System.Windows.Forms.StatusStrip
$statusBar.BackColor     = $clrCard
$statusBar.SizingGrip    = $false
$statusBar.RenderMode    = 'System'

$statusLabel           = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text      = '就绪'
$statusLabel.Spring    = $true
$statusLabel.TextAlign = 'MiddleLeft'

$statusAdmin           = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusAdmin.TextAlign = 'MiddleRight'
if ($isAdmin) {
    $statusAdmin.Text      = '管理员权限 · 可修改系统配置'
    $statusAdmin.ForeColor = $clrGreen
} else {
    $statusAdmin.Text      = '未提权 · 仅可查看'
    $statusAdmin.ForeColor = $clrOrange
}

[void]$statusBar.Items.Add($statusLabel)
[void]$statusBar.Items.Add($statusAdmin)

$form.Controls.Add($content)
$form.Controls.Add($segWrap)
$form.Controls.Add($header)
$form.Controls.Add($statusBar)

# ============================================================
# 十、页面切换
# ============================================================
function Show-Page {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:Pages.Count) { return }
    for ($i = 0; $i -lt $script:Pages.Count; $i++) {
        $on = ($i -eq $Index)
        $script:Pages[$i].Visible = $on
        $b = $script:SegBtns[$i]
        if ($on) {
            $b.BackColor = $clrCard
            $b.ForeColor = $clrText
            $b.Font      = $fontBold
        } else {
            $b.BackColor = $clrSeg
            $b.ForeColor = $clrText2
            $b.Font      = $fontUI
        }
    }
    $script:ActivePage = $Index
}

# ============================================================
# 十一、刷新逻辑
# ============================================================
function Set-Status {
    param([string]$Text)
    try { $statusLabel.Text = $Text } catch { }
}

function Refresh-ProtocolView {
    $list = @(Get-ProtocolList)
    foreach ($p in $list) {
        $c = $script:Cards[$p.Key]
        if (-not $c) { continue }

        Set-CtrlText -Ctrl $c.Badge -Text $p.StateText
        $c.Hint.Text = $p.Detail
        $c.Addr.Text = "端口 $($p.Port)      $($p.Address)"

        if ($p.Running) {
            Set-BadgeStyle -Badge $c.Badge -Style 'run'
        } elseif ($p.Installed) {
            Set-BadgeStyle -Badge $c.Badge -Style 'stop'
        } else {
            Set-BadgeStyle -Badge $c.Badge -Style 'warn'
        }

        if ($p.Key -in @('SMB', 'DLNA')) {
            Set-CtrlText -Ctrl $c.Install -Text '系统内置'
            $c.Install.Enabled = $false
        } else {
            Set-CtrlText -Ctrl $c.Install -Text '安装组件'
            $c.Install.Enabled = (-not $p.Installed)
        }

        # 组件没装时开关不可拨动（拨了也没东西可启）
        Set-ToggleState -Toggle $c.Toggle -On ([bool]$p.Running) -Enabled ([bool]$p.Installed)
    }

    $up = @($list | Where-Object { $_.Running }).Count
    Set-Status "协议 $up / $($list.Count) 运行中"
}

function Refresh-ShareView {
    $cfg = Get-Config

    # 协议运行状态，用于判断每条链接当前是否真的可用
    $running = @{}
    try {
        foreach ($p in (Get-ProtocolList)) { $running[$p.Key] = [bool]$p.Running }
    } catch { }

    $smbNames = @()
    try {
        $smbNames = @(Get-SmbShareNamesFast)
    } catch { }

    # 按共享名分组：每个协议一行，组首行显示共享名与路径，后续行只显示协议（树形符表现层级）
    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('组首', [bool])
    [void]$dt.Columns.Add('共享名')
    [void]$dt.Columns.Add('物理路径')
    [void]$dt.Columns.Add('协议')
    [void]$dt.Columns.Add('链接')
    [void]$dt.Columns.Add('状态')
    [void]$dt.Columns.Add('协议键')   # 隐藏列：存放未加树形符的协议名，「删除」按它来

    foreach ($s in (Get-ShareList)) {
        $protos = @()
        if ($s.Protocols) { $protos = @($s.Protocols) }
        $n = $protos.Count

        for ($i = 0; $i -lt $n; $i++) {
            $pr   = [string]$protos[$i]
            $link = ''
            $ok   = $false
            switch ($pr) {
                'SMB' {
                    $link = "\\$env:COMPUTERNAME\$($s.Name)"
                    $ok   = ($smbNames -contains $s.Name)
                }
                'WebDAV' {
                    # 路径部分必须做 URL 编码：中文共享名拼成裸 http://.../共享
                    # 在很多客户端里直接失败，编码成 %E5%85%B1%E4%BA%AB 才通用
                    $link = "http://$env:COMPUTERNAME`:$($cfg.WebDavPort)/$([Uri]::EscapeDataString($s.Name))"
                    $ok   = [bool]$running['WebDAV']
                }
                'FTP' {
                    # FTP 目录别名一律 ASCII（中文别名会让资源管理器报 451），
                    # 所以链接直接用别名，不再做 URL 编码
                    $alias = Get-FtpAlias -Name $s.Name
                    $link = "ftp://$env:COMPUTERNAME`:$($cfg.FtpPort)/$alias"
                    $ok   = [bool]$running['FTP']
                }
                'SFTP' {
                    # 不能拼成 sftp://主机/D:/目录 —— 那是 Windows 盘符塞进 URL，
                    # 任何 SFTP 客户端都解析不了，而且 sftp:// 也没有系统级处理器。
                    # 这里只给主机，真正的远程路径（服务器上的 Windows 绝对路径）
                    # 交给「打开」按钮复制到剪贴板。
                    $link = "sftp://$env:COMPUTERNAME"
                    $ok   = [bool]$running['SFTP']
                }
                'DLNA' {
                    # DLNA 没有可直接点开的链接：设备在「网络邻居 / 媒体设备」里自动发现
                    $link = "dlna://$env:COMPUTERNAME`:$($cfg.DlnaPort)/"
                    $ok   = [bool]$running['DLNA']
                }
            }

            $glyph = '├'
            if ($n -eq 1) { $glyph = '·' }
            elseif ($i -eq ($n - 1)) { $glyph = '└' }

            $row = $dt.NewRow()
            $row['组首']     = ($i -eq 0)
            $row['共享名']   = $s.Name
            $row['物理路径'] = $s.Path
            $row['协议']     = "$glyph $pr"
            $row['协议键']   = $pr
            $row['链接']     = $link
            if ($ok) { $row['状态'] = '已生效' } else { $row['状态'] = '协议未运行' }
            [void]$dt.Rows.Add($row)
        }
    }

    # 先绑定数据源，再把「复制」链接列追加到最右
    $gridShare.DataSource = $dt

    # 隐藏分组标记列与协议原始名；禁用排序，否则一排序分组就散了
    try {
        $gridShare.Columns['组首'].Visible   = $false
        $gridShare.Columns['协议键'].Visible = $false
        foreach ($gc in $gridShare.Columns) { $gc.SortMode = 'NotSortable' }
    } catch { }

    # 用链列而不是按钮列：按钮列会画一块白色矩形叠在选中行上，像一块白块盖住内容
    if (-not $gridShare.Columns.Contains('复制')) {
        $col                           = New-Object System.Windows.Forms.DataGridViewLinkColumn
        $col.Name                      = '复制'
        $col.HeaderText                = '复制'
        $col.Text                      = '复制'
        $col.UseColumnTextForLinkValue = $true
        $col.LinkColor                 = $clrAccent
        $col.ActiveLinkColor           = [System.Drawing.Color]::FromArgb(0, 90, 200)
        $col.VisitedLinkColor          = $clrAccent
        $col.TrackVisitedState         = $false
        $col.AutoSizeMode              = 'None'
        $col.Width                     = 62
        $col.SortMode                  = 'NotSortable'
        $col.DefaultCellStyle.Alignment = 'MiddleCenter'
        $col.DefaultCellStyle.Padding   = New-Object System.Windows.Forms.Padding(0)
        [void]$gridShare.Columns.Add($col)
        $gridShare.Columns['复制'].HeaderCell.ToolTipText = '把这一行的链接复制到剪贴板'
    }

    # 「打开」：链接本身在很多地方粘不进去（ftp:// 现代浏览器已不支持、sftp:// 没有系统处理器），
    # 所以这里按协议挑一个真正打得开的动作。
    if (-not $gridShare.Columns.Contains('打开')) {
        $col                           = New-Object System.Windows.Forms.DataGridViewLinkColumn
        $col.Name                      = '打开'
        $col.HeaderText                = '打开'
        $col.Text                      = '打开'
        $col.UseColumnTextForLinkValue = $true
        $col.LinkColor                 = $clrGreen
        $col.ActiveLinkColor           = [System.Drawing.Color]::FromArgb(24, 128, 56)
        $col.VisitedLinkColor          = $clrGreen
        $col.TrackVisitedState         = $false
        $col.AutoSizeMode              = 'None'
        $col.Width                     = 62
        $col.SortMode                  = 'NotSortable'
        $col.DefaultCellStyle.Alignment = 'MiddleCenter'
        $col.DefaultCellStyle.Padding   = New-Object System.Windows.Forms.Padding(0)
        [void]$gridShare.Columns.Add($col)
        $gridShare.Columns['打开'].HeaderCell.ToolTipText = 'SMB / WebDAV / FTP 用资源管理器或浏览器打开；SFTP 自动调起 WinSCP / FileZilla 或自带命令行连接'
    }

    # 每行单独删除一个协议（共享名是组首，协议才是这一行真正对应的东西）
    if (-not $gridShare.Columns.Contains('删除')) {
        $col                           = New-Object System.Windows.Forms.DataGridViewLinkColumn
        $col.Name                      = '删除'
        $col.HeaderText                = '删除'
        $col.Text                      = '删除'
        $col.UseColumnTextForLinkValue = $true
        $col.LinkColor                 = $clrRed
        $col.ActiveLinkColor           = [System.Drawing.Color]::FromArgb(190, 30, 20)
        $col.VisitedLinkColor          = $clrRed
        $col.TrackVisitedState         = $false
        $col.AutoSizeMode              = 'None'
        $col.Width                     = 62
        $col.SortMode                  = 'NotSortable'
        $col.DefaultCellStyle.Alignment = 'MiddleCenter'
        $col.DefaultCellStyle.Padding   = New-Object System.Windows.Forms.Padding(0)
        [void]$gridShare.Columns.Add($col)
        $gridShare.Columns['删除'].HeaderCell.ToolTipText = '只删除这一行的协议，同一共享的其它协议继续可用'
    }
    try {
        $gridShare.Columns['复制'].DisplayIndex = $gridShare.Columns.Count - 3
        $gridShare.Columns['打开'].DisplayIndex = $gridShare.Columns.Count - 2
        $gridShare.Columns['删除'].DisplayIndex = $gridShare.Columns.Count - 1
    } catch { }

    # 列宽权重：链接拿最大份额，保证完整显示不被截断
    try {
        $gridShare.Columns['共享名'].FillWeight   = 95
        $gridShare.Columns['物理路径'].FillWeight = 105
        $gridShare.Columns['协议'].FillWeight     = 95
        $gridShare.Columns['链接'].FillWeight     = 290
        $gridShare.Columns['状态'].FillWeight     = 85
    } catch { }

    $names   = @(Get-ShareList | ForEach-Object { $_.Name })
    $current = $null
    if ($cmbPermShare.SelectedIndex -ge 0) { $current = [string]$cmbPermShare.SelectedItem }
    $cmbPermShare.Items.Clear()
    foreach ($n in $names) { [void]$cmbPermShare.Items.Add($n) }
    if ($cmbPermShare.Items.Count -gt 0) {
        if ($current -and ($names -contains $current)) { $cmbPermShare.SelectedItem = $current }
        else { $cmbPermShare.SelectedIndex = 0 }
    }
    Set-Status "共享 $($names.Count) 项 · 链接 $($dt.Rows.Count) 条"
}

function Refresh-UserView {
    $all    = @(Get-UserList)
    $shown  = @($all | Where-Object { $script:ShowAllUsers -or (-not (Test-SysUser -Name $_.Name)) })
    $hidden = $all.Count - $shown.Count

    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('用户名')
    [void]$dt.Columns.Add('描述')
    [void]$dt.Columns.Add('状态')
    [void]$dt.Columns.Add('最近登录')

    foreach ($u in $shown) {
        $row = $dt.NewRow()
        $row['用户名'] = $u.Name
        $desc = $u.Description
        if (-not $desc) { $desc = $u.FullName }
        $row['描述'] = $desc
        if ($u.Enabled) { $row['状态'] = '已启用' } else { $row['状态'] = '已禁用' }
        if ($u.LastLogon) { $row['最近登录'] = $u.LastLogon.ToString('yyyy-MM-dd HH:mm') } else { $row['最近登录'] = '从未' }
        [void]$dt.Rows.Add($row)
    }
    $gridUser.DataSource = $dt

    $current = $null
    if ($cmbPermUser.SelectedIndex -ge 0) { $current = [string]$cmbPermUser.SelectedItem }
    $cmbPermUser.Items.Clear()
    $script:PermUserMap = @{}

    # 具体账户排前面（默认选中第一个，避免误操作直接把权限开给所有人）
    foreach ($u in ($shown | Where-Object { $_.Enabled })) {
        [void]$cmbPermUser.Items.Add($u.Name)
        $script:PermUserMap[$u.Name] = $u.Name
    }

    # 再补两个常用组：省得为了「让局域网都能读」去挨个建账号
    [void]$cmbPermUser.Items.Add('Everyone（所有人）')
    $script:PermUserMap['Everyone（所有人）'] = 'Everyone'
    [void]$cmbPermUser.Items.Add('Users（本机用户组）')
    $script:PermUserMap['Users（本机用户组）'] = 'Users'

    if ($cmbPermUser.Items.Count -gt 0) {
        if ($current -and $cmbPermUser.Items.Contains($current)) { $cmbPermUser.SelectedItem = $current }
        else { $cmbPermUser.SelectedIndex = 0 }
    }

    $msg = "用户 $($dt.Rows.Count) 项"
    if ($hidden -gt 0) { $msg += "（已隐藏 $hidden 个系统账户）" }
    Set-Status $msg
}

function New-AclTable {
    $t = New-Object System.Data.DataTable
    [void]$t.Columns.Add('账户')
    [void]$t.Columns.Add('权限')
    [void]$t.Columns.Add('类型')
    [void]$t.Columns.Add('来源')
    # 注意：DataTable 会被管道展开成 DataRow，0 行时函数会返回 $null，
    # 必须用逗号包一层让它作为单个对象输出。
    return (, $t)
}

function Refresh-AclView {
    # 无选中项时也绑定空表，保证表头始终可见，不至于看起来像坏掉
    $dt = New-AclTable

    $entry = $null
    if ($cmbPermShare.SelectedIndex -ge 0) {
        $name  = [string]$cmbPermShare.SelectedItem
        $entry = Get-ShareList | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    }

    if ($entry) {
        foreach ($a in @(Get-PathPermission -Path $entry.Path)) {
            $row = $dt.NewRow()
            $row['账户'] = [string]$a.Account
            $row['权限'] = [string]$a.Level
            $row['类型'] = [string]$a.Type
            $row['来源'] = [string]$a.Source
            [void]$dt.Rows.Add($row)
        }

        $hidden = [int]$script:PermHiddenCount
        $note = '以上是该目录真实生效的 NTFS 授权，四种协议共用同一份。'
        if ($hidden -gt 0) { $note += "另有 $hidden 条系统内置（SYSTEM / 管理员组）或仅继承的条目未列出。" }
        if ($dt.Rows.Count -eq 0) {
            $note = '这个目录目前没有额外授权条目（只剩系统内置的 SYSTEM 与管理员组）。'
        }
        $lblAclNote.Text = $note
    } else {
        $lblAclNote.Text = '先在左侧选择一个共享，下面会列出该目录的 NTFS 授权。'
    }

    $gridAcl.DataSource = $dt

    try {
        $gridAcl.Columns['账户'].FillWeight = 230
        $gridAcl.Columns['权限'].FillWeight = 110
        $gridAcl.Columns['类型'].FillWeight = 70
        $gridAcl.Columns['来源'].FillWeight = 120
    } catch { }
}

# ============================================================
# 十二、对话框
# ============================================================
function New-DialogBase {
    param([string]$Title, [int]$W = 460, [int]$H = 220)
    $d                 = New-Object System.Windows.Forms.Form
    $d.Text            = $Title
    $d.Size            = New-Object System.Drawing.Size($W, $H)
    $d.StartPosition   = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox     = $false
    $d.MinimizeBox     = $false
    $d.BackColor       = $clrBg
    $d.Font            = $fontUI
    $d.ShowInTaskbar   = $false
    return $d
}

function New-DialogLabel {
    param([string]$Text, [int]$X, [int]$Y, [bool]$Sub = $false)
    $l         = New-Object System.Windows.Forms.Label
    $l.Text    = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize = $true
    if ($Sub) { $l.ForeColor = $clrSub; $l.Font = $fontSmall } else { $l.ForeColor = $clrText2 }
    return $l
}

function Show-InputDialog {
    param(
        [string]$Title = '输入',
        [string]$Label = '内容',
        [switch]$IsPassword
    )
    $dlg = New-DialogBase -Title $Title -W 440 -H 214

    $l  = New-DialogLabel -Text $Label -X 26 -Y 24
    $t          = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(26, 52)
    $t.Size     = New-Object System.Drawing.Size(372, 28)
    $t.BorderStyle = 'FixedSingle'
    if ($IsPassword) { $t.UseSystemPasswordChar = $true }

    $ok              = New-Pill -Text '确定' -Width 92 -Kind 'primary'
    $ok.DialogResult = 'OK'
    $ok.Location     = New-Object System.Drawing.Point(202, 106)

    $cancel              = New-Pill -Text '取消' -Width 92
    $cancel.DialogResult = 'Cancel'
    $cancel.Location     = New-Object System.Drawing.Point(306, 106)

    $dlg.Controls.AddRange(@($l, $t, $ok, $cancel))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq 'OK') { return $t.Text }
    return $null
}

function Show-NewShareDialog {
    $dlg = New-DialogBase -Title '新增共享' -W 600 -H 452

    $lName = New-DialogLabel -Text '共享名' -X 28 -Y 28
    $tName          = New-Object System.Windows.Forms.TextBox
    $tName.Location = New-Object System.Drawing.Point(116, 24)
    $tName.Size     = New-Object System.Drawing.Size(438, 28)
    $tName.Text     = 'Share'
    $tName.BorderStyle = 'FixedSingle'

    $lPath = New-DialogLabel -Text '物理路径' -X 28 -Y 74
    $tPath          = New-Object System.Windows.Forms.TextBox
    $tPath.Location = New-Object System.Drawing.Point(116, 70)
    $tPath.Size     = New-Object System.Drawing.Size(348, 28)
    $tPath.BorderStyle = 'FixedSingle'
    $cfgBuf         = Get-Config
    $tPath.Text     = (Join-Path $cfgBuf.RootBase 'Share')

    $btnBrowse = New-Pill -Text '浏览' -Width 78
    $btnBrowse.Location = New-Object System.Drawing.Point(476, 69)

    $lProto = New-DialogLabel -Text '发布协议' -X 28 -Y 122

    $cbSmb          = New-Object System.Windows.Forms.CheckBox
    $cbSmb.Text     = 'SMB     ·  Windows 网络共享'
    $cbSmb.Location = New-Object System.Drawing.Point(116, 118)
    $cbSmb.AutoSize = $true
    $cbSmb.Checked  = $true

    $cbDav          = New-Object System.Windows.Forms.CheckBox
    $cbDav.Text     = 'WebDAV  ·  浏览器 / 手机 / 跨平台'
    $cbDav.Location = New-Object System.Drawing.Point(116, 148)
    $cbDav.AutoSize = $true

    $cbFtp          = New-Object System.Windows.Forms.CheckBox
    $cbFtp.Text     = 'FTP     ·  传统设备 / 内网设备'
    $cbFtp.Location = New-Object System.Drawing.Point(116, 178)
    $cbFtp.AutoSize = $true

    $cbSftp          = New-Object System.Windows.Forms.CheckBox
    $cbSftp.Text     = 'SFTP    ·  SSH 加密通道'
    $cbSftp.Location = New-Object System.Drawing.Point(116, 208)
    $cbSftp.AutoSize = $true

    $cbDlna          = New-Object System.Windows.Forms.CheckBox
    $cbDlna.Text     = 'DLNA    ·  电视 / 手机自动发现（无密码，内网可读）'
    $cbDlna.Location = New-Object System.Drawing.Point(116, 238)
    $cbDlna.AutoSize = $true

    $lNote = New-DialogLabel -Text '备注' -X 28 -Y 284
    $tNote          = New-Object System.Windows.Forms.TextBox
    $tNote.Location = New-Object System.Drawing.Point(116, 280)
    $tNote.Size     = New-Object System.Drawing.Size(438, 28)
    $tNote.BorderStyle = 'FixedSingle'

    $ok              = New-Pill -Text '创建' -Width 100 -Kind 'primary'
    $ok.DialogResult = 'OK'
    $ok.Location     = New-Object System.Drawing.Point(336, 350)

    $cancel              = New-Pill -Text '取消' -Width 100
    $cancel.DialogResult = 'Cancel'
    $cancel.Location     = New-Object System.Drawing.Point(448, 350)

    $btnBrowse.Add_Click({
        $fb             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = '选择要共享的目录（也可直接输入不存在的路径，程序会自动创建）'
        if ($fb.ShowDialog() -eq 'OK') { $tPath.Text = $fb.SelectedPath }
    })

    $dlg.Controls.AddRange(@($lName, $tName, $lPath, $tPath, $btnBrowse,
                             $lProto, $cbSmb, $cbDav, $cbFtp, $cbSftp, $cbDlna,
                             $lNote, $tNote, $ok, $cancel))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $protos = @()
        if ($cbSmb.Checked)  { $protos += 'SMB' }
        if ($cbDav.Checked)  { $protos += 'WebDAV' }
        if ($cbFtp.Checked)  { $protos += 'FTP' }
        if ($cbSftp.Checked) { $protos += 'SFTP' }
        if ($cbDlna.Checked) { $protos += 'DLNA' }
        return [pscustomobject]@{
            Name      = $tName.Text.Trim()
            Path      = $tPath.Text.Trim()
            Protocols = $protos
            Note      = $tNote.Text.Trim()
        }
    }
    return $null
}

function Show-SettingsDialog {
    $cfg = Get-Config
    $dlg = New-DialogBase -Title '管理设置' -W 680 -H 372

    $lRoot = New-DialogLabel -Text '共享根目录' -X 28 -Y 32
    $tRoot          = New-Object System.Windows.Forms.TextBox
    $tRoot.Location = New-Object System.Drawing.Point(156, 28)
    $tRoot.Size     = New-Object System.Drawing.Size(388, 28)
    $tRoot.Text     = [string]$cfg.RootBase
    $tRoot.BorderStyle = 'FixedSingle'

    $btnBrowse = New-Pill -Text '浏览' -Width 78
    $btnBrowse.Location = New-Object System.Drawing.Point(556, 27)

    # 三个端口各占一列：标签与输入框之间留足间距，标签不再被截断
    $lPort1 = New-DialogLabel -Text 'WebDAV 端口' -X 28 -Y 84
    $tPort1          = New-Object System.Windows.Forms.TextBox
    $tPort1.Location = New-Object System.Drawing.Point(156, 80)
    $tPort1.Size     = New-Object System.Drawing.Size(110, 28)
    $tPort1.Text     = [string]$cfg.WebDavPort
    $tPort1.BorderStyle = 'FixedSingle'

    $lPort2 = New-DialogLabel -Text 'FTP 端口' -X 320 -Y 84
    $tPort2          = New-Object System.Windows.Forms.TextBox
    $tPort2.Location = New-Object System.Drawing.Point(424, 80)
    $tPort2.Size     = New-Object System.Drawing.Size(110, 28)
    $tPort2.Text     = [string]$cfg.FtpPort
    $tPort2.BorderStyle = 'FixedSingle'

    $lPort3 = New-DialogLabel -Text 'DLNA 端口' -X 28 -Y 128
    $tPort3          = New-Object System.Windows.Forms.TextBox
    $tPort3.Location = New-Object System.Drawing.Point(156, 124)
    $tPort3.Size     = New-Object System.Drawing.Size(110, 28)
    $tPort3.Text     = $(if ($cfg.DlnaPort) { [string]$cfg.DlnaPort } else { '8420' })
    $tPort3.BorderStyle = 'FixedSingle'

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Location  = New-Object System.Drawing.Point(28, 172)
    $lHint.Size      = New-Object System.Drawing.Size(616, 46)
    $lHint.ForeColor = $clrSub
    $lHint.Font      = $fontSmall
    $lHint.Text      = '根目录可填任意本地路径（不存在会自动创建）。WebDAV / FTP 端口改动后需点「重建 IIS 站点」才会生效；DLNA 端口保存后自动生效。'

    $ok              = New-Pill -Text '保存' -Width 100 -Kind 'primary'
    $ok.DialogResult = 'OK'
    $ok.Location     = New-Object System.Drawing.Point(384, 248)

    $cancel              = New-Pill -Text '取消' -Width 100
    $cancel.DialogResult = 'Cancel'
    $cancel.Location     = New-Object System.Drawing.Point(496, 248)

    $btnBrowse.Add_Click({
        $fb             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = '选择共享根目录（也可直接输入不存在的路径，保存时自动创建）'
        if ($fb.ShowDialog() -eq 'OK') { $tRoot.Text = $fb.SelectedPath }
    })

    $dlg.Controls.AddRange(@($lRoot, $tRoot, $btnBrowse, $lPort1, $tPort1,
                             $lPort2, $tPort2, $lPort3, $tPort3, $lHint, $ok, $cancel))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $p1 = 0; $p2 = 0; $p3 = 0
        if (-not [int]::TryParse($tPort1.Text.Trim(), [ref]$p1)) {
            [void][System.Windows.Forms.MessageBox]::Show('WebDAV 端口必须是数字。', '提示', 'OK', 'Warning')
            return $null
        }
        if (-not [int]::TryParse($tPort2.Text.Trim(), [ref]$p2)) {
            [void][System.Windows.Forms.MessageBox]::Show('FTP 端口必须是数字。', '提示', 'OK', 'Warning')
            return $null
        }
        if (-not [int]::TryParse($tPort3.Text.Trim(), [ref]$p3)) {
            [void][System.Windows.Forms.MessageBox]::Show('DLNA 端口必须是数字。', '提示', 'OK', 'Warning')
            return $null
        }
        return [pscustomobject]@{
            RootBase   = $tRoot.Text.Trim()
            WebDavPort = $p1
            FtpPort    = $p2
            DlnaPort   = $p3
        }
    }
    return $null
}

# ============================================================
# 十三、访问方式说明
# ============================================================
$script:Guides = @{
    'SMB' = @{
        Intro = 'Windows 原生的网络共享。资源管理器能直接打开，也可以映射成盘符，速度最快。'
        Steps = @(
            @{ OS = 'Windows'; Lines = @(
                'Win + E 打开资源管理器',
                '地址栏粘贴下面的地址，回车',
                '输入用户名密码，勾选「记住我的凭据」') },
            @{ OS = 'macOS'; Lines = @(
                'Finder → 前往 → 连接服务器（⌘K）',
                '输入 smb://主机名/共享名，点连接') },
            @{ OS = '手机 / 电视盒子'; Lines = @(
                '文件管理器里选「局域网 / SMB 共享」',
                '填主机名与共享名，用同一账号登录') }
        )
        Tip = '需与服务器在同一局域网。Windows 家庭版并发入站连接上限约 20 个，多人同时用要上 Server 版。'
    }
    'WebDAV' = @{
        Intro = '基于 HTTP 的共享，浏览器、手机、跨平台客户端都能挂载，穿透性最好。'
        Steps = @(
            @{ OS = 'Windows'; Lines = @(
                '资源管理器 → 此电脑 → 右键「添加一个网络位置」',
                '粘贴下面的地址，下一步',
                '输入用户名密码，完成') },
            @{ OS = 'macOS'; Lines = @(
                'Finder → 前往 → 连接服务器（⌘K）',
                '输入 http://主机名:端口/共享名，点连接') },
            @{ OS = '手机'; Lines = @(
                '文件 App / ES 文件浏览器 → 添加 WebDAV 账户',
                '填地址、端口、账号密码') }
        )
        Tip = 'Windows 若提示 0x80070043 或无法连接，用管理员身份执行 net start WebClient 后再试。非 HTTPS 为明文传输，建议只在内部网络使用。'
    }
    'FTP' = @{
        Intro = '最通用的老协议，扫描仪、打印机、老式终端、监控设备基本都支持。'
        Steps = @(
            @{ OS = 'Windows'; Lines = @(
                '资源管理器地址栏粘贴 ftp:// 地址，回车',
                '输入用户名密码登录') },
            @{ OS = 'FileZilla / WinSCP'; Lines = @(
                '主机填主机名，端口填 21',
                '输入用户名密码，点快速连接') },
            @{ OS = 'macOS'; Lines = @(
                'Finder → 连接服务器（⌘K）',
                '输入 ftp://主机名:21/共享名（只读）') }
        )
        Tip = 'FTP 的账号密码是明文传输，仅建议在内网使用；需要外网访问请改用 SFTP 或给 WebDAV 配 HTTPS。'
    }
    'SFTP' = @{
        Intro = '跑在 SSH 上的加密文件传输，安全性最高，适合跨网络使用。'
        Steps = @(
            @{ OS = 'Windows'; Lines = @(
                '用 WinSCP 或 FileZilla，协议选 SFTP',
                '主机填主机名，端口填 22',
                '输入 Windows 账号密码登录') },
            @{ OS = 'macOS / Linux'; Lines = @(
                '终端执行 sftp 用户名@主机名',
                '用 ls / get / put 浏览与传输文件') },
            @{ OS = '手机'; Lines = @(
                'Termius / ES 文件浏览器 → 新建 SFTP 连接',
                '填主机名、端口 22、账号密码') }
        )
        Tip = '登录后能访问哪些目录完全由 NTFS 权限决定（Windows 版 OpenSSH 不支持 ChrootDirectory）。'
    }
    'DLNA' = @{
        Intro = '数字生活网络联盟协议：电视、机顶盒、游戏机、手机播放器自动发现媒体服务器，无需输入任何地址。'
        Steps = @(
            @{ OS = '智能电视 / 机顶盒'; Lines = @(
                '打开自带的「媒体中心 / DLNA / 多屏互动」应用',
                '设备列表里选「WinShareManager (主机名)」',
                '按文件夹浏览，直接点播') },
            @{ OS = 'Windows'; Lines = @(
                '资源管理器 → 网络 → 媒体设备',
                '或用 VLC：本地网络 → UPnP / DLNA 发现') },
            @{ OS = '手机 / 平板'; Lines = @(
                'VLC / nPlayer / 倍播 等播放器的 DLNA 入口',
                '选择本设备后按目录点播') }
        )
        Tip = '注意：DLNA 协议本身不支持账号密码，勾选 DLNA 的目录对整个局域网只读开放，请只在内网使用。视频支持拖动进度条（HTTP Range）。'
    }
}

function Show-GuideDialog {
    param([string]$Key)

    $g = $script:Guides[$Key]
    if (-not $g) { return }

    $addr = ''
    try {
        $one = @(Get-ProtocolList) | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
        if ($one) { $addr = [string]$one.Address }
    } catch { }

    $dlg = New-DialogBase -Title ("{0} · 访问方式" -f $Key) -W 676 -H 640
    $dlg.ClientSize = New-Object System.Drawing.Size(660, 600)

    $lAddrTitle = New-DialogLabel -Text '服务地址（把 <共享名> 换成你的共享名）' -X 24 -Y 16

    $tAddr             = New-Object System.Windows.Forms.TextBox
    $tAddr.Location    = New-Object System.Drawing.Point(24, 42)
    $tAddr.Size        = New-Object System.Drawing.Size(468, 28)
    $tAddr.ReadOnly    = $true
    $tAddr.BorderStyle = 'FixedSingle'
    $tAddr.Font        = $fontMono
    $tAddr.BackColor   = [System.Drawing.Color]::White
    $tAddr.Text        = $addr

    $btnCopy = New-Pill -Text '复制地址' -Width 118 -Height 30 -Kind 'soft'
    $btnCopy.Location = New-Object System.Drawing.Point(504, 41)
    $btnCopy.Tag      = $tAddr
    $btnCopy.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText([string]$this.Tag.Text)
            Set-CtrlText -Ctrl $this -Text '已复制'
        } catch {
            Set-CtrlText -Ctrl $this -Text '复制失败'
        }
    })

    $lIntro           = New-Object System.Windows.Forms.Label
    $lIntro.Text      = $g.Intro
    $lIntro.Location  = New-Object System.Drawing.Point(24, 82)
    $lIntro.Size      = New-Object System.Drawing.Size(612, 32)
    $lIntro.ForeColor = $clrText2

    $scroll           = New-Object System.Windows.Forms.Panel
    $scroll.Location  = New-Object System.Drawing.Point(18, 122)
    $scroll.Size      = New-Object System.Drawing.Size(624, 410)
    $scroll.AutoScroll = $true
    $scroll.BackColor = $clrBg

    $y  = 0
    $sw = 592

    foreach ($sec in $g.Steps) {
        $n = $sec.Lines.Count
        $h = 30 + ($n * 22) + 10

        $pn           = New-Object System.Windows.Forms.Panel
        $pn.BackColor = $clrCard
        $pn.Location  = New-Object System.Drawing.Point(0, $y)
        $pn.Size      = New-Object System.Drawing.Size($sw, $h)
        Enable-RoundSurface -Ctrl $pn -Radius 10 -Surface $clrBg

        $hd           = New-Object System.Windows.Forms.Label
        $hd.Text      = $sec.OS
        $hd.Font      = $fontBold
        $hd.ForeColor = $clrAccent
        $hd.BackColor = $clrCard
        $hd.AutoSize  = $true
        $hd.Location  = New-Object System.Drawing.Point(16, 7)
        $pn.Controls.Add($hd)

        for ($i = 0; $i -lt $n; $i++) {
            $ln              = New-Object System.Windows.Forms.Label
            $ln.Text         = ('{0}. {1}' -f ($i + 1), $sec.Lines[$i])
            $ln.ForeColor    = $clrText2
            $ln.BackColor    = $clrCard
            $ln.AutoSize     = $false
            $ln.AutoEllipsis = $true
            $ln.Location     = New-Object System.Drawing.Point(16, (28 + $i * 22))
            $ln.Size         = New-Object System.Drawing.Size(($sw - 32), 20)
            $pn.Controls.Add($ln)
        }

        $scroll.Controls.Add($pn)
        $y += $h + 8
    }

    if ($g.Tip) {
        $tp           = New-Object System.Windows.Forms.Panel
        $tp.BackColor = $clrOrangeSoft
        $tp.Location  = New-Object System.Drawing.Point(0, $y)
        $tp.Size      = New-Object System.Drawing.Size($sw, 64)
        Enable-RoundSurface -Ctrl $tp -Radius 10 -Surface $clrBg

        $tl           = New-Object System.Windows.Forms.Label
        $tl.Text      = '提示：' + $g.Tip
        $tl.ForeColor = $clrOrange
        $tl.BackColor = $clrOrangeSoft
        $tl.Location  = New-Object System.Drawing.Point(16, 12)
        $tl.Size      = New-Object System.Drawing.Size(($sw - 32), 42)
        $tp.Controls.Add($tl)

        $scroll.Controls.Add($tp)
    }

    $btnClose              = New-Pill -Text '关闭' -Width 100 -Height 32 -Kind 'primary'
    $btnClose.Location     = New-Object System.Drawing.Point(536, 548)
    $btnClose.DialogResult = 'OK'

    $dlg.Controls.AddRange(@($lAddrTitle, $tAddr, $btnCopy, $lIntro, $scroll, $btnClose))
    $dlg.AcceptButton = $btnClose
    $dlg.CancelButton = $btnClose

    # 仅在开发核对时启用：把对话框挪到屏幕外、截图后自动关闭
    if ($env:WSM_DLG_SHOT) {
        try {
            $dlg.StartPosition = 'Manual'
            $dlg.Location      = New-Object System.Drawing.Point(-5000, -5000)
            $dlg.ShowInTaskbar = $false
            $capTimer          = New-Object System.Windows.Forms.Timer
            $capTimer.Interval = 700
            $capTimer.Tag      = @{ Dlg = $dlg; Path = ("{0}_{1}.png" -f $env:WSM_DLG_SHOT, $Key) }
            $capTimer.Add_Tick({
                $capTimer.Stop()
                $info = $capTimer.Tag
                $d    = $info.Dlg
                try {
                    $bmp = New-Object System.Drawing.Bitmap($d.Width, $d.Height)
                    $rc  = New-Object System.Drawing.Rectangle(0, 0, $d.Width, $d.Height)
                    $d.DrawToBitmap($bmp, $rc)
                    $bmp.Save([string]$info.Path, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose()
                } catch { }
                $d.Close()
            })
            $capTimer.Start()
        } catch { }
    }

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# ============================================================
# 十四、事件：协议卡片
# ============================================================
foreach ($key in @('SMB', 'WebDAV', 'FTP', 'SFTP')) {
    $card = $script:Cards[$key]

    # ---- 安装组件：交给子进程跑，界面全程可响应 ----
    $card.Install.Add_Click({
        $k = [string]$this.Tag
        if (-not (Test-Admin)) {
            [void][System.Windows.Forms.MessageBox]::Show('需要以管理员身份运行本程序。', '权限不足', 'OK', 'Warning')
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "即将安装 $k 协议所需的 Windows 组件，约需 1-5 分钟（部分需要重启）。`r`n`r`n安装过程在后台进行，窗口不会卡住。",
            "安装 $k 组件", 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }

        $res = Invoke-LongTask -Task 'InstallProtocol' -Arg1 $k `
                               -Title "正在安装 $k 组件" `
                               -SubTitle '正在调用 Windows 组件安装接口，首次安装需要联网下载，请稍候'

        Refresh-ProtocolView
        if ($res -eq 'bg') {
            Set-Status "$k 组件正在后台安装 · 完成后点「刷新状态」"
        } elseif ($res -eq $true) {
            Set-Status "$k 组件安装完成"
        } else {
            Set-Status "$k 组件安装失败 · 详情见「日志」页"
        }
    })

    # ---- 滑块开关：一个控件管启停 ----
    $card.Toggle.Add_Click({
        $k  = [string]$this.Tag.Key
        $on = [bool]$this.Tag.On

        if (-not (Test-Admin)) {
            [void][System.Windows.Forms.MessageBox]::Show('需要以管理员身份运行本程序。', '权限不足', 'OK', 'Warning')
            return
        }

        # 从「关」拨到「开」= 启动；从「开」拨到「关」= 停止
        $wantOn = -not $on
        if ($wantOn -eq $false) {
            $msg = "确认停止 $k 服务？"
            if ($k -eq 'SMB') { $msg = "确认停止 SMB 服务？`r`n`r`n本机所有共享（含管理共享）都会中断。" }
            $r = [System.Windows.Forms.MessageBox]::Show($msg, "停止 $k", 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }

        $form.Cursor = 'WaitCursor'
        try {
            if ($wantOn) { Start-Protocol -Key $k | Out-Null }
            else         { Stop-Protocol  -Key $k | Out-Null }
        } catch {
            Write-Op "$(if ($wantOn) { '启动' } else { '停止' }) $k 异常：$($_.Exception.Message)" 'ERR'
        } finally {
            $form.Cursor = 'Default'
        }
        Refresh-ProtocolView
        if (-not $wantOn) { Refresh-ShareView }
    })

    $card.Guide.Add_Click({
        $k = [string]$this.Tag
        try { Show-GuideDialog -Key $k } catch { Write-Op "打开访问方式失败：$($_.Exception.Message)" 'ERR' }
    })
}

# ============================================================
# 十五、事件：工具条
# ============================================================
$btnSettings.Add_Click({
    $data = Show-SettingsDialog
    if (-not $data) { return }
    if (Save-Settings -RootBase $data.RootBase -WebDavPort $data.WebDavPort -FtpPort $data.FtpPort -DlnaPort $data.DlnaPort) {
        Refresh-ProtocolView
        [void][System.Windows.Forms.MessageBox]::Show(
            '设置已保存。若改过 WebDAV / FTP 端口，请点「重建 IIS 站点」使其生效。',
            '已保存', 'OK', 'Information')
    }
})

$btnRebuild.Add_Click({
    if (-not (Test-Admin)) {
        [void][System.Windows.Forms.MessageBox]::Show('需要以管理员身份运行本程序。', '权限不足', 'OK', 'Warning')
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "将删除并按当前配置重建 WebDAV 与 FTP 站点，随后重新挂载所有已登记的共享目录。`r`n`r`n确认继续？",
        '重建 IIS 站点', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    $res = Invoke-LongTask -Task 'RebuildSites' `
                           -Title '正在重建 IIS 站点' `
                           -SubTitle '按当前配置删除并重建 WebDAV / FTP 站点，然后重新挂载所有共享'

    Refresh-ProtocolView
    Refresh-ShareView
    if ($res -eq 'bg')      { Set-Status '重建站点正在后台进行 · 完成后点「刷新状态」' }
    elseif ($res -eq $true) { Set-Status 'IIS 站点已重建' }
    else                    { Set-Status '重建 IIS 站点失败 · 详情见「日志」页' }
})

$btnRefreshP.Add_Click({
    try { Refresh-ProtocolView } catch { }
})

# ============================================================
# 十六、事件：共享 / 用户 / 权限
# ============================================================
$btnRefreshShare.Add_Click({ try { Refresh-ShareView } catch { } })

$btnAddShare.Add_Click({
    $data = Show-NewShareDialog
    if (-not $data) { return }
    if (-not $data.Name) {
        [void][System.Windows.Forms.MessageBox]::Show('共享名不能为空。', '提示', 'OK', 'Warning')
        return
    }
    if ($data.Protocols.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请至少选择一种协议。', '提示', 'OK', 'Warning')
        return
    }
    $form.Cursor = 'WaitCursor'
    try {
        New-ShareEntry -Name $data.Name -Path $data.Path -Protocols $data.Protocols -Note $data.Note | Out-Null
        Refresh-ShareView
        Refresh-ProtocolView
    } catch {
        Write-Op "创建共享异常：$($_.Exception.Message)" 'ERR'
    } finally {
        $form.Cursor = 'Default'
    }
})

$btnDelShare.Add_Click({
    if ($null -eq $gridShare.CurrentRow) { return }
    $name = [string]$gridShare.CurrentRow.Cells['共享名'].Value
    $msg  = "确认删除共享「$name」？`r`n`r`n将移除 SMB 共享、WebDAV 与 FTP 的目录映射，磁盘文件不会被删除。"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, '删除确认', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $form.Cursor = 'WaitCursor'
    try {
        Remove-ShareEntry -Name $name | Out-Null
        Refresh-ShareView
        Refresh-ProtocolView
    } catch {
        Write-Op "删除异常：$($_.Exception.Message)" 'ERR'
    } finally {
        $form.Cursor = 'Default'
    }
})

$btnOpenShare.Add_Click({
    if ($null -eq $gridShare.CurrentRow) { return }
    $path = [string]$gridShare.CurrentRow.Cells['物理路径'].Value
    try { Start-Process explorer.exe -ArgumentList $path } catch { Write-Op '无法打开目录。' 'WARN' }
})

# 分组显示：非组首行的「共享名 / 物理路径」留空，组首行加粗，避免同名重复四遍
$gridShare.Add_CellFormatting({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $col = [string]$sender.Columns[$e.ColumnIndex].Name
    if ($col -ne '共享名' -and $col -ne '物理路径') { return }

    $first = $sender.Rows[$e.RowIndex].Cells['组首'].Value
    if (($first -eq $true) -or ("$first" -eq 'True')) {
        if ($col -eq '共享名') {
            $cs      = $e.CellStyle.Clone()
            $cs.Font = $fontBold
            $e.CellStyle = $cs
        }
        return
    }
    $e.Value = ''
    $e.FormattingApplied = $true
})

$gridShare.Add_CellContentClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $colName = [string]$sender.Columns[$e.ColumnIndex].Name

    # ---- 复制链接 ----
    if ($colName -eq '复制') {
        $link = [string]$sender.Rows[$e.RowIndex].Cells['链接'].Value
        if ([string]::IsNullOrWhiteSpace($link)) {
            [void][System.Windows.Forms.MessageBox]::Show('该共享没有可复制的链接。', '提示', 'OK', 'Warning')
            return
        }
        try {
            [System.Windows.Forms.Clipboard]::SetText($link)
            Set-Status "已复制：$link"
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("复制失败：$($_.Exception.Message)", '提示', 'OK', 'Warning')
        }
        return
    }

    # ---- 打开（按协议挑一个打得开的动作）----
    if ($colName -eq '打开') {
        $proto = [string]$sender.Rows[$e.RowIndex].Cells['协议键'].Value
        $link  = [string]$sender.Rows[$e.RowIndex].Cells['链接'].Value
        $path  = [string]$sender.Rows[$e.RowIndex].Cells['物理路径'].Value
        $name  = [string]$sender.Rows[$e.RowIndex].Cells['共享名'].Value

        switch ($proto) {
            'SMB' {
                try {
                    Start-Process explorer.exe -ArgumentList $link
                    Set-Status "已在资源管理器中打开 $link"
                } catch {
                    [void][System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)", '提示', 'OK', 'Warning')
                }
            }
            'WebDAV' {
                # http:// 交给默认浏览器；要挂成驱动器得先 net start WebClient
                try {
                    Start-Process -FilePath $link
                    Set-Status "已在浏览器中打开 $link"
                } catch {
                    [void][System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)", '提示', 'OK', 'Warning')
                }
            }
            'FTP' {
                # 现代浏览器都已移除 ftp:// 支持，交给资源管理器的 FTP 文件夹
                try {
                    Start-Process explorer.exe -ArgumentList $link
                    Set-Status "已在资源管理器中打开 $link（打不开请用 FileZilla 等 FTP 客户端）"
                } catch {
                    [void][System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)", '提示', 'OK', 'Warning')
                }
            }
            'SFTP' {
                # sftp:// 没有系统级处理器；优先带起 GUI 客户端，
                # 其次用 Windows 自带的 OpenSSH 命令行客户端开个控制台直连，
                # 两者都没有才退回「复制路径 + 指引」。
                # 登录用户必须显式指定——不指定的话 sftp.exe 默认拿当前
                # Windows 账户（administrator）去连，而共享授权的往往不是它。
                try { [System.Windows.Forms.Clipboard]::SetText($path) } catch { }

                $sftpUser = ''
                try {
                    $sftpUser = [string](Get-SftpLastUser)
                } catch { }
                try {
                    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
                    $typed = [Microsoft.VisualBasic.Interaction]::InputBox(
                        "SFTP 登录用户名（建议用共享授权的账号）：`r`n`r`n远程路径已复制到剪贴板：$path",
                        'SFTP 登录用户', $sftpUser)
                } catch { $typed = $sftpUser }
                if ([string]::IsNullOrWhiteSpace($typed)) {
                    Set-Status '已取消 SFTP 连接 · 远程路径仍在剪贴板'
                    return
                }
                $sftpUser = $typed.Trim()
                Set-SftpLastUser -User $sftpUser

                $winscp = @("$env:ProgramFiles\WinSCP\WinSCP.exe",
                            "${env:ProgramFiles(x86)}\WinSCP\WinSCP.exe") |
                          Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($winscp) {
                    try {
                        Start-Process -FilePath $winscp -ArgumentList "sftp://${sftpUser}@$env:COMPUTERNAME/"
                        Set-Status "已启动 WinSCP（用户 $sftpUser）· 远程路径已复制：$path"
                    } catch { Start-Process -FilePath $winscp }
                    return
                }
                $filezilla = @("$env:ProgramFiles\FileZilla FTP Client\filezilla.exe",
                               "${env:ProgramFiles(x86)}\FileZilla FTP Client\filezilla.exe") |
                             Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($filezilla) {
                    try {
                        Start-Process -FilePath $filezilla -ArgumentList "sftp://${sftpUser}@$env:COMPUTERNAME"
                        Set-Status "已启动 FileZilla（用户 $sftpUser）· 远程路径已复制：$path"
                    } catch { Start-Process -FilePath $filezilla }
                    return
                }
                $sftpExe = Join-Path $env:windir 'System32\OpenSSH\sftp.exe'
                if (-not (Test-Path $sftpExe)) {
                    try { $sftpExe = (Get-Command sftp.exe -ErrorAction Stop).Source } catch { $sftpExe = $null }
                }
                if ($sftpExe -and (Test-Path $sftpExe)) {
                    try {
                        Start-Process -FilePath "$env:windir\System32\cmd.exe" `
                            -ArgumentList "/k", "`"$sftpExe`" ${sftpUser}@$env:COMPUTERNAME"
                        Set-Status "已打开命令行以 $sftpUser 连接本机 SFTP（输入密码登录，cd 到共享目录）· 远程路径已复制：$path"
                    } catch {
                        [void][System.Windows.Forms.MessageBox]::Show(
                            "启动 sftp.exe 失败：$($_.Exception.Message)",
                            'SFTP 打开方式', 'OK', 'Warning')
                    }
                    return
                }
                [void][System.Windows.Forms.MessageBox]::Show(
                    "本机没有 WinSCP / FileZilla，也没有 OpenSSH 命令行客户端。`n`n" +
                    "已复制远程路径：$path`n请安装 WinSCP 或 FileZilla 后重试。",
                    'SFTP 打开方式', 'OK', 'Information')
                Set-Status "已复制远程路径 $path · 粘到 SFTP 客户端的远程目录里"
            }
            'DLNA' {
                # DLNA 没有系统级处理器：设备在网络邻居 / 播放器里自动发现
                [void][System.Windows.Forms.MessageBox]::Show(
                    "DLNA 不需要「打开」，设备会自动发现本服务器：`r`n`r`n" +
                    "· 智能电视 / 机顶盒：打开「媒体中心 / DLNA / 多屏互动」应用`r`n" +
                    "· Windows：资源管理器 → 网络 → 媒体设备`r`n" +
                    "· 手机 / 平板：VLC、nPlayer 等播放器的 DLNA 入口`r`n`r`n" +
                    "设备列表里选「WinShareManager ($env:COMPUTERNAME)」即可浏览点播。`r`n" +
                    "注意：DLNA 无账号密码，勾选 DLNA 的目录对整个局域网只读开放。",
                    'DLNA 使用方式', 'OK', 'Information')
                Set-Status 'DLNA 设备会自动发现本服务器 · 在电视或播放器的媒体列表里选择'
            }
        }
        return
    }

    # ---- 删除这一行的协议 ----
    if ($colName -eq '删除') {
        $name  = [string]$sender.Rows[$e.RowIndex].Cells['共享名'].Value
        $proto = [string]$sender.Rows[$e.RowIndex].Cells['协议键'].Value
        if (-not $name -or -not $proto) { return }

        if (-not (Test-Admin)) {
            [void][System.Windows.Forms.MessageBox]::Show('需要以管理员身份运行本程序。', '权限不足', 'OK', 'Warning')
            return
        }

        $other = @()
        try {
            $one = Get-ShareList | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($one) { $other = @($one.Protocols | Where-Object { $_ -ne $proto }) }
        } catch { }

        $tail = '磁盘上的文件不会被删除。'
        if ($other.Count -eq 0) {
            $tail = "这是「$name」上最后一个协议，删除后整条共享记录也会一并移除；磁盘文件不会被删除。"
        } else {
            $tail = "「$name」仍会通过 $($other -join ' / ') 继续提供访问。磁盘文件不会被删除。"
        }

        $r = [System.Windows.Forms.MessageBox]::Show(
            "确认只删除「$name」的 $proto 协议？`r`n`r`n$tail",
            "删除 $proto 协议", 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }

        $res = Invoke-LongTask -Task 'RemoveShareProtocol' -Arg1 $name -Arg2 $proto `
                               -Title "正在删除 $name 的 $proto" `
                               -SubTitle '正在移除该协议的共享映射，其它协议不受影响'

        Refresh-ShareView
        Refresh-ProtocolView
        if ($res -eq 'bg')      { Set-Status "正在后台删除 $name 的 $proto · 完成后点「刷新」" }
        elseif ($res -eq $true) { Set-Status "已删除 $name 的 $proto 协议" }
        else                    { Set-Status "删除 $name 的 $proto 失败 · 详情见「日志」页" }
        return
    }
})

$btnRefreshUser.Add_Click({ try { Refresh-UserView } catch { } })

$btnShowSys.Add_Click({
    $script:ShowAllUsers = -not $script:ShowAllUsers
    if ($script:ShowAllUsers) {
        Set-CtrlText -Ctrl $btnShowSys -Text '隐藏系统账户'
        $btnShowSys.AccessibleDescription = 'soft'
    } else {
        Set-CtrlText -Ctrl $btnShowSys -Text '显示系统账户'
        $btnShowSys.AccessibleDescription = 'ghost'
    }
    Set-PillColors -Btn $btnShowSys -State 'normal'
    $btnShowSys.Invalidate()
    Refresh-UserView
    Refresh-AclView
})

$btnNewUser.Add_Click({
    $name = Show-InputDialog -Title '新建用户' -Label '用户名'
    if (-not $name) { return }
    $pwd = Show-InputDialog -Title "新建用户 $name" -Label '密码' -IsPassword
    if (-not $pwd) { return }
    if (New-SrvUser -Name $name.Trim() -Password $pwd) { Refresh-UserView }
})

$btnPwdUser.Add_Click({
    if ($null -eq $gridUser.CurrentRow) { return }
    $name = [string]$gridUser.CurrentRow.Cells[0].Value
    $pwd  = Show-InputDialog -Title "设置密码 · $name" -Label '新密码' -IsPassword
    if (-not $pwd) { return }
    if (Set-SrvUserPassword -Name $name -Password $pwd) { Refresh-UserView }
})

$btnToggleUser.Add_Click({
    if ($null -eq $gridUser.CurrentRow) { return }
    $name   = [string]$gridUser.CurrentRow.Cells[0].Value
    $state  = [string]$gridUser.CurrentRow.Cells[2].Value
    $enable = ($state -eq '已禁用')
    if (Set-SrvUserEnabled -Name $name -Enabled $enable) { Refresh-UserView }
})

$btnDelUser.Add_Click({
    if ($null -eq $gridUser.CurrentRow) { return }
    $name = [string]$gridUser.CurrentRow.Cells[0].Value
    $r = [System.Windows.Forms.MessageBox]::Show("确认删除本地用户「$name」？此操作不可恢复。", '删除确认', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    if (Remove-SrvUser -Name $name) { Refresh-UserView }
})

$cmbPermShare.Add_SelectedIndexChanged({
    try { Refresh-AclView } catch { }
})

$btnApplyPerm.Add_Click({
    if ($cmbPermShare.SelectedIndex -lt 0 -or $cmbPermUser.SelectedIndex -lt 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请先选择共享目录和用户。', '提示', 'OK', 'Warning')
        return
    }
    $name    = [string]$cmbPermShare.SelectedItem
    $display = [string]$cmbPermUser.SelectedItem
    $user    = $display
    if ($script:PermUserMap -and $script:PermUserMap.ContainsKey($display)) {
        $user = [string]$script:PermUserMap[$display]
    }
    $entry = Get-ShareList | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $entry) { return }

    $lvName = @{ 'Read' = '只读'; 'Write' = '读写'; 'Full' = '完全控制' }[$script:PermLevel]

    Set-PathPermission -Path $entry.Path -User $user -Level $script:PermLevel | Out-Null
    Refresh-AclView
    Set-Status "已给 $display 在「$name」上设定 $lvName 权限"
})

$btnRevokePerm.Add_Click({
    if ($cmbPermShare.SelectedIndex -lt 0 -or $cmbPermUser.SelectedIndex -lt 0) { return }
    $name    = [string]$cmbPermShare.SelectedItem
    $display = [string]$cmbPermUser.SelectedItem
    $user    = $display
    if ($script:PermUserMap -and $script:PermUserMap.ContainsKey($display)) {
        $user = [string]$script:PermUserMap[$display]
    }
    $entry = Get-ShareList | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $entry) { return }

    $r = [System.Windows.Forms.MessageBox]::Show(
        "确认撤销 $display 在「$name」上的全部直接授权？`r`n`r`n从上级目录继承来的权限不受影响。",
        '撤销授权', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    Set-PathPermission -Path $entry.Path -User $user -Level 'Remove' | Out-Null
    Refresh-AclView
    Set-Status "已撤销 $display 在「$name」上的授权"
})

# ============================================================
# 十七、启动
# ============================================================
Set-PermLevel -Level 'Read'
Show-Page -Index 0

# 首轮状态刷新。抽成独立函数有两个目的：
#   1) Timer 回调里只调用它，回调体保持极简（作用域坑少）
#   2) 界面自检（WSM_SMOKE）也能直接调用，真正测到这条路径
function Invoke-StartupRefresh {
    try { Refresh-ProtocolView } catch { Write-Op "协议状态读取失败：$($_.Exception.Message)" 'ERR' }
    try { Refresh-ShareView }    catch { Write-Op "共享读取失败：$($_.Exception.Message)" 'ERR' }
    try { Refresh-UserView }     catch { Write-Op "用户读取失败：$($_.Exception.Message)" 'ERR' }
    try { Refresh-AclView }      catch { }
    # 有勾选 DLNA 的共享就自动拉起内置媒体服务器（协议随程序进程存活）
    try {
        $dlnaShares = @(Get-ShareList | Where-Object { $_.Protocols -contains 'DLNA' })
        if ($dlnaShares.Count -gt 0 -and -not $script:Dlna.Running -and (Test-Admin)) {
            [void](Start-DlnaServer)
            Refresh-ProtocolView
        }
    } catch { Write-Op "DLNA 自动启动失败：$($_.Exception.Message)" 'WARN' }
    Trace-Startup '首轮状态刷新完成'
    Set-Status '就绪'
}

$form.Add_Shown({
    Trace-Startup '窗体已显示（Shown 触发）'
    Write-Op "程序启动 v$($script:AppVersion)，运行身份：$([Security.Principal.WindowsIdentity]::GetCurrent().Name)" 'INFO'
    if (-not $isAdmin) {
        Write-Op '当前非管理员身份，安装组件与修改共享会失败，请右键「以管理员身份运行」。' 'WARN'
    }
    # 全窗体开双缓冲，消除拖动缩放窗口时的残影线条
    Enable-DoubleBufferTree -Ctrl $form
    $form.Invalidate()

    # 首轮状态刷新放到 120ms 后的一次性 Timer 里跑：
    # Shown 事件是在窗口刚创建、还没画第一帧的时候同步执行的，
    # 在这里直接刷状态（读 IIS 模块 / DISM / SMB）会把「窗口出现」
    # 卡在后面好几秒，看起来就像「点了没反应、进程在但没窗口」。
    #
    # 注意：Timer 必须挂在 $script: 上，且回调里用 param($s,$e) 拿发送者 ——
    # 事件处理器的执行作用域看不到这里定义的局部变量（局部 $timer 会是 null），
    # 一旦在回调里引用就会抛「不能对 Null 值表达式调用方法」。
    Set-Status '正在检测系统状态 ...'
    $script:StartupTimer          = New-Object System.Windows.Forms.Timer
    $script:StartupTimer.Interval = 120
    $script:StartupTimer.Add_Tick({
        param($s, $e)
        $s.Stop()
        $s.Dispose()
        $script:StartupTimer = $null
        Invoke-StartupRefresh
    })
    $script:StartupTimer.Start()
})

# ---- 构建自检（仅设置 WSM_SMOKE=1 时启用，不显示窗口）----
if ($env:WSM_SMOKE -eq '1') {
    $log = New-Object System.Collections.Generic.List[string]
    $fail = 0

    try {
        $log.Add(("窗口创建 : OK  尺寸 {0}x{1}" -f $form.Width, $form.Height))
        $log.Add(("页面数量 : {0}" -f $script:Pages.Count))
        $log.Add(("导航按钮 : {0}" -f $script:SegBtns.Count))
        $log.Add(("协议卡片 : {0}" -f $script:Cards.Count))
    } catch { $fail++; $log.Add("基础结构 : FAIL $($_.Exception.Message)") }

    try {
        if ($form.Icon) {
            $log.Add(("窗口图标 : OK  {0}x{1}（标题栏 / 任务栏同源）" -f $form.Icon.Width, $form.Icon.Height))
        } else {
            $fail++; $log.Add('窗口图标 : FAIL 未设置，会退回 WinForms 默认图标')
        }
    } catch { $fail++; $log.Add("窗口图标 : FAIL $($_.Exception.Message)") }

    try {
        $verOk = ($form.Text -like "*v$($script:AppVersion)*")
        if (-not $verOk) { $fail++ }
        $lnkOk = ($null -ne $lnkRepo) -and ($lnkRepo.Tag.Url -eq $script:AppRepoUrl)
        if (-not $lnkOk) { $fail++ }
        # 明文地址不应该再出现在状态栏里
        $plain = (@($statusBar.Items) | Where-Object { $_.Text -like "*$($script:AppRepoName)*" }).Count
        if ($plain -gt 0) { $fail++ }
        $log.Add(("版本与链接 : {0}  标题「{1}」  仓库图标 {2}  状态栏明文 {3}" -f `
                  $(if ($verOk -and $lnkOk -and $plain -eq 0) { 'OK' } else { 'FAIL' }),
                  $form.Text, $(if ($lnkOk) { 'OK' } else { 'FAIL' }), $plain))
    } catch { $fail++; $log.Add("版本与链接 : FAIL $($_.Exception.Message)") }

    # 启动耗时：探测必须走缓存与文件级判断，不能碰 DISM
    try {
        $script:FeatureCache.Clear()
        $t1 = [Diagnostics.Stopwatch]::StartNew(); [void](Get-ProtocolList); $t1.Stop()
        $t2 = [Diagnostics.Stopwatch]::StartNew(); [void](Get-PluginList);   $t2.Stop()
        $t3 = [Diagnostics.Stopwatch]::StartNew(); [void](Get-ProtocolList); $t3.Stop()
        $slow = ($t1.ElapsedMilliseconds -gt 2500)
        if ($slow) { $fail++ }
        $log.Add(("探测耗时 : 协议 {0} ms / 插件 {1} ms / 缓存命中 {2} ms  {3}" -f `
                  $t1.ElapsedMilliseconds, $t2.ElapsedMilliseconds, $t3.ElapsedMilliseconds,
                  $(if ($slow) { 'FAIL 超过 2.5 秒' } else { 'OK' })))
    } catch { $log.Add("探测耗时 : 测量失败 $($_.Exception.Message)") }

    foreach ($i in 0..($script:Pages.Count - 1)) {
        try {
            Show-Page -Index $i
            $ok = ($script:ActivePage -eq $i)
            if (-not $ok) { $fail++ }
            $log.Add(("切换页面 : {0} {1}" -f $segLabels[$i], $(if ($ok) { 'OK' } else { 'FAIL' })))
        } catch { $fail++; $log.Add("切换页面 $i : FAIL $($_.Exception.Message)") }
    }
    Show-Page -Index 0

    foreach ($fn in @('Refresh-ProtocolView', 'Refresh-ShareView', 'Refresh-UserView', 'Refresh-AclView')) {
        try {
            & $fn
            $log.Add(("刷新 {0} : OK" -f $fn))
        } catch { $fail++; $log.Add(("刷新 {0} : FAIL {1}" -f $fn, $_.Exception.Message)) }
    }

    # 真正走一遍启动刷新路径（Timer 回调里调用的就是它）
    try {
        Invoke-StartupRefresh
        $log.Add(("启动刷新路径 : OK（状态栏「{0}」）" -f $statusLabel.Text))
    } catch { $fail++; $log.Add("启动刷新路径 : FAIL $($_.Exception.Message)") }

    try {
        Set-PermLevel -Level 'Write'
        Set-PermLevel -Level 'Full'
        Set-PermLevel -Level 'Read'
        $log.Add(("权限级别切换 : OK（当前 {0}）" -f $script:PermLevel))
    } catch { $fail++; $log.Add("权限级别切换 : FAIL $($_.Exception.Message)") }

    try {
        $ord = $gridShare.Columns | Sort-Object DisplayIndex | ForEach-Object { $_.Name }
        $log.Add(("共享表格列序 : {0}" -f ($ord -join ' | ')))
        $log.Add(("ACL 表格列数 : {0}   用户表格行数 : {1}" -f $gridAcl.Columns.Count, $gridUser.Rows.Count))
        $log.Add(("状态栏文案 : {0}" -f $statusLabel.Text))
    } catch { }

    $log.Add('')
    if ($fail -eq 0) { $log.Add('SMOKE_RESULT=OK') } else { $log.Add("SMOKE_RESULT=FAIL($fail)") }

    # ---- 可选：离屏渲染每一页为 PNG，用于目视核对（不会显示在桌面上）----
    if ($env:WSM_SHOT) {
        try {
            $form.ShowInTaskbar = $false
            $form.StartPosition = 'Manual'
            $form.Location      = New-Object System.Drawing.Point(-5000, -5000)
            $form.Show()
            [System.Windows.Forms.Application]::DoEvents()

            for ($i = 0; $i -lt $script:Pages.Count; $i++) {
                Show-Page -Index $i
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 350
                [System.Windows.Forms.Application]::DoEvents()

                $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                $rc  = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
                $form.DrawToBitmap($bmp, $rc)
                $dst = "{0}_p{1}.png" -f $env:WSM_SHOT, $i
                $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $log.Add(("已渲染 : {0}" -f $dst))
            }
            # 可选：放大窗口后再渲染一遍，专门用来抓「拖动缩放留下线条残影」
            if ($env:WSM_SHOT_SIZE) {
                $parts = ([string]$env:WSM_SHOT_SIZE) -split 'x'
                if ($parts.Count -eq 2) {
                    $form.Size = New-Object System.Drawing.Size([int]$parts[0], [int]$parts[1])
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 350
                    Show-Page -Index 0
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 250
                    [System.Windows.Forms.Application]::DoEvents()
                    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                    $rc  = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
                    $form.DrawToBitmap($bmp, $rc)
                    $dst = "{0}_resized.png" -f $env:WSM_SHOT
                    $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose()
                    $log.Add(("已渲染 : {0}  ({1}x{2})" -f $dst, $form.Width, $form.Height))
                }
            }

            Show-Page -Index 0
            $form.Hide()

            # 可选：逐个打开「访问方式」对话框，截图后自动关闭
            if ($env:WSM_DLG_SHOT) {
                foreach ($gk in @('SMB', 'WebDAV', 'FTP', 'SFTP')) {
                    try { Show-GuideDialog -Key $gk } catch { $log.Add(("对话框渲染失败（{0}）：{1}" -f $gk, $_.Exception.Message)) }
                }
                $log.Add('已渲染：访问方式对话框 x4')
            }

            # 可选：起一个立刻失败的后台任务，只为了把进度对话框截下来
            if ($env:WSM_TASK_SHOT) {
                try {
                    [void](Invoke-LongTask -Task 'NoSuchTask' `
                                           -Title '任务进度对话框（自检渲染）' `
                                           -SubTitle '这是一次界面自检，不会修改任何系统设置')
                    $log.Add('已渲染：后台任务进度对话框')
                } catch {
                    $log.Add('任务对话框渲染失败 : ' + $_.Exception.Message)
                }
            }
        } catch {
            $log.Add('渲染失败 : ' + $_.Exception.Message)
        }
    }

    $outFile = Join-Path $env:TEMP 'wsm_smoke.txt'
    [System.IO.File]::WriteAllText($outFile, ($log -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ($log -join "`r`n")

    $form.Dispose()
    exit 0
}

Trace-Startup '窗体构建完成，准备 ShowDialog'
# 退出时先关掉内置 DLNA 服务器（要给客户端发 byebye，别让设备列表里留尸体）
$form.Add_FormClosed({
    try {
        if ($script:Dlna.Running) { [void](Stop-DlnaServer) }
    } catch { }
})
[void]$form.ShowDialog()
$form.Dispose()
