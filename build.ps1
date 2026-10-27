#requires -Version 5.1
<#
    build.ps1
    把 ShareManager.Core.ps1（逻辑层）+ App.UI.ps1（界面层）拼成单个脚本，
    再编译成单文件 exe（请求管理员权限、无控制台黑框、带图标）。

    产物：
      WinShareManager.ps1   合并后的单文件脚本（可直接用 powershell 运行，作为备用）
      WinShareManager.exe   真·单文件程序，双击即用

    用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipExe,
    [switch]$KeepOld,
    [switch]$ForceIcon
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

$corePath = Join-Path $root 'ShareManager.Core.ps1'
$uiPath   = Join-Path $root 'App.UI.ps1'
$outPs1   = Join-Path $root 'WinShareManager.ps1'
$outExe   = Join-Path $root 'WinShareManager.exe'
$icoPath  = Join-Path $root 'app.ico'

foreach ($p in @($corePath, $uiPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少源文件：$p" }
}

function Write-Step { param([string]$Text) Write-Host "  $Text" -ForegroundColor Cyan }

Write-Host ''
Write-Host '=== 构建单文件 WinShareManager ===' -ForegroundColor White
Write-Host ''

# ------------------------------------------------------------
# 1. 读取源文件并剥离 Core 的头部（#requires + 注释帮助）
# ------------------------------------------------------------
Write-Step '读取源文件 ...'
$core = [System.IO.File]::ReadAllText($corePath, [System.Text.Encoding]::UTF8)
$ui   = [System.IO.File]::ReadAllText($uiPath,   [System.Text.Encoding]::UTF8)

$core = $core -replace '^\uFEFF', ''
$ui   = $ui   -replace '^\uFEFF', ''

# ------------------------------------------------------------
# 1.5 解析版本号（唯一事实来源 = Core 里的 $script:AppVersion）
# ------------------------------------------------------------
$vm = [regex]::Match($core, '\$script:AppVersion\s*=\s*''([^'']+)''')
if (-not $vm.Success) {
    throw '未能在 ShareManager.Core.ps1 中解析到 $script:AppVersion，无法确定版本号。'
}
$appVersion = $vm.Groups[1].Value
$asmVersion = if ($appVersion -match '^\d+\.\d+\.\d+$') { "$appVersion.0" } else { $appVersion }
Write-Step ("版本号 {0} → 程序集版本 {1}" -f $appVersion, $asmVersion)

$before = $core.Length
$core = [regex]::Replace($core, '\A\s*#requires[^\r\n]*\r?\n\s*<#.*?#>\s*', '', 'Singleline')
if ($core.Length -eq $before) {
    throw '未能剥离 ShareManager.Core.ps1 的头部，请检查该文件是否仍以 #requires + <# ... #> 开头。'
}
Write-Step ("Core 头部已剥离（{0} -> {1} 字符）" -f $before, $core.Length)

# ------------------------------------------------------------
# 2. 拼接
# ------------------------------------------------------------
$preamble = @'
#requires -Version 5.1
<#
    共享管理器 (WinShareManager) - 单文件版
    在 Windows 上统一管理 SMB / WebDAV / FTP / SFTP 四种原生共享协议。

    本文件由「build.ps1」自动生成，请勿手工修改。
    修改逻辑请改 ShareManager.Core.ps1，修改界面请改 App.UI.ps1，然后重新构建。

    用法：
      双击 WinShareManager.exe                              打开图形界面
      WinShareManager.exe -Install                          静默安装全部组件
      WinShareManager.exe -Restore                          回滚站点 / 共享 / 防火墙
      WinShareManager.exe -Check                            只做环境体检
      WinShareManager.exe -Task InstallProtocol -TaskArg SFTP   后台任务（界面内部调用）
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Restore,
    [switch]$Check,

    # 后台任务：界面把长耗时操作交给自己的子进程跑，避免 UI 线程被阻塞成「未响应」
    [string]$Task = '',
    [string]$TaskArg = '',
    [string]$TaskArg2 = ''
)

$ErrorActionPreference = 'Continue'

# ============================================================
# 核心逻辑层（ShareManager.Core.ps1）
# ============================================================
'@

$separator = @'


# ============================================================
# 界面层（App.UI.ps1）
# ============================================================
'@

$merged = $preamble + "`r`n" + $core.TrimEnd() + $separator + "`r`n" + $ui.TrimEnd() + "`r`n"

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($outPs1, $merged, $enc)
Write-Step ("已生成 {0}（{1:N0} 字符）" -f (Split-Path $outPs1 -Leaf), $merged.Length)

# ------------------------------------------------------------
# 3. 语法校验
# ------------------------------------------------------------
Write-Step '语法校验 ...'
$errs = $null
$toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($outPs1, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Host ''
    Write-Host ("语法错误 {0} 处：" -f $errs.Count) -ForegroundColor Red
    $errs | Select-Object -First 25 | ForEach-Object {
        Write-Host ("  行 {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red
    }
    throw '合并后的脚本存在语法错误，已中止。'
}
Write-Step '语法校验通过（0 错误）'

# ------------------------------------------------------------
# 4. 生成图标
# ------------------------------------------------------------
function New-RoundRectPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# 在指定尺寸上矢量绘制一次图标，返回 PNG 字节。
# 每个尺寸都单独绘制（而不是把 256 缩下去），小尺寸才够锐利。
function New-IconPng {
    param([int]$Size)

    $s     = $Size / 256.0
    $bmp   = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g     = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # 底板：大圆角方（squircle 感）+ 亮蓝 → 紫罗兰 斜向渐变
    $inset = [Math]::Max(1, [int][Math]::Round(8 * $s))
    $side  = $Size - 2 * $inset
    $rad   = [Math]::Max(2, [int][Math]::Round(62 * $s))
    $rect  = New-Object System.Drawing.Rectangle($inset, $inset, $side, $side)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(64, 142, 255),
        [System.Drawing.Color]::FromArgb(124, 74, 235),
        45)
    $shape = New-RoundRectPath -X $inset -Y $inset -W $side -H $side -R $rad
    $g.FillPath($brush, $shape)

    # 顶部柔光：横向铺满整块底板再向下淡出，并裁到底板内，
    # 这样不会在底板中间留下一条「高光矩形的硬边」。
    $hiRect  = New-Object System.Drawing.Rectangle($inset, $inset, $side, [int][Math]::Max(2, ($side * 0.62)))
    $hiBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $hiRect,
        [System.Drawing.Color]::FromArgb(58, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
        90)
    $g.SetClip($shape)
    $g.FillRectangle($hiBrush, $hiRect)
    $g.ResetClip()

    # 图形：白色文件夹（共享目录）。
    # 相比「三节点连线」，纯色剪影在 16px 下依然成形，且语义更直白。
    function F([double]$v) { return [int][Math]::Round($v * $s) }
    function R2([int]$w, [int]$h) { return [Math]::Max(1, [Math]::Min([int]($s * 12), [int]([Math]::Min($w, $h) / 2))) }

    # 页签（文件夹后片的上沿）
    $tabX = F 48; $tabY = F 64; $tabW = [Math]::Max(2, (F 84)); $tabH = [Math]::Max(2, (F 42))
    $tabP = New-RoundRectPath -X $tabX -Y $tabY -W $tabW -H $tabH -R (R2 $tabW $tabH)

    # 主体（文件夹前片）
    $bdX = F 48; $bdY = F 86; $bdW = [Math]::Max(3, (F 160)); $bdH = [Math]::Max(3, (F 104))
    $bdP = New-RoundRectPath -X $bdX -Y $bdY -W $bdW -H $bdH -R (R2 $bdW $bdH)

    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillPath($white, $tabP)
    $white.Dispose()

    # 前片用极浅的竖向渐变代替纯白：有厚度感，又不会像压一条灰带那样显脏
    $bdRect = New-Object System.Drawing.Rectangle($bdX, $bdY, $bdW, $bdH)
    $bdBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $bdRect,
        [System.Drawing.Color]::White,
        [System.Drawing.Color]::FromArgb(238, 243, 253),
        90)
    $g.FillPath($bdBrush, $bdP)
    $bdBrush.Dispose()

    $tabP.Dispose(); $bdP.Dispose()

    # 极淡的内描边，浅色背景上也有边界感（小尺寸省掉，否则糊成一圈）
    if ($Size -ge 48) {
        $sp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(30, 255, 255, 255), [single][Math]::Max(1, 2 * $s))
        $g.DrawPath($sp, $shape)
        $sp.Dispose()
    }

    $brush.Dispose(); $hiBrush.Dispose(); $shape.Dispose(); $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
    return (, $png)
}

# 把位图编码成 ICO 里的 32bpp DIB 条目（BITMAPINFOHEADER + BGRA + AND 掩码）。
# 为什么不能全用 PNG：PNG 压缩帧只有 256x256 被系统普遍支持，
# 16/32/48 用 PNG 时 GDI+（System.Drawing.Icon）读出来会畸形甚至抛
# “请求的范围扩展超过了数组的结尾”，标题栏和任务栏图标就会花掉。
# 因此 ≤64 的帧一律写成 DIB，只有 256 才用 PNG。
function New-IconDib {
    param([System.Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    # ---- BITMAPINFOHEADER ----
    $bw.Write([UInt32]40)              # biSize
    $bw.Write([Int32]$w)               # biWidth
    $bw.Write([Int32]($h * 2))         # biHeight = XOR + AND
    $bw.Write([UInt16]1)               # biPlanes
    $bw.Write([UInt16]32)              # biBitCount
    $bw.Write([UInt32]0)               # biCompression = BI_RGB
    $bw.Write([UInt32]($w * $h * 4))   # biSizeImage
    $bw.Write([Int32]0); $bw.Write([Int32]0)
    $bw.Write([UInt32]0); $bw.Write([UInt32]0)

    # ---- XOR 位图：BGRA，自下而上 ----
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $rowBytes = $data.Stride
        $buf = New-Object byte[] ($rowBytes * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
        for ($y = $h - 1; $y -ge 0; $y--) {
            $bw.Write($buf, $y * $rowBytes, $w * 4)
        }
    } finally {
        $Bitmap.UnlockBits($data)
    }

    # ---- AND 掩码：1bpp，按 4 字节对齐，全 0 表示「全部不透明」（实际透明由 alpha 决定）----
    $maskRow = [int][Math]::Floor(($w + 31) / 32) * 4
    $zero = New-Object byte[] $maskRow
    for ($y = 0; $y -lt $h; $y++) { $bw.Write($zero, 0, $maskRow) }

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Close(); $ms.Dispose()
    return (, $bytes)
}

if ((Test-Path -LiteralPath $icoPath) -and (-not $ForceIcon)) {
    Write-Step '图标已存在，跳过生成（要重画加 -ForceIcon）'
} else {
    Write-Step '生成图标 ...'
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')

    # 多尺寸条目：任务栏 / 列表视图取 32、16，资源管理器大图标取 256
    $sizes   = @(16, 32, 48, 64, 256)
    $entries = New-Object System.Collections.ArrayList
    foreach ($sz in $sizes) {
        $png = New-IconPng -Size $sz
        if ($sz -ge 256) {
            $data = $png                       # 256 用 PNG 压缩，体积小且系统支持
        } else {
            $msPng = New-Object System.IO.MemoryStream(, $png)
            $bmp32 = New-Object System.Drawing.Bitmap($msPng)
            $data = New-IconDib -Bitmap $bmp32
            $bmp32.Dispose(); $msPng.Dispose()
        }
        [void]$entries.Add([pscustomobject]@{ Size = $sz; Data = $data })
    }

    $icoEntries = $entries | Sort-Object -Property Size -Descending

    $fs = [System.IO.File]::Create($icoPath)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0)                       # reserved
    $bw.Write([UInt16]1)                       # type = icon
    $bw.Write([UInt16]$icoEntries.Count)       # count

    $offset = 6 + 16 * $icoEntries.Count
    foreach ($en in $icoEntries) {
        $bw.Write([Byte]($(if ($en.Size -ge 256) { 0 } else { $en.Size })))   # width
        $bw.Write([Byte]($(if ($en.Size -ge 256) { 0 } else { $en.Size })))   # height
        $bw.Write([Byte]0)                     # color count
        $bw.Write([Byte]0)                     # reserved
        $bw.Write([UInt16]1)                   # planes
        $bw.Write([UInt16]32)                  # bit count
        $bw.Write([UInt32]$en.Data.Length)     # bytes in resource
        $bw.Write([UInt32]$offset)             # offset
        $offset += $en.Data.Length
    }
    foreach ($en in $icoEntries) { $bw.Write($en.Data) }

    $bw.Flush()
    $bw.Close()
    Write-Step ("图标已生成（{0} 尺寸 / {1:N0} 字节）" -f $icoEntries.Count, (Get-Item $icoPath).Length)
}

# ------------------------------------------------------------
# 4.5 把图标以 base64 注入脚本（窗体 Icon 用，保证 exe 单文件自足）
# ------------------------------------------------------------
# 只把图标编进 exe 资源是不够的：WinForms 窗体不会自动读取 exe 资源，
# 不显式赋值 $form.Icon 就会退回通用默认图标，标题栏和任务栏都跟着错。
if (Test-Path -LiteralPath $icoPath) {
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($icoPath))
    $text = [System.IO.File]::ReadAllText($outPs1, [System.Text.Encoding]::UTF8)
    if ($text.Contains('@@ICON_B64@@')) {
        $text = $text.Replace('@@ICON_B64@@', $b64)
        [System.IO.File]::WriteAllText($outPs1, $text, $enc)
        Write-Step ("图标已注入脚本（base64 {0:N0} 字符）" -f $b64.Length)
    } else {
        Write-Step '未找到图标占位符 @@ICON_B64@@，跳过注入'
    }
} else {
    Write-Step '没有 app.ico，窗体将退回 exe 关联图标'
}

# ------------------------------------------------------------
# 5. 编译单文件 exe
# ------------------------------------------------------------
if ($SkipExe) {
    Write-Host ''
    Write-Host '已跳过 exe 编译（-SkipExe）。' -ForegroundColor Yellow
    exit 0
}

Write-Step '载入 ps2exe ...'
$ps2 = Get-Module -ListAvailable -Name ps2exe | Sort-Object Version -Descending | Select-Object -First 1
if (-not $ps2) {
    throw '未找到 ps2exe 模块。请先执行：Install-Module ps2exe -Scope CurrentUser -Force'
}
Import-Module ps2exe -ErrorAction Stop
Write-Step ("ps2exe v{0}" -f $ps2.Version)

if ((Test-Path -LiteralPath $outExe) -and (-not $KeepOld)) {
    $bak = Join-Path $env:TEMP ("WinShareManager_{0}.exe.bak" -f (Get-Date -Format 'HHmmss'))
    Move-Item -LiteralPath $outExe -Destination $bak -Force
    Write-Step ("旧 exe 已备份到 {0}" -f $bak)
}

Write-Step '编译中（约 10-30 秒）...'
# ps2exe 编译结束后会清理临时清单文件，某些环境下该系统调用会被安全软件拦截并抛错。
# 只要 exe 已产出，就视为成功。
$compileError = $null
try {
    Invoke-ps2exe `
        -inputFile     $outPs1 `
        -outputFile    $outExe `
        -iconFile      $icoPath `
        -title         '共享管理器' `
        -description   '在 Windows 上统一管理 SMB / WebDAV / FTP / SFTP 原生共享协议' `
        -product       'WinShareManager' `
        -company       'qianwei' `
        -copyright     '(c) qianwei' `
        -version       $asmVersion `
        -requireAdmin `
        -noConsole `
        -STA `
        -UNICODEEncoding `
        -supportOS `
        -x64 `
        -noOutput
} catch {
    $compileError = $_.Exception.Message
}

if (-not (Test-Path -LiteralPath $outExe)) {
    if ($compileError) { throw "编译失败：$compileError" }
    throw '编译未产出 exe。'
}
if ($compileError) {
    Write-Step ("已忽略编译器清理阶段的告警：" + ($compileError -split "`r?`n")[0])
}

Write-Host ''
Write-Host '=== 构建完成 ===' -ForegroundColor Green
Write-Host ("  exe  : {0}  ({1:N0} 字节)" -f $outExe, (Get-Item $outExe).Length) -ForegroundColor Green
Write-Host ("  ps1  : {0}" -f $outPs1) -ForegroundColor Green
Write-Host ''
