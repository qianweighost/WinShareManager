#requires -Version 5.1
<#
    ShareManager.Core.ps1 - WinShareManager 的核心逻辑层
    不包含任何界面代码，可被 GUI 或命令行直接 dot-source 使用。

    设计要点：
      四种协议共用 Windows 本地账户 + NTFS ACL
        SMB   -> 系统原生共享（New-SmbShare）
        WebDAV-> IIS WebDAV 发布（站点 + 虚拟目录 + 创作规则）
        FTP   -> IIS FTP 服务（站点 + 虚拟目录）
        SFTP  -> OpenSSH Server（按绝对路径访问，权限同由 NTFS 决定）
#>

$ErrorActionPreference = 'Continue'

# ============================================================
# 常量
# ============================================================
$script:AppName    = 'WinShareManager'

# ---- 版本与仓库信息（唯一事实来源）----
# 界面标题、状态栏、exe 文件版本、关于信息全部读这里。
# 构建脚本从本文件解析 $script:AppVersion，同步给 ps2exe 的 -version，
# 所以发版只需要改这一行。
$script:AppVersion  = '2.0.1'
$script:AppRepoName = 'qianweighost/WinShareManager'
$script:AppRepoUrl  = 'https://github.com/qianweighost/WinShareManager'
$script:AppReleaseUrl = "$($script:AppRepoUrl)/releases/latest"

$script:ConfigDir  = Join-Path $env:ProgramData 'WinShareManager'
$script:ConfigFile = Join-Path $script:ConfigDir 'config.json'
$script:LogFile    = Join-Path $script:ConfigDir 'ops.log'
$script:AppCmd     = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
$script:LogBox     = $null
$script:PermHiddenCount = 0

$script:IisFeatures = @(
    'IIS-WebServerRole',
    'IIS-WebServer',
    'IIS-CommonHttpFeatures',
    'IIS-StaticContent',
    'IIS-DefaultDocument',
    'IIS-HttpErrors',
    'IIS-DirectoryBrowsing',
    'IIS-WebDAV',
    'IIS-FTPServer',
    'IIS-FTPSvc',
    'IIS-FTPExtensibility',
    'IIS-ManagementConsole',
    'IIS-RequestFiltering'
)

# ============================================================
# 通用
# ============================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Store {
    if (-not (Test-Path $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    }
}

function Write-Op {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp][$Level] $Message"

    Initialize-Store
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }

    if ($null -ne $script:LogBox) {
        $prefix = switch ($Level) {
            'OK'   { '[成功] ' }
            'WARN' { '[注意] ' }
            'ERR'  { '[错误] ' }
            default { '[信息] ' }
        }
        try {
            $script:LogBox.AppendText("$prefix$Message`r`n")
            $script:LogBox.SelectionStart = $script:LogBox.TextLength
            $script:LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        } catch { }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    if (-not (Test-Path $FilePath)) {
        return [pscustomobject]@{ ExitCode = -1; Output = "程序不存在: $FilePath" }
    }
    try {
        $out = & $FilePath @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        return [pscustomobject]@{ ExitCode = $code; Output = $out.Trim() }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    }
}

# ============================================================
# 配置
# ============================================================
function Get-Config {
    Initialize-Store
    if (Test-Path $script:ConfigFile) {
        try {
            $raw = Get-Content -Path $script:ConfigFile -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) { return ($raw | ConvertFrom-Json) }
        } catch {
            Write-Op "配置文件解析失败，回退默认配置：$($_.Exception.Message)" 'WARN'
        }
    }
    return [pscustomobject]@{
        RootBase   = 'D:\Share'
        WebDavPort = 8081
        FtpPort    = 21
        WebDavSite = 'WSS-WebDAV'
        FtpSite    = 'WSS-FTP'
        Shares     = @()
    }
}

function Save-Config {
    param([Parameter(Mandatory = $true)]$Config)
    Initialize-Store
    try {
        $Config | ConvertTo-Json -Depth 8 | Set-Content -Path $script:ConfigFile -Encoding UTF8 -Force
        return $true
    } catch {
        Write-Op "保存配置失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}

function Get-ShareList {
    $cfg = Get-Config
    if ($null -eq $cfg.Shares) { return @() }
    return @($cfg.Shares)
}

# ============================================================
# 环境安装 / 回滚
# ============================================================
function Install-Environment {
    if (-not (Test-Admin)) {
        Write-Op '需要以管理员身份运行。' 'ERR'
        return $false
    }

    Write-Op '开始启用 Windows 组件（IIS + WebDAV + FTP + OpenSSH），约需 2-5 分钟...' 'INFO'

    foreach ($feat in $script:IisFeatures) {
        try {
            $state = (Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop).State
            if ($state -eq 'Enabled') {
                Write-Op "组件 $feat 已启用，跳过。" 'OK'
                continue
            }
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart -ErrorAction Stop
            if ($r.RestartNeeded) {
                Write-Op "组件 $feat 已启用（需重启系统才完全生效）。" 'WARN'
            } else {
                Write-Op "组件 $feat 已启用。" 'OK'
            }
        } catch {
            Write-Op "组件 $feat 启用失败：$($_.Exception.Message)" 'WARN'
        }
    }

    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop |
               Select-Object -First 1
        if ($cap -and $cap.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            Write-Op 'OpenSSH Server 已安装（SFTP 可用）。' 'OK'
        } else {
            Write-Op 'OpenSSH Server 已安装，跳过。' 'OK'
        }
        Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name sshd -ErrorAction SilentlyContinue
        Write-Op 'sshd 服务已设为自动启动并启动。' 'OK'
    } catch {
        Write-Op "OpenSSH Server 安装失败：$($_.Exception.Message)" 'ERR'
    }

    $cfg = Get-Config
    $rules = @(
        @{ Name = 'WinShareManager-FTP';    Port = $cfg.FtpPort },
        @{ Name = 'WinShareManager-WebDAV'; Port = $cfg.WebDavPort },
        @{ Name = 'WinShareManager-SFTP';   Port = 22 }
    )
    foreach ($rule in $rules) {
        try {
            $exist = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
            if (-not $exist) {
                New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound `
                    -Action Allow -Protocol TCP -LocalPort $rule.Port -ErrorAction Stop | Out-Null
                Write-Op "防火墙已放行 TCP $($rule.Port)（$($rule.Name)）。" 'OK'
            } else {
                Write-Op "防火墙规则 $($rule.Name) 已存在，跳过。" 'OK'
            }
        } catch {
            Write-Op "防火墙规则 $($rule.Name) 建立失败：$($_.Exception.Message)" 'WARN'
        }
    }

    if (-not (Test-Path $cfg.RootBase)) {
        try {
            New-Item -ItemType Directory -Path $cfg.RootBase -Force | Out-Null
            Write-Op "已创建共享根目录 $($cfg.RootBase)。" 'OK'
        } catch {
            Write-Op "创建共享根目录失败：$($_.Exception.Message)" 'ERR'
        }
    }

    Write-Op '环境安装流程结束。' 'OK'
    return $true
}

function Remove-Environment {
    if (-not (Test-Admin)) {
        Write-Op '需要以管理员身份运行。' 'ERR'
        return $false
    }

    $cfg = Get-Config

    foreach ($s in (Get-ShareList)) {
        try { Remove-ShareEntry -Name $s.Name | Out-Null } catch { }
    }

    if (Initialize-IisModule) {
        foreach ($siteName in @($cfg.WebDavSite, $cfg.FtpSite)) {
            try {
                if (Get-Website -Name $siteName -ErrorAction SilentlyContinue) {
                    Remove-Website -Name $siteName -ErrorAction Stop
                    Write-Op "已删除 IIS 站点 $siteName。" 'OK'
                }
            } catch {
                Write-Op "删除站点 $siteName 失败：$($_.Exception.Message)" 'WARN'
            }
        }
    }

    foreach ($ruleName in @('WinShareManager-FTP', 'WinShareManager-WebDAV', 'WinShareManager-SFTP')) {
        try {
            $r = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            if ($r) {
                Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
                Write-Op "已删除防火墙规则 $ruleName。" 'OK'
            }
        } catch { }
    }

    Write-Op '回滚完成（IIS / OpenSSH 组件本身保留，如需卸载请到 Windows 功能里手动关闭）。' 'WARN'
    return $true
}

# ============================================================
# IIS
# ============================================================
function Initialize-IisModule {
    if (-not (Test-Path $script:AppCmd)) { return $false }
    try {
        Import-Module WebAdministration -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Set-AppCmdConfig {
    param([string]$Site, [string]$Section, [string]$Value)
    $argList = @('set', 'config', $Site, "/section:$Section", $Value, '/commit:apphost')
    return (Invoke-Native -FilePath $script:AppCmd -Arguments $argList)
}

function Ensure-WebDavSite {
    $cfg = Get-Config
    if (-not (Initialize-IisModule)) {
        Write-Op 'IIS 管理模块不可用，请先执行「一键安装所需组件」。' 'ERR'
        return $false
    }

    $siteName = $cfg.WebDavSite
    $root     = $cfg.RootBase
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }

    $existing = Get-Website -Name $siteName -ErrorAction SilentlyContinue
    if (-not $existing) {
        try {
            New-Website -Name $siteName -Port $cfg.WebDavPort -PhysicalPath $root -Force | Out-Null
            Write-Op "WebDAV 站点 $siteName 已创建（端口 $($cfg.WebDavPort)）。" 'OK'
        } catch {
            Write-Op "创建 WebDAV 站点失败：$($_.Exception.Message)" 'ERR'
            return $false
        }
    }

    [void](Set-AppCmdConfig -Site $siteName -Section 'system.webServer/webdav/authoring' -Value '/enabled:true')
    [void](Set-AppCmdConfig -Site $siteName -Section 'system.webServer/webdav/authoringRules' -Value "/+[users='*',path='*',access='Read,Write']")
    [void](Set-AppCmdConfig -Site $siteName -Section 'system.webServer/security/authentication/basicAuthentication' -Value '/enabled:true')
    [void](Set-AppCmdConfig -Site $siteName -Section 'system.webServer/security/authentication/anonymousAuthentication' -Value '/enabled:false')
    [void](Set-AppCmdConfig -Site $siteName -Section 'system.webServer/security/requestFiltering' -Value '/requestLimits.maxAllowedContentLength:4294967295')

    try {
        $wc = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
        if (Test-Path $wc) {
            Set-ItemProperty -Path $wc -Name BasicAuthLevel -Value 2 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $wc -Name FileSizeLimitInBytes -Value 4294967295 -ErrorAction SilentlyContinue
        }
    } catch { }

    return $true
}

function Ensure-FtpSite {
    $cfg = Get-Config
    if (-not (Initialize-IisModule)) {
        Write-Op 'IIS 管理模块不可用，请先执行「一键安装所需组件」。' 'ERR'
        return $false
    }

    $siteName = $cfg.FtpSite
    $root     = $cfg.RootBase
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }

    $existing = Get-Website -Name $siteName -ErrorAction SilentlyContinue
    if (-not $existing) {
        try {
            New-WebFtpSite -Name $siteName -Port $cfg.FtpPort -PhysicalPath $root -Force | Out-Null
            Write-Op "FTP 站点 $siteName 已创建（端口 $($cfg.FtpPort)）。" 'OK'
        } catch {
            Write-Op "创建 FTP 站点失败：$($_.Exception.Message)" 'ERR'
            return $false
        }
    }

    [void](Set-AppCmdConfig -Site $siteName -Section 'system.ftpServer/security/authentication/basicAuthentication' -Value '/enabled:true')
    [void](Set-AppCmdConfig -Site $siteName -Section 'system.ftpServer/security/authentication/anonymousAuthentication' -Value '/enabled:false')
    [void](Set-AppCmdConfig -Site $siteName -Section 'system.ftpServer/security/authorization' -Value "/+[accessType='Allow',users='*',permissions='Read,Write']")

    return $true
}

function Restart-IisSites {
    try {
        Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
        $ftp = Get-Service FTPSVC -ErrorAction SilentlyContinue
        if ($ftp -and $ftp.Status -ne 'Running') { Start-Service FTPSVC -ErrorAction SilentlyContinue }
        Write-Op 'IIS 服务已重启，配置生效。' 'OK'
    } catch {
        Write-Op "重启 IIS 失败：$($_.Exception.Message)" 'WARN'
    }
}

# ============================================================
# 共享
# ============================================================
function New-ShareEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Protocols = @('SMB'),
        [string]$Note = ''
    )

    if (-not $Name -or $Name.Trim() -eq '') {
        Write-Op '共享名不能为空。' 'ERR'; return $false
    }
    if ($Name -match '[\\/:*?"<>|]') {
        Write-Op '共享名中包含非法字符。' 'ERR'; return $false
    }
    if (-not (Test-Path $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Op "目标目录不存在，已自动创建：$Path" 'OK'
        } catch {
            Write-Op "目标目录创建失败：$Path" 'ERR'; return $false
        }
    }

    $ok = $true

    if ($Protocols -contains 'SMB') {
        $exist = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
        if ($exist) {
            Write-Op "SMB 共享 $Name 已存在，跳过创建。" 'WARN'
        } else {
            try {
                New-SmbShare -Name $Name -Path $Path -FullAccess 'Administrators' -ChangeAccess 'Users' -ErrorAction Stop | Out-Null
                Write-Op "SMB 共享已发布：\\$env:COMPUTERNAME\$Name -> $Path" 'OK'
            } catch {
                Write-Op "SMB 共享创建失败：$($_.Exception.Message)" 'ERR'
                $ok = $false
            }
        }
    }

    if ($Protocols -contains 'WebDAV') {
        $cfg = Get-Config
        if (Ensure-WebDavSite) {
            try {
                $vd = Get-WebVirtualDirectory -Site $cfg.WebDavSite -Name $Name -ErrorAction SilentlyContinue
                if (-not $vd) {
                    New-WebVirtualDirectory -Site $cfg.WebDavSite -Name $Name -PhysicalPath $Path -ErrorAction Stop | Out-Null
                    Write-Op "WebDAV 目录已映射：http://$env:COMPUTERNAME`:$($cfg.WebDavPort)/$Name" 'OK'
                } else {
                    Write-Op "WebDAV 目录 $Name 已存在，跳过。" 'WARN'
                }
            } catch {
                Write-Op "WebDAV 目录创建失败：$($_.Exception.Message)" 'ERR'
                $ok = $false
            }
        } else { $ok = $false }
    }

    if ($Protocols -contains 'FTP') {
        $cfg = Get-Config
        if (Ensure-FtpSite) {
            try {
                $vd = Get-WebVirtualDirectory -Site $cfg.FtpSite -Name $Name -ErrorAction SilentlyContinue
                if (-not $vd) {
                    New-WebVirtualDirectory -Site $cfg.FtpSite -Name $Name -PhysicalPath $Path -ErrorAction Stop | Out-Null
                    Write-Op "FTP 目录已映射：ftp://$env:COMPUTERNAME`:$($cfg.FtpPort)/$Name" 'OK'
                } else {
                    Write-Op "FTP 目录 $Name 已存在，跳过。" 'WARN'
                }
            } catch {
                Write-Op "FTP 目录创建失败：$($_.Exception.Message)" 'ERR'
                $ok = $false
            }
        } else { $ok = $false }
    }

    if ($Protocols -contains 'SFTP') {
        Write-Op "SFTP 无需单独发布：登录后用绝对路径 $Path 访问，权限由 NTFS 决定。" 'INFO'
        $sshd = Get-Service sshd -ErrorAction SilentlyContinue
        if (-not $sshd) {
            Write-Op 'sshd 服务未安装，SFTP 暂不可用。' 'WARN'
        } elseif ($sshd.Status -ne 'Running') {
            Start-Service sshd -ErrorAction SilentlyContinue
        }
    }

    $cfg  = Get-Config
    $list = @(Get-ShareList | Where-Object { $_.Name -ne $Name })
    $list += [pscustomobject]@{
        Name      = $Name
        Path      = $Path
        Protocols = @($Protocols)
        Note      = $Note
    }
    $cfg.Shares = $list
    Save-Config -Config $cfg | Out-Null

    if (($Protocols -contains 'WebDAV') -or ($Protocols -contains 'FTP')) { Restart-IisSites }
    return $ok
}

function Remove-ShareEntry {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        $s = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
        if ($s) {
            Remove-SmbShare -Name $Name -Force -ErrorAction Stop
            Write-Op "已删除 SMB 共享 $Name。" 'OK'
        }
    } catch {
        Write-Op "删除 SMB 共享失败：$($_.Exception.Message)" 'WARN'
    }

    $cfg = Get-Config
    if (Initialize-IisModule) {
        foreach ($siteName in @($cfg.WebDavSite, $cfg.FtpSite)) {
            try {
                $vd = Get-WebVirtualDirectory -Site $siteName -Name $Name -ErrorAction SilentlyContinue
                if ($vd) {
                    Remove-WebVirtualDirectory -Site $siteName -Name $Name -ErrorAction Stop
                    Write-Op "已删除 $siteName 下的目录 $Name。" 'OK'
                }
            } catch { }
        }
    }

    $cfg = Get-Config
    $cfg.Shares = @(Get-ShareList | Where-Object { $_.Name -ne $Name })
    Save-Config -Config $cfg | Out-Null

    Restart-IisSites
    return $true
}

# 只摘掉某个共享名下的一个协议，其余协议继续对外提供服务。
# 最后一个协议被摘掉时，整条共享记录一并从配置里移除（物理目录不动）。
function Remove-ShareProtocol {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Protocol
    )

    $cfg   = Get-Config
    $entry = @(Get-ShareList) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $entry) {
        Write-Op "共享 $Name 不存在。" 'ERR'; return $false
    }

    $protos = @($entry.Protocols)
    if ($protos -notcontains $Protocol) {
        Write-Op "共享 $Name 下没有 $Protocol 协议，无需删除。" 'WARN'; return $false
    }

    switch ($Protocol) {
        'SMB' {
            try {
                $s = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
                if ($s) {
                    Remove-SmbShare -Name $Name -Force -ErrorAction Stop
                    Write-Op "已撤下 SMB 共享 \\$env:COMPUTERNAME\$Name。" 'OK'
                } else {
                    Write-Op "SMB 共享 $Name 本就不存在，仅清理登记。" 'WARN'
                }
            } catch {
                Write-Op "删除 SMB 共享失败：$($_.Exception.Message)" 'ERR'
                return $false
            }
        }
        'WebDAV' {
            if (-not (Initialize-IisModule)) { Write-Op 'IIS 管理模块不可用。' 'ERR'; return $false }
            try {
                $vd = Get-WebVirtualDirectory -Site $cfg.WebDavSite -Name $Name -ErrorAction SilentlyContinue
                if ($vd) {
                    Remove-WebVirtualDirectory -Site $cfg.WebDavSite -Name $Name -ErrorAction Stop
                    Write-Op "已撤下 WebDAV 目录 $Name。" 'OK'
                }
            } catch {
                Write-Op "删除 WebDAV 目录失败：$($_.Exception.Message)" 'ERR'
                return $false
            }
        }
        'FTP' {
            if (-not (Initialize-IisModule)) { Write-Op 'IIS 管理模块不可用。' 'ERR'; return $false }
            try {
                $vd = Get-WebVirtualDirectory -Site $cfg.FtpSite -Name $Name -ErrorAction SilentlyContinue
                if ($vd) {
                    Remove-WebVirtualDirectory -Site $cfg.FtpSite -Name $Name -ErrorAction Stop
                    Write-Op "已撤下 FTP 目录 $Name。" 'OK'
                }
            } catch {
                Write-Op "删除 FTP 目录失败：$($_.Exception.Message)" 'ERR'
                return $false
            }
        }
        'SFTP' {
            Write-Op 'SFTP 走绝对路径，没有独立映射，这里只取消登记（目录与 NTFS 权限保持不变）。' 'INFO'
        }
    }

    $rest = @($protos | Where-Object { $_ -ne $Protocol })
    $list = @(Get-ShareList | Where-Object { $_.Name -ne $Name })
    if ($rest.Count -gt 0) {
        $list += [pscustomobject]@{
            Name      = $entry.Name
            Path      = $entry.Path
            Protocols = $rest
            Note      = $entry.Note
        }
    }

    $cfg.Shares = $list
    Save-Config -Config $cfg | Out-Null

    if (($Protocol -eq 'WebDAV') -or ($Protocol -eq 'FTP')) { Restart-IisSites }

    if ($rest.Count -eq 0) {
        Write-Op "共享 $Name 已没有任何协议，整条记录已移除（磁盘目录保留）。" 'OK'
    } else {
        Write-Op "共享 $Name 还剩 $($rest -join ' / ') 协议。" 'OK'
    }
    return $true
}

function Save-Settings {    param(
        [string]$RootBase,
        [int]$WebDavPort = 8081,
        [int]$FtpPort = 21
    )

    if (-not $RootBase -or $RootBase.Trim() -eq '') {
        Write-Op '共享根目录不能为空。' 'ERR'; return $false
    }
    if ($WebDavPort -lt 1 -or $WebDavPort -gt 65535) {
        Write-Op 'WebDAV 端口超出范围（1-65535）。' 'ERR'; return $false
    }
    if ($FtpPort -lt 1 -or $FtpPort -gt 65535) {
        Write-Op 'FTP 端口超出范围（1-65535）。' 'ERR'; return $false
    }
    if ($WebDavPort -eq $FtpPort) {
        Write-Op 'WebDAV 与 FTP 不能使用同一端口。' 'ERR'; return $false
    }

    if (-not (Test-Path $RootBase)) {
        try {
            New-Item -ItemType Directory -Path $RootBase -Force | Out-Null
            Write-Op "共享根目录已创建：$RootBase" 'OK'
        } catch {
            Write-Op "共享根目录创建失败：$($_.Exception.Message)" 'ERR'; return $false
        }
    }

    $cfg = Get-Config
    $cfg.RootBase   = $RootBase
    $cfg.WebDavPort = $WebDavPort
    $cfg.FtpPort    = $FtpPort
    Save-Config -Config $cfg | Out-Null
    Write-Op "设置已保存：根目录=$RootBase / WebDAV=$WebDavPort / FTP=$FtpPort" 'OK'
    return $true
}

function Rebuild-Sites {
    $cfg = Get-Config
    if (-not (Initialize-IisModule)) {
        Write-Op 'IIS 管理模块不可用，请先安装组件。' 'ERR'; return $false
    }

    foreach ($siteName in @($cfg.WebDavSite, $cfg.FtpSite)) {
        try {
            $s = Get-Website -Name $siteName -ErrorAction SilentlyContinue
            if ($s) {
                Remove-Website -Name $siteName -ErrorAction Stop
                Write-Op "已移除旧站点 $siteName。" 'OK'
            }
        } catch {
            Write-Op "移除站点 $siteName 失败：$($_.Exception.Message)" 'WARN'
        }
    }

    foreach ($item in (Get-ShareList)) {
        $protos = @()
        if ($item.Protocols) { $protos = @($item.Protocols) }
        if (($protos -contains 'WebDAV') -or ($protos -contains 'FTP')) {
            New-ShareEntry -Name $item.Name -Path $item.Path -Protocols $protos -Note $item.Note | Out-Null
        }
    }

    Restart-IisSites
    Write-Op '站点已按当前配置重建完成。' 'OK'
    return $true
}

# ============================================================
# 用户
# ============================================================
function Get-UserList {
    try { return Get-LocalUser | Sort-Object Name } catch { return @() }
}

function New-SrvUser {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Description = 'WinShareManager 共享账户'
    )
    if ($Name -match '[\\/:*?"<>|@]') {
        Write-Op '用户名中包含非法字符。' 'ERR'; return $false
    }
    if (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) {
        Write-Op "用户 $Name 已存在。" 'ERR'; return $false
    }
    try {
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $Name -Password $sec -Description $Description `
            -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
        try { Add-LocalGroupMember -Group 'Users' -Member $Name -ErrorAction Stop } catch { }
        Write-Op "用户 $Name 已创建并加入 Users 组。" 'OK'
        return $true
    } catch {
        Write-Op "创建用户失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}

function Set-SrvUserPassword {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password
    )
    try {
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        Set-LocalUser -Name $Name -Password $sec -ErrorAction Stop
        Write-Op "用户 $Name 的密码已更新。" 'OK'
        return $true
    } catch {
        Write-Op "修改密码失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}

function Set-SrvUserEnabled {
    param([Parameter(Mandatory = $true)][string]$Name, [bool]$Enabled)
    try {
        if ($Enabled) { Enable-LocalUser  -Name $Name -ErrorAction Stop }
        else          { Disable-LocalUser -Name $Name -ErrorAction Stop }
        $word = if ($Enabled) { '启用' } else { '禁用' }
        Write-Op "用户 $Name 已$word。" 'OK'
        return $true
    } catch {
        Write-Op "切换用户状态失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}

function Remove-SrvUser {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -in @('Administrator', 'DefaultAccount', 'Guest', 'WDAGUtilityAccount')) {
        Write-Op "禁止删除系统账户 $Name。" 'ERR'; return $false
    }
    try {
        Remove-LocalUser -Name $Name -ErrorAction Stop
        Write-Op "用户 $Name 已删除。" 'OK'
        return $true
    } catch {
        Write-Op "删除用户失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}

# ============================================================
# 权限（NTFS ACL）
# ============================================================
function Set-PathPermission {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$User,
        [ValidateSet('Read', 'Write', 'Full', 'Remove')][string]$Level = 'Read'
    )

    if (-not (Test-Path $Path)) {
        Write-Op "路径不存在：$Path" 'ERR'; return $false
    }

    $icacls = Join-Path $env:windir 'System32\icacls.exe'

    if ($Level -eq 'Remove') {
        $r = Invoke-Native -FilePath $icacls -Arguments @($Path, '/remove:g', $User)
        if ($r.ExitCode -eq 0) {
            Write-Op "已撤销 $User 对 $Path 的授权。" 'OK'
            return $true
        }
        Write-Op "撤销失败：$($r.Output)" 'ERR'
        return $false
    }

    $acl = '(OI)(CI)RX'
    if ($Level -eq 'Write') { $acl = '(OI)(CI)M' }
    if ($Level -eq 'Full')  { $acl = '(OI)(CI)F' }

    $r = Invoke-Native -FilePath $icacls -Arguments @($Path, '/grant', "$($User):$acl")
    if ($r.ExitCode -eq 0) {
        Write-Op "已授权 $User 对 $Path 的 $Level 权限。" 'OK'
        return $true
    }
    Write-Op "授权失败：$($r.Output)" 'ERR'
    return $false
}

# 把 ACL 里的英文枚举翻成人话。
# 直接显示 "DREAME-010443\Administrator  FullControl, Synchronize" 谁看都发懵。
function Get-FsRightLevel {
    param([string]$Rights)

    # ACL 里有时直接给枚举的数值（含继承标志位），先还原成名字再判断
    if ($Rights -match '^-?\d+$') {
        try { $Rights = [string]([System.Security.AccessControl.FileSystemRights][int64]$Rights) } catch { }
    }

    $tokens = @($Rights -split ',' | ForEach-Object { $_.Trim() })

    if ($tokens -contains 'FullControl')    { return '完全控制' }
    if ($tokens -contains 'Modify')         { return '修改' }
    if ($tokens -contains 'ReadAndExecute') { return '读取和执行' }
    if ($tokens -contains 'Read')           { return '读取' }
    if ($tokens -contains 'Write')          { return '写入' }

    # 逐项授权的 ACE（Windows 会把细粒度权限拆成 ReadData / WriteData / ExecuteFile …）
    # 按「有没有读 / 有没有写」拼成最接近的中文说法，避免整张表全是「特殊权限」
    $writeBits  = @('WriteData', 'CreateFiles', 'AppendData', 'CreateDirectories',
                    'WriteAttributes', 'WriteExtendedAttributes',
                    'Delete', 'DeleteSubdirectoriesAndFiles',
                    'ChangePermissions', 'TakeOwnership')
    $readBits   = @('ReadData', 'ListDirectory', 'ReadAttributes', 'ReadExtendedAttributes',
                    'ReadPermissions', 'ExecuteFile', 'Traverse', 'Synchronize')

    $hasWrite = @($tokens | Where-Object { $writeBits -contains $_ }).Count -gt 0
    $hasRead  = @($tokens | Where-Object { $readBits  -contains $_ }).Count -gt 0

    if ($hasWrite -and $hasRead) { return '修改' }
    if ($hasWrite)               { return '写入' }
    if ($hasRead)                { return '读取' }
    return '特殊权限'
}

function Get-FsAccountName {
    param([string]$Identity)
    $map = @{
        'Everyone'                         = '所有人'
        'Users'                            = '本机用户组'
        'Authenticated Users'              = '已认证用户'
        'NETWORK'                          = '网络登录用户'
        'INTERACTIVE'                      = '本机交互登录'
        'Administrators'                   = '管理员组'
        'SYSTEM'                           = '系统'
        'CREATOR OWNER'                    = '创建者'
        'Guests'                           = '来宾组'
        'Guest'                            = 'Guest'
        'LOCAL SERVICE'                    = '本地服务'
        'NETWORK SERVICE'                  = '网络服务'
        'TrustedInstaller'                 = 'TrustedInstaller'
        'ALL APPLICATION PACKAGES'          = '所有应用包'
        'ALL RESTRICTED APPLICATION PACKAGES' = '受限制应用包'
    }

    # 去掉 计算机名\ 前缀，只留下账户名
    $short = $Identity
    if ($short -match '^[^\\]+\\+(.+)$') { $short = $Matches[1] }

    if ($map.ContainsKey($short)) { return $map[$short] }
    return $short
}

function Get-PathPermission {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $acl = Get-Acl -Path $Path -ErrorAction Stop
    } catch {
        return @()
    }

    # 这几类纯粹是系统噪声，列出来只会干扰判断
    $skip = @('SYSTEM', 'Administrators', 'TrustedInstaller', 'CREATOR OWNER')

    $rows = @()
    $script:PermHiddenCount = 0

    foreach ($a in $acl.Access) {
        # 「仅继承」的条目（PropagationFlags 含 InheritOnly）只作用于子目录，
        # 对这一层目录本身不生效，列出来只会和上一条重复且显示成一串数字。
        $prop = 0
        try { $prop = [int]$a.PropagationFlags } catch { }
        if (($prop -band 2) -ne 0) { $script:PermHiddenCount++; continue }

        $id    = [string]$a.IdentityReference
        $short = $id
        if ($short -match '^[^\\]+\\+(.+)$') { $short = $Matches[1] }

        if ($skip -contains $short) { $script:PermHiddenCount++; continue }

        $friendly = Get-FsAccountName -Identity $id
        $account  = $friendly
        if ($friendly -ne $short) { $account = "$friendly（$short）" }

        $rows += [pscustomobject]@{
            Account   = $account
            Short     = $short
            Level     = Get-FsRightLevel -Rights ([string]$a.FileSystemRights)
            Type      = $(if ([string]$a.AccessControlType -eq 'Deny') { '拒绝' } else { '允许' })
            Source    = $(if ($a.IsInherited) { '继承自上级' } else { '在此目录设置' })
            Inherited = [bool]$a.IsInherited
            Raw       = [string]$a.FileSystemRights
        }
    }

    # 显式设置的排前面，其次按账户名
    return @($rows | Sort-Object @{ Expression = { $_.Inherited } }, @{ Expression = { $_.Short } })
}

# ============================================================
# 协议级控制（每个协议独立：安装 / 启动 / 停止）
# ============================================================
# 共享数量：直接读 LanmanServer 的注册表键（毫秒级）。
# Get-SmbShare 首次调用要加载整个 CIM/SMB 模块，实测 5~7 秒，
# 放在启动路径上就是明显的「点了没反应」。
function Get-SmbShareCountFast {
    # 用 .NET 的注册表 API 而不是 Get-ItemProperty + 管道：
    # 后者实测要多花 900 ms 左右（PowerShell 管道 + PSObject 属性枚举的开销），
    # 直接读值名列表是毫秒级。
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SYSTEM\CurrentControlSet\Services\LanmanServer\Shares')
        if ($null -eq $key) { throw 'registry key missing' }
        $names = $key.GetValueNames()
        $key.Dispose()

        # 以 $ 开头的是系统共享（C$ / IPC$ / ADMIN$），不计入
        $c = 0
        foreach ($n in $names) {
            if ($n.Length -gt 0 -and $n[0] -ne '$') { $c++ }
        }
        return $c
    } catch {
        return @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { -not $_.Special }).Count
    }
}

# 共享名列表（毫秒级）。Get-SmbShare 首次调用要 5~7 秒，不能放在启动路径上。
function Get-SmbShareNamesFast {
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SYSTEM\CurrentControlSet\Services\LanmanServer\Shares')
        if ($null -eq $key) { throw 'registry key missing' }
        $names = @($key.GetValueNames())
        $key.Dispose()
        return $names
    } catch {
        return @(Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
}

function Get-ProtocolList {
    $cfg  = Get-Config
    $list = @()

    # ---------- SMB ----------
    $lan     = Get-Service LanmanServer -ErrorAction SilentlyContinue
    $smbRun  = [bool]($lan -and $lan.Status -eq 'Running')
    $smbCnt  = Get-SmbShareCountFast
    $list += [pscustomobject]@{
        Key       = 'SMB'
        Name      = 'SMB'
        Port      = '445'
        Address   = "\\$env:COMPUTERNAME\<共享名>"
        Installed = $true
        Running   = $smbRun
        Detail    = "系统原生能力，无需安装 · 当前 $smbCnt 个共享"
        StateText = if ($smbRun) { '运行中' } else { '已停止' }
    }

    # ---------- WebDAV ----------
    $davInstalled = (Test-WinFeatureFast 'IIS-WebServer') -and (Test-WinFeatureFast 'IIS-WebDAV')
    $davSite = $null
    if ($davInstalled -and (Initialize-IisModule)) {
        $davSite = Get-Website -Name $cfg.WebDavSite -ErrorAction SilentlyContinue
    }
    $w3 = Get-Service W3SVC -ErrorAction SilentlyContinue
    $davRunning = [bool]($davSite -and $w3 -and $w3.Status -eq 'Running' -and $davSite.State -eq 'Started')

    $davDetail = '依赖 IIS Web 服务器 + WebDAV 发布'
    if (-not $davInstalled) { $davDetail = '组件未安装，点卡片右侧「安装组件」' }
    elseif (-not $davSite) { $davDetail = '组件已装，站点未创建（新增共享或点「重建 IIS 站点」）' }

    $davState = '未安装'
    if ($davInstalled) { if ($davRunning) { $davState = '运行中' } else { $davState = '已停止' } }

    $list += [pscustomobject]@{
        Key       = 'WebDAV'
        Name      = 'WebDAV'
        Port      = [string]$cfg.WebDavPort
        Address   = "http://$env:COMPUTERNAME`:$($cfg.WebDavPort)/<共享名>"
        Installed = $davInstalled
        Running   = $davRunning
        Detail    = $davDetail
        StateText = $davState
    }

    # ---------- FTP ----------
    $ftpInstalled = (Test-WinFeatureFast 'IIS-WebServer') -and (Test-WinFeatureFast 'IIS-FTPServer')
    $ftpSite = $null
    if ($ftpInstalled -and (Initialize-IisModule)) {
        $ftpSite = Get-Website -Name $cfg.FtpSite -ErrorAction SilentlyContinue
    }
    $ftpsvc = Get-Service FTPSVC -ErrorAction SilentlyContinue
    $ftpRunning = [bool]($ftpSite -and $ftpsvc -and $ftpsvc.Status -eq 'Running' -and $ftpSite.State -eq 'Started')

    $ftpDetail = '依赖 IIS Web 服务器 + FTP 服务'
    if (-not $ftpInstalled) { $ftpDetail = '组件未安装，点卡片右侧「安装组件」' }
    elseif (-not $ftpSite) { $ftpDetail = '组件已装，站点未创建（新增共享或点「重建 IIS 站点」）' }

    $ftpState = '未安装'
    if ($ftpInstalled) { if ($ftpRunning) { $ftpState = '运行中' } else { $ftpState = '已停止' } }

    $list += [pscustomobject]@{
        Key       = 'FTP'
        Name      = 'FTP'
        Port      = [string]$cfg.FtpPort
        Address   = "ftp://$env:COMPUTERNAME`:$($cfg.FtpPort)/<共享名>"
        Installed = $ftpInstalled
        Running   = $ftpRunning
        Detail    = $ftpDetail
        StateText = $ftpState
    }

    # ---------- SFTP ----------
    $sshInstalled = Test-OpenSshServer
    $sshd = Get-Service sshd -ErrorAction SilentlyContinue
    $sshRunning = [bool]($sshd -and $sshd.Status -eq 'Running')

    $sshDetail = '依赖 OpenSSH Server'
    if (-not $sshInstalled) {
        if (Test-WuServiceUsable) {
            $sshDetail = '组件未安装，点卡片右侧「安装组件」'
        } else {
            $sshDetail = '组件未安装 · 系统缺少 Windows Update，请点「安装组件」看说明'
        }
    }
    elseif (-not $sshRunning) { $sshDetail = '已安装，服务未启动' }
    else { $sshDetail = '已安装并运行 · 登录后按绝对路径访问' }

    $sshState = '未安装'
    if ($sshInstalled) { if ($sshRunning) { $sshState = '运行中' } else { $sshState = '已停止' } }

    $list += [pscustomobject]@{
        Key       = 'SFTP'
        Name      = 'SFTP'
        Port      = '22'
        Address   = "sftp://$env:COMPUTERNAME/"
        Installed = $sshInstalled
        Running   = $sshRunning
        Detail    = $sshDetail
        StateText = $sshState
    }

    return $list
}

function Install-Protocol {
    param([Parameter(Mandatory = $true)][string]$Key)

    if (-not (Test-Admin)) {
        Write-Op '安装协议组件需要管理员权限。' 'ERR'; return $false
    }

    switch ($Key) {
        'SMB' {
            Write-Op 'SMB 是 Windows 系统原生能力，无需安装。' 'OK'
            return $true
        }
        'WebDAV' {
            Write-Op '——— 安装 WebDAV 所需组件 ———' 'INFO'
            Install-Plugin -Key 'IIS-WEB'    | Out-Null
            Install-Plugin -Key 'IIS-WEBDAV' | Out-Null
            return $true
        }
        'FTP' {
            Write-Op '——— 安装 FTP 所需组件 ———' 'INFO'
            Install-Plugin -Key 'IIS-WEB' | Out-Null
            Install-Plugin -Key 'IIS-FTP' | Out-Null
            return $true
        }
        'SFTP' {
            Write-Op '——— 安装 SFTP 所需组件 ———' 'INFO'
            return [bool](Install-Plugin -Key 'OPENSSH')
        }
        default {
            Write-Op "未知协议：$Key" 'ERR'
            return $false
        }
    }
}

function Start-Protocol {
    param([Parameter(Mandatory = $true)][string]$Key)

    $cfg = Get-Config
    try {
        switch ($Key) {
            'SMB' {
                Start-Service LanmanServer -ErrorAction Stop
                Write-Op 'SMB 服务已启动。' 'OK'
                return $true
            }
            'WebDAV' {
                if (-not (Initialize-IisModule)) { Write-Op 'IIS 管理模块不可用。' 'ERR'; return $false }
                if (-not (Get-Website -Name $cfg.WebDavSite -ErrorAction SilentlyContinue)) {
                    Write-Op 'WebDAV 站点尚未创建，请先新增一个共享或点「重建 IIS 站点」。' 'ERR'
                    return $false
                }
                $w3 = Get-Service W3SVC -ErrorAction SilentlyContinue
                if ($w3 -and $w3.Status -ne 'Running') { Start-Service W3SVC -ErrorAction SilentlyContinue }
                Start-Website -Name $cfg.WebDavSite -ErrorAction Stop
                Write-Op 'WebDAV 站点已启动。' 'OK'
                return $true
            }
            'FTP' {
                if (-not (Initialize-IisModule)) { Write-Op 'IIS 管理模块不可用。' 'ERR'; return $false }
                if (-not (Get-Website -Name $cfg.FtpSite -ErrorAction SilentlyContinue)) {
                    Write-Op 'FTP 站点尚未创建，请先新增一个共享或点「重建 IIS 站点」。' 'ERR'
                    return $false
                }
                $w3 = Get-Service W3SVC -ErrorAction SilentlyContinue
                if ($w3 -and $w3.Status -ne 'Running') { Start-Service W3SVC -ErrorAction SilentlyContinue }
                $fs = Get-Service FTPSVC -ErrorAction SilentlyContinue
                if ($fs -and $fs.Status -ne 'Running') { Start-Service FTPSVC -ErrorAction SilentlyContinue }
                Start-Website -Name $cfg.FtpSite -ErrorAction Stop
                Write-Op 'FTP 站点已启动。' 'OK'
                return $true
            }
            'SFTP' {
                $s = Get-Service sshd -ErrorAction SilentlyContinue
                if (-not $s) { Write-Op 'sshd 服务未安装。' 'ERR'; return $false }
                Start-Service sshd -ErrorAction Stop
                Write-Op 'SFTP（sshd）已启动。' 'OK'
                return $true
            }
            default { return $false }
        }
    } catch {
        Write-Op "启动 $Key 失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}

function Stop-Protocol {
    param([Parameter(Mandatory = $true)][string]$Key)

    $cfg = Get-Config
    try {
        switch ($Key) {
            'SMB' {
                Stop-Service LanmanServer -Force -ErrorAction Stop
                Write-Op 'SMB 服务已停止（本机共享与管理共享都会中断）。' 'WARN'
                return $true
            }
            'WebDAV' {
                if (-not (Initialize-IisModule)) { Write-Op 'IIS 管理模块不可用。' 'ERR'; return $false }
                if (-not (Get-Website -Name $cfg.WebDavSite -ErrorAction SilentlyContinue)) {
                    Write-Op 'WebDAV 站点不存在。' 'ERR'; return $false
                }
                Stop-Website -Name $cfg.WebDavSite -ErrorAction Stop
                Write-Op 'WebDAV 站点已停止（FTP 不受影响）。' 'OK'
                return $true
            }
            'FTP' {
                if (-not (Initialize-IisModule)) { Write-Op 'IIS 管理模块不可用。' 'ERR'; return $false }
                if (-not (Get-Website -Name $cfg.FtpSite -ErrorAction SilentlyContinue)) {
                    Write-Op 'FTP 站点不存在。' 'ERR'; return $false
                }
                Stop-Website -Name $cfg.FtpSite -ErrorAction Stop
                Write-Op 'FTP 站点已停止（WebDAV 不受影响）。' 'OK'
                return $true
            }
            'SFTP' {
                $s = Get-Service sshd -ErrorAction SilentlyContinue
                if (-not $s) { Write-Op 'sshd 服务未安装。' 'ERR'; return $false }
                Stop-Service sshd -Force -ErrorAction Stop
                Write-Op 'SFTP（sshd）已停止。' 'OK'
                return $true
            }
            default { return $false }
        }
    } catch {
        Write-Op "停止 $Key 失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}

# ============================================================
# 插件 / 组件中心
# ============================================================
# 特性探测有两条路，用途不同，别混用：
#
#   Test-WinFeature      — 真问 DISM（Get-WindowsOptionalFeature），语义准确，
#                          但首次调用约 5 秒，而且 DISM 全局只有一个会话锁，
#                          多个实例同时启动会互相排队，能拖到分钟级。
#                          只用于「要不要执行安装」这种必须准确的场合。
#
#   Test-WinFeatureFast  — 只看 inetsrv 下的文件 / 服务注册键，毫秒级。
#                          用于界面展示「已安装 / 未安装」。
#
# 两者都带进程内缓存，重复刷新不再重复付出代价。
$script:FeatureCache = @{}

function Test-WinFeatureFast {
    param([string]$Name, [switch]$Fresh)

    if (-not $Fresh -and $script:FeatureCache.ContainsKey("fast:$Name")) {
        return $script:FeatureCache["fast:$Name"]
    }

    $inetsrv = Join-Path $env:windir 'System32\inetsrv'
    $result  = $false
    switch ($Name) {
        'IIS-WebServerRole'     { $result = Test-Path (Join-Path $inetsrv 'w3wp.exe') }
        'IIS-WebServer'         { $result = Test-Path (Join-Path $inetsrv 'w3wp.exe') }
        'IIS-WebDAV'            { $result = Test-Path (Join-Path $inetsrv 'webdav.dll') }
        'IIS-FTPServer'         { $result = Test-Path (Join-Path $inetsrv 'ftpsvc.dll') }
        'IIS-FTPSvc'            { $result = Test-Path (Join-Path $inetsrv 'ftpsvc.dll') }
        'IIS-ManagementConsole' {
            $result = (Test-Path (Join-Path $inetsrv 'inetsrv.dll')) -and
                      (Test-Path 'HKLM:\SOFTWARE\Microsoft\InetMgr')
        }
        default {
            # 认不出来的特性名，退回 DISM（有缓存兜底，最多慢一次）
            return (Test-WinFeature -Name $Name)
        }
    }
    $script:FeatureCache["fast:$Name"] = [bool]$result
    return [bool]$result
}

function Test-WinFeature {
    param([string]$Name, [switch]$Fresh)

    if (-not $Fresh -and $script:FeatureCache.ContainsKey($Name)) {
        return $script:FeatureCache[$Name]
    }
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        $ok = ($f.State -eq 'Enabled')
    } catch {
        $ok = $false
    }
    $script:FeatureCache[$Name] = [bool]$ok
    return [bool]$ok
}

function Test-OpenSshServer {
    param([switch]$Fresh)

    if (-not $Fresh -and $script:FeatureCache.ContainsKey('openssh')) {
        return $script:FeatureCache['openssh']
    }

    # 快速路径：磁盘上有 sshd.exe 就算装了（约 20ms）。
    # 能力包查询是 DISM，冷启动 0.6~5 秒，而且 wuauserv 被掏空的机器上
    # 会长时间挂住 —— 所以先看文件，找不到再问，问了也没用就直接放弃。
    $ok = [bool](Find-SshdBinary)

    if (-not $ok -and (Test-WuServiceUsable)) {
        try {
            $c = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop |
                 Select-Object -First 1
            if ($c -and $c.State -eq 'Installed') { $ok = $true }
        } catch { }
    }

    $script:FeatureCache['openssh'] = [bool]$ok
    return [bool]$ok
}

function Test-Ps2Exe {
    return [bool](Get-Module -ListAvailable -Name ps2exe -ErrorAction SilentlyContinue)
}

# ============================================================
# OpenSSH Server 安装（带兜底链路）
# ============================================================
# 关键事实：Add-WindowsCapability 报 0x80070424「指定的服务未安装」时，
# 缺的不是 sshd，而是 DISM 背后的 Windows Update 服务（wuauserv）。
# 很多「系统优化/精简」工具会把 wuauserv 的服务注册直接删掉（注册表键还在，
# 但 ImagePath / Start / ServiceDll 全空，Get-Service 直接查不到），
# 于是 DISM 下载组件包的链路彻底断掉，错误信息还极具误导性。
#
# 所以这里的策略是：
#   1) 探测 wuauserv 是否可用；不可用就直接说清楚原因，不再白等几十秒
#   2) 优先使用本机已有的 sshd.exe（便携版 OpenSSH 也认），手工注册服务即可
#   3) 都没有，才走 Windows 能力包安装
function Test-WuServiceUsable {
    $svc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    if ($svc) { return $true }

    # 服务对象查不到，再看注册表是不是「键在内容空」的残骸
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv'
    if (-not (Test-Path $key)) { return $false }
    $img = (Get-ItemProperty -Path $key -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    return [bool]($img -and $img.Trim())
}

function Find-SshdBinary {
    $candidates = @(
        (Join-Path $env:windir 'System32\OpenSSH\sshd.exe'),
        'C:\Program Files\OpenSSH\sshd.exe',
        'C:\Program Files\OpenSSH-Win64\sshd.exe',
        'C:\OpenSSH\sshd.exe',
        (Join-Path $script:ConfigDir 'OpenSSH\sshd.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return ''
}

# ------------------------------------------------------------
# 便携版 OpenSSH 下载（能力包链路断掉时的兜底）
# ------------------------------------------------------------
function Get-OpenSshPortable {
    $target = 'C:\Program Files\OpenSSH'
    $zip = Join-Path $env:TEMP ('OpenSSH-Win64-' + [Guid]::NewGuid().ToString('N') + '.zip')

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $urls = New-Object System.Collections.Generic.List[string]
    $urls.Add('https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip')

    # 直链拿不到时，用 API 找出当前的 zip 资产地址
    if ($urls.Count -eq 1) {
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' `
                                     -Headers @{ 'User-Agent' = 'WinShareManager' } -TimeoutSec 25 -ErrorAction Stop
            foreach ($a in $rel.assets) {
                if ($a.name -eq 'OpenSSH-Win64.zip') { $urls.Add($a.browser_download_url) }
            }
        } catch { }
    }

    $got = $false
    foreach ($u in $urls) {
        Write-Op "正在下载 OpenSSH-Win64.zip ..." 'INFO'
        try {
            Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            if ((Get-Item $zip).Length -gt 1MB) { $got = $true; break }
        } catch {
            Write-Op "下载失败：$($_.Exception.Message)" 'WARN'
        }
    }
    if (-not $got) {
        if (Test-Path $zip) { Move-Item $zip (Join-Path $env:TEMP ('ossh_fail_' + (Get-Date -Format 'HHmmss') + '.zip')) -Force }
        Write-Op '便携版下载失败（网络不通或被拦截）。' 'ERR'
        return ''
    }

    $tmp = Join-Path $env:TEMP ('ossh_unz_' + [Guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force -ErrorAction Stop
    } catch {
        Write-Op "解压失败：$($_.Exception.Message)" 'ERR'
        return ''
    }

    $src = Get-ChildItem $tmp -Directory -ErrorAction SilentlyContinue |
           Where-Object { Test-Path (Join-Path $_.FullName 'sshd.exe') } |
           Select-Object -First 1
    if (-not $src) {
        Write-Op '压缩包里没找到 sshd.exe。' 'ERR'
        return ''
    }

    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    # 整体复制（覆盖旧文件），目标目录里已有配置不动的文件也一并刷新可执行体
    Copy-Item (Join-Path $src.FullName '*') $target -Recurse -Force -ErrorAction SilentlyContinue
    Write-Op "便携版已展开到 $target" 'OK'

    if (Test-Path $zip) { Move-Item $zip (Join-Path $env:TEMP ('ossh_ok_' + (Get-Date -Format 'HHmmss') + '.zip')) -Force }
    return (Join-Path $target 'sshd.exe')
}

# ------------------------------------------------------------
# 主机密钥权限收紧（关键！漏了这一步 sshd 必死）
# ------------------------------------------------------------
# sshd 逐把加载主机私钥时会做权限校验：只要发现「其他人也能读」就直接
# 忽略该密钥，四把全被忽略后输出 "sshd: no hostkeys available -- exiting"，
# 服务表现为「启动后立即退出」，但事件日志里只有一条毫无信息量的 7034。
#
# %ProgramData%\ssh 默认把 Authenticated Users:读取 继承给所有子文件，
# 于是刚生成的私钥天然就是「过宽」的 —— 必须逐文件断开继承、只留
# SYSTEM 与 Administrators。
function Repair-SshHostKeyPermission {
    param([string]$DataDir)

    $owner = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')
    $ruleSys = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')
    $ruleAdm = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators', 'FullControl', 'Allow')

    $fixed = 0
    foreach ($k in (Get-ChildItem -LiteralPath $DataDir -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue)) {
        try {
            $acl = Get-Acl -LiteralPath $k.FullName
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($ace in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($ace) }
            $acl.AddAccessRule($ruleSys)
            $acl.AddAccessRule($ruleAdm)
            try { $acl.SetOwner($owner) } catch { }
            Set-Acl -LiteralPath $k.FullName -AclObject $acl
            $fixed++
        } catch {
            Write-Op "私钥权限收紧失败（$($k.Name)）：$($_.Exception.Message)" 'WARN'
        }
    }
    if ($fixed -gt 0) { Write-Op "已收紧 $fixed 个主机私钥的访问权限（仅 SYSTEM / Administrators）。" 'OK' }
    return ($fixed -gt 0)
}

# ------------------------------------------------------------
# sshd 运行前置条件：配置 + 主机密钥 + 私钥权限 + 服务特权
# ------------------------------------------------------------
function Initialize-OpenSshRuntime {
    param([string]$SshdExe)

    $root = Split-Path -Parent $SshdExe
    $data = Join-Path $env:ProgramData 'ssh'
    if (-not (Test-Path $data)) { New-Item -ItemType Directory -Path $data -Force | Out-Null }
    $logs = Join-Path $data 'logs'
    if (-not (Test-Path $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }

    # ---- sshd_config ----
    $cfg = Join-Path $data 'sshd_config'
    if (-not (Test-Path $cfg)) {
        $tpl = Join-Path $root 'sshd_config_default'
        if (Test-Path $tpl) {
            Copy-Item -LiteralPath $tpl -Destination $cfg -Force
            Write-Op '已生成 sshd_config（取自官方模板）。' 'OK'
        } else {
            $inline = @(
                'Port 22',
                'Subsystem sftp sftp-server.exe',
                'AuthorizedKeysFile .ssh/authorized_keys',
                'Match Group administrators',
                '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($cfg, $inline + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-Op '已生成最小可用 sshd_config。' 'OK'
        }
    }

    # ---- 主机密钥 ----
    $keys = @(Get-ChildItem -LiteralPath $data -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue)
    if ($keys.Count -eq 0) {
        $kg = Join-Path $root 'ssh-keygen.exe'
        if (-not (Test-Path $kg)) {
            Write-Op '缺少 ssh-keygen.exe，无法生成主机密钥。' 'ERR'
            return $false
        }
        Write-Op '正在生成 SSH 主机密钥...' 'INFO'
        Push-Location $data
        try { & $kg -A 2>&1 | ForEach-Object { if ("$_".Trim()) { Write-Op "  $_" 'INFO' } } }
        catch { Write-Op "生成主机密钥失败：$($_.Exception.Message)" 'ERR' }
        Pop-Location
        $keys = @(Get-ChildItem -LiteralPath $data -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue)
    }
    if ($keys.Count -eq 0) {
        Write-Op '主机密钥仍为空，sshd 无法启动。' 'ERR'
        return $false
    }
    Write-Op "主机密钥：$($keys.Count) 把。" 'OK'

    # ---- 私钥权限（不收紧必然 no hostkeys available）----
    Repair-SshHostKeyPermission -DataDir $data | Out-Null

    # ---- 服务特权 ----
    # 官方 install-sshd.ps1 用 `sc privs sshd ...` 写 RequiredPrivileges。
    # LocalSystem 服务的默认特权集不含 SeAssignPrimaryTokenPrivilege / SeTcbPrivilege，
    # 缺了它们 sshd 无法为登录用户创建令牌。这里直接写注册表，等价且不依赖 sc.exe。
    $sk = 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd'
    if (Test-Path $sk) {
        $want = @('SeAssignPrimaryTokenPrivilege', 'SeTcbPrivilege', 'SeBackupPrivilege',
                  'SeRestorePrivilege', 'SeImpersonatePrivilege')
        $has = (Get-ItemProperty -Path $sk -Name 'RequiredPrivileges' -ErrorAction SilentlyContinue).RequiredPrivileges
        if (-not $has) {
            try {
                New-ItemProperty -Path $sk -Name 'RequiredPrivileges' -PropertyType MultiString `
                                 -Value $want -Force -ErrorAction Stop | Out-Null
                Write-Op '已为 sshd 服务补充必需特权（AssignPrimaryToken / Tcb / Backup / Restore / Impersonate）。' 'OK'
            } catch {
                Write-Op "服务特权写入失败：$($_.Exception.Message)" 'WARN'
            }
        }
    }

    # ---- 加进系统 PATH（让 sftp / scp 命令行直接可用）----
    try {
        $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($mp -and ($mp -split ';' | Where-Object { $_.TrimEnd('\') -ieq $root.TrimEnd('\') }).Count -eq 0) {
            [Environment]::SetEnvironmentVariable('Path', ($mp.TrimEnd(';') + ';' + $root), 'Machine')
            Write-Op "已将 $root 加入系统 PATH。" 'OK'
        }
    } catch { }

    return $true
}

function Install-OpenSshServer {
    $sshdExe = Find-SshdBinary

    # ---- 1. 探测 Windows Update 服务（决定还能不能走能力包）----
    $wuOk = Test-WuServiceUsable
    if (-not $wuOk) {
        Write-Op '检测到 Windows Update 服务（wuauserv）不可用 —— 它的注册项被清理工具删空了（ImagePath / ServiceDll 为空）。' 'WARN'
        Write-Op 'DISM 靠这个服务下载组件包，所以此处必然报 0x80070424「指定的服务未安装」，与 sshd 本身无关。' 'WARN'
        Write-Op '因此不再尝试在线安装，改为使用本机已有的 sshd.exe。' 'INFO'
    }

    # ---- 2. 拉起 CBS 依赖的服务（有就拉，没有就跳过）----
    if ($wuOk) {
        foreach ($svcName in @('wuauserv', 'BITS', 'TrustedInstaller')) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -eq 'Running') { continue }
            try {
                if ($svc.StartType -eq 'Disabled') {
                    Set-Service -Name $svcName -StartupType Manual -ErrorAction Stop
                    Write-Op "依赖服务 $svcName 处于「禁用」，已改为「手动」。" 'WARN'
                }
                Start-Service -Name $svcName -ErrorAction Stop
                Write-Op "已启动依赖服务 $svcName。" 'OK'
            } catch {
                Write-Op "依赖服务 $svcName 启动失败：$($_.Exception.Message)" 'WARN'
            }
        }
    }

    # ---- 3. 没有 sshd.exe 时才去装能力包 ----
    if (-not $sshdExe -and $wuOk) {
        $cap = $null
        try {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
        } catch {
            try {
                $cap = Get-WindowsCapability -Online -ErrorAction Stop |
                       Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
            } catch { }
        }

        if ($cap -and $cap.State -eq 'Installed') {
            Write-Op '能力包状态为已安装，但没找到 sshd.exe，请检查是否被杀毒软件隔离。' 'WARN'
        } elseif (-not $cap) {
            Write-Op '本机查询不到 OpenSSH.Server 能力包（系统可能被精简或组件源被移除）。' 'WARN'
        } else {
            Write-Op '正在安装 OpenSSH Server（需联网下载，约 10-60 秒）...' 'INFO'
            try {
                $r = Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                if ($r.RestartNeeded) { Write-Op '能力包已安装，系统要求重启后生效。' 'WARN' }
                else { Write-Op 'OpenSSH Server 能力包安装完成。' 'OK' }
            } catch {
                Write-Op "能力包安装失败：$($_.Exception.Message)" 'WARN'
            }
        }
        $sshdExe = Find-SshdBinary
    }

    # ---- 3.5 能力包这条路走不通时，直接取官方便携版 ----
    if (-not $sshdExe) {
        Write-Op '改为下载官方便携版 OpenSSH（绕开 Windows Update 依赖）...' 'INFO'
        $sshdExe = Get-OpenSshPortable
    }

    # ---- 4. 仍然没有可执行文件：给出可执行的替代路径 ----
    if (-not $sshdExe) {
        Write-Op '未找到 sshd.exe —— 本机确实还没有 OpenSSH 服务端。' 'ERR'
        Write-Op '方案 A（不联网、不动系统服务）：下载 OpenSSH-Win64.zip，把解压出的整个文件夹放到 C:\Program Files\OpenSSH\，再点一次本按钮即可自动注册服务。' 'WARN'
        Write-Op '方案 B（恢复系统在线安装能力）：以管理员身份执行 —— sc create wuauserv type= share start= demand binPath= "%SystemRoot%\system32\svchost.exe -k netsvcs" 然后 reg add "HKLM\SYSTEM\CurrentControlSet\Services\wuauserv\Parameters" /v ServiceDll /t REG_EXPAND_SZ /d "%SystemRoot%\system32\wuaueng.dll" /f 再 net start wuauserv，之后重试。' 'WARN'
        Write-Op '方案 C（图形界面）：设置 → 应用 → 可选功能 → 添加功能 → 搜索「OpenSSH 服务器」（同样依赖 Windows Update）。' 'WARN'
        return $false
    }
    Write-Op "使用 sshd.exe：$sshdExe" 'OK'

    # ---- 5. 服务注册（能力包落地但服务缺失时手工注册）----
    $svcSshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $svcSshd) {
        Write-Op 'sshd 服务未注册，正在手工注册为系统服务...' 'WARN'
        try {
            New-Service -Name 'sshd' `
                        -BinaryPathName ('"' + $sshdExe + '"') `
                        -StartupType Automatic `
                        -DisplayName 'OpenSSH SSH Server' `
                        -ErrorAction Stop | Out-Null
            Write-Op 'sshd 服务已注册（自动启动）。' 'OK'
        } catch {
            Write-Op "sshd 服务注册失败：$($_.Exception.Message)" 'ERR'
            Write-Op '多半是文件权限问题：请确认当前是管理员，且目录未被安全软件锁住。' 'WARN'
            return $false
        }
    } else {
        try { Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop } catch { }
    }

    # ---- 5.5 运行前置条件（配置 / 主机密钥 / 私钥权限 / 服务特权）----
    # 这一步是「服务注册成功但启动即退出」的唯一正解：
    # 缺 sshd_config、缺主机密钥、或私钥权限过宽，sshd 都会静默退出。
    if (-not (Initialize-OpenSshRuntime -SshdExe $sshdExe)) {
        Write-Op 'sshd 运行前置条件未满足，服务无法启动。' 'ERR'
        return $false
    }

    # ---- 6. 启动并等它真的起来 ----
    $running = $false
    for ($i = 0; $i -lt 12; $i++) {
        $cur = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if ($cur -and $cur.Status -eq 'Running') { $running = $true; break }
        try { Start-Service -Name sshd -ErrorAction Stop } catch { }
        Start-Sleep -Milliseconds 700
    }

    # ---- 7. 防火墙放行 22 ----
    try {
        $rule = Get-NetFirewallRule -DisplayName 'WinShareManager SFTP (22)' -ErrorAction SilentlyContinue
        if (-not $rule) {
            New-NetFirewallRule -DisplayName 'WinShareManager SFTP (22)' -Direction Inbound `
                -Action Allow -Protocol TCP -LocalPort 22 -Profile Any -ErrorAction Stop | Out-Null
            Write-Op '已添加入站规则，放行 TCP 22。' 'OK'
        }
    } catch {
        Write-Op "防火墙规则写入失败（不影响局域网内使用，公网需手动放行）：$($_.Exception.Message)" 'WARN'
    }

    if ($running) {
        Write-Op 'OpenSSH Server 已就绪并运行，SFTP 可用。' 'OK'
        return $true
    }

    # 起不来时把 sshd 自己的日志尾巴贴出来，比让用户翻事件查看器有用得多
    Write-Op '组件已就位，但 sshd 服务没能启动。' 'ERR'
    $sshdLog = Join-Path (Join-Path $env:ProgramData 'ssh') 'logs\sshd.log'
    if (Test-Path $sshdLog) {
        Write-Op '--- sshd 日志末尾 ---' 'WARN'
        Get-Content -LiteralPath $sshdLog -Tail 12 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Op "  $_" 'WARN' }
    }
    Write-Op '常见原因：主机私钥权限过宽（sshd 会拒绝加载并输出 no hostkeys available）、sshd_config 缺失或损坏、22 端口被其它程序占用。' 'WARN'
    Write-Op '也可在「服务」里手动启动 OpenSSH SSH Server 后查看系统事件日志中的 7034 条目。' 'WARN'
    return $false
}

function Get-PluginList {
    $list = @()

    $iisWeb = (Test-WinFeatureFast 'IIS-WebServerRole') -and (Test-WinFeatureFast 'IIS-WebServer')
    $list += [pscustomobject]@{
        Key       = 'IIS-WEB'
        Name      = 'IIS Web 服务器'
        Purpose   = 'WebDAV 与 FTP 的宿主，附带 IIS 管理控制台'
        Installed = $iisWeb
        Detail    = if ($iisWeb) { '已启用' } else { '未启用' }
    }

    $dav = Test-WinFeatureFast 'IIS-WebDAV'
    $list += [pscustomobject]@{
        Key       = 'IIS-WEBDAV'
        Name      = 'IIS WebDAV 发布'
        Purpose   = '提供 WebDAV 协议（浏览器 / 手机 / 跨平台挂载）'
        Installed = $dav
        Detail    = if ($dav) { '已启用' } else { '未启用' }
    }

    $ftp = (Test-WinFeatureFast 'IIS-FTPServer') -and (Test-WinFeatureFast 'IIS-FTPSvc')
    $list += [pscustomobject]@{
        Key       = 'IIS-FTP'
        Name      = 'IIS FTP 服务'
        Purpose   = '提供 FTP 协议（传统设备 / 内网设备）'
        Installed = $ftp
        Detail    = if ($ftp) { '已启用' } else { '未启用' }
    }

    $ssh = Test-OpenSshServer
    $list += [pscustomobject]@{
        Key       = 'OPENSSH'
        Name      = 'OpenSSH Server'
        Purpose   = '提供 SFTP 协议（SSH 加密通道）'
        Installed = $ssh
        Detail    = if ($ssh) { '已安装' } else { '未安装' }
    }

    $ps2 = Test-Ps2Exe
    $ps2Ver = ''
    if ($ps2) {
        $m = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
        $ps2Ver = [string]$m.Version
    }
    $list += [pscustomobject]@{
        Key       = 'PS2EXE'
        Name      = 'ps2exe 打包插件'
        Purpose   = '把本程序编译成单文件独立 EXE（可选，不装也能正常使用）'
        Installed = $ps2
        Detail    = if ($ps2) { "已安装 v$ps2Ver" } else { '未安装' }
    }

    return $list
}

function Install-Plugin {
    param([Parameter(Mandatory = $true)][string]$Key)

    switch ($Key) {
        'IIS-WEB' {
            $feats = @('IIS-WebServerRole', 'IIS-WebServer', 'IIS-CommonHttpFeatures',
                       'IIS-StaticContent', 'IIS-DefaultDocument', 'IIS-HttpErrors',
                       'IIS-DirectoryBrowsing', 'IIS-ManagementConsole')
        }
        'IIS-WEBDAV' {
            $feats = @('IIS-WebDAV')
        }
        'IIS-FTP' {
            $feats = @('IIS-FTPServer', 'IIS-FTPSvc', 'IIS-FTPExtensibility')
        }
        'OPENSSH' {
            $feats = @()
        }
        'PS2EXE' {
            $feats = @()
        }
        default {
            Write-Op "未知插件：$Key" 'ERR'
            return $false
        }
    }

    if (-not (Test-Admin)) {
        Write-Op '安装插件需要管理员权限。' 'ERR'
        return $false
    }

    # ---- Windows 功能 ----
    $fail = 0
    foreach ($f in $feats) {
        try {
            if (Test-WinFeature $f) {
                Write-Op "[$Key] 功能 $f 已启用，跳过。" 'OK'
                continue
            }
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop
            if ($r.RestartNeeded) { Write-Op "[$Key] 功能 $f 已启用（需重启）。" 'WARN' }
            else { Write-Op "[$Key] 功能 $f 已启用。" 'OK' }
        } catch {
            Write-Op "[$Key] 功能 $f 启用失败：$($_.Exception.Message)" 'ERR'
            $fail++
        }
    }
    if ($fail -gt 0) {
        Write-Op "[$Key] 有 $fail 项组件没装上，请查看上面的错误行。" 'ERR'
        return $false
    }

    # ---- OpenSSH ----
    if ($Key -eq 'OPENSSH') {
        return (Install-OpenSshServer)
    }

    # ---- ps2exe ----
    if ($Key -eq 'PS2EXE') {
        try {
            if (Test-Ps2Exe) {
                Write-Op 'ps2exe 已安装，无需重复安装。' 'OK'
                return $true
            }
            Write-Op '正在安装 NuGet 提供程序（首次需要）...' 'INFO'
            try {
                Get-PackageProvider -Name NuGet -ErrorAction Stop | Out-Null
            } catch {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }
            try {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            } catch { }

            Write-Op '正在从 PSGallery 安装 ps2exe 模块...' 'INFO'
            Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Import-Module ps2exe -Force -ErrorAction SilentlyContinue
            Write-Op 'ps2exe 安装完成。' 'OK'
            return $true
        } catch {
            Write-Op "ps2exe 安装失败：$($_.Exception.Message)" 'ERR'
            Write-Op '可尝试手动执行：Install-Module ps2exe -Scope CurrentUser -Force' 'WARN'
            return $false
        }
    }

    Write-Op "插件 $Key 处理完成。" 'OK'
    return $true
}

function Build-StandaloneExe {
    param([string]$OutputDir)

    if (-not (Test-Ps2Exe)) {
        Write-Op '缺少 ps2exe 插件，请先在插件页安装。' 'ERR'
        return $false
    }

    if (-not $OutputDir) { $OutputDir = (Get-Location).Path }

    $guiFile  = Join-Path $OutputDir 'WinShareManager.ps1'
    $coreFile = Join-Path $OutputDir 'ShareManager.Core.ps1'
    if (-not (Test-Path $guiFile)) { Write-Op "找不到 $guiFile" 'ERR'; return $false }
    if (-not (Test-Path $coreFile)) { Write-Op "找不到 $coreFile" 'ERR'; return $false }

    try {
        Import-Module ps2exe -Force -ErrorAction SilentlyContinue

        $gui  = [System.IO.File]::ReadAllText($guiFile, [System.Text.Encoding]::UTF8)
        $core = [System.IO.File]::ReadAllText($coreFile, [System.Text.Encoding]::UTF8)

        $pattern = '(?s)# ---- 加载核心逻辑 ----.*?\. \$corePath'
        if ($gui -notmatch $pattern) {
            Write-Op '源文件中找不到核心加载标记，无法合并。' 'ERR'
            return $false
        }
        $merged = $gui -replace $pattern, $core

        $tempFile = Join-Path $env:TEMP ('wsm_build_' + [guid]::NewGuid().ToString('N') + '.ps1')
        $utf8bom  = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($tempFile, $merged, $utf8bom)
        Write-Op "已合并为单文件脚本（$([math]::Round((Get-Item $tempFile).Length/1KB,1)) KB）。" 'INFO'

        $outExe = Join-Path $OutputDir 'WinShareManager.exe'
        Invoke-PS2EXE -InputFile $tempFile `
                      -OutputFile $outExe `
                      -NoConsole `
                      -RequireAdmin `
                      -Title 'WinShareManager' `
                      -Description 'Windows 原生共享协议统一管理台' `
                      -Product 'WinShareManager' `
                      -Version '1.0.0.0'

        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

        if (Test-Path $outExe) {
            Write-Op "编译完成：$outExe（$([math]::Round((Get-Item $outExe).Length/1KB,1)) KB）" 'OK'
            return $true
        }
        Write-Op '编译命令已执行，但未找到输出文件。' 'ERR'
        return $false
    } catch {
        Write-Op "编译失败：$($_.Exception.Message)" 'ERR'
        return $false
    }
}
