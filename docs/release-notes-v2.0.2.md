# WinShareManager v2.0.2 发布说明

发布日期：2026-10-26

## 这版修了什么

三个「打开」之后不能用的老问题，全部实测修复（本机 FTP 登录 125、WebDAV 认证 207 验证通过）：

### 1. WebDAV 打开报 401.2，不弹登录框

- **根因**：`IIS-BasicAuthentication` 功能未启用，`authbas.dll` 缺失。站点配置里
  `basicAuthentication enabled="true"` 是死配置——模块根本没装，IIS 返回 401 时
  **不带 `WWW-Authenticate` 质询头**，浏览器收不到质询就直接渲染错误页（401.2）。
- **修复**：
  - WebDAV 安装链（`安装组件` / `一键安装环境`）现在会自动启用
    `IIS-BasicAuthentication` + `IIS-WindowsAuthentication`；
  - 建站时通过新增的 `Ensure-IisSiteModule` 确保站点挂上
    `BasicAuthenticationModule` / `WindowsAuthenticationModule`（功能后装时全局
    模块会注册，但站点自带 `<modules>` 覆盖集合时可能漏挂）。
- **实测**：匿名 PROPFIND 现在返回 `401 + WWW-Authenticate: Basic realm="..."`，
  浏览器弹出登录框；带凭据 PROPFIND 返回 `207 Multi-Status`。

### 2. FTP 资源管理器「Windows 无法访问此文件夹」

- **根因 1**：`IIS-FTPExtensibility` 功能未启用。FTP 站点里只有 `denyByFailure`，
  `basicAuthentication` / `anonymousAuthentication` / `ssl` 三个子节连 schema 都
  没注册，`appcmd set config` 直接报「未知配置节」——程序此前写认证配置全部静默失败。
- **根因 2**：`ssl` 策略默认 `SslRequire`，明文通道登录一律报 **534**。
- **修复**：
  - FTP 安装链补上 `IIS-FTPExtensibility`（此前已在列表中，但文件探测只认
    `ftpsvc.dll`，容易误判已装齐）；
  - `Ensure-FtpSite` 新增 `Set-AppCmdSiteProp` 兜底：用 `appcmd set site` 的
    `ftpServer.security.*` 点路径设置——Basic 开、匿名关、
    `controlChannelPolicy` / `dataChannelPolicy` 改 `SslAllow`；
  - 站点授权规则 `Allow * Read,Write` 保持不变。
- **实测**：`FtpWebRequest` 用本机账号登录返回 `125`，能列出共享目录。

### 3. SFTP 点「打开」只弹提示框

- **修复**：现在按优先级自动带起可用客户端——
  1. **WinSCP**（找到则直接 `sftp://主机/` 打开）；
  2. **FileZilla**；
  3. Windows 自带 **OpenSSH 命令行客户端**（`System32\OpenSSH\sftp.exe`），
     开一个控制台窗口直连本机，输入密码即可 `cd` 到共享目录；
  4. 都没有才退回「复制远程路径 + 安装指引」。

### 4. WebDAV 浏览器打开报 403.14（登录后）

- **根因**：浏览器「打开」是普通 GET（PROPFIND 只有 WebDAV 客户端才发），IIS
  目录浏览默认关闭，登录成功后照样 403.14「禁止列出目录内容」。
- **修复**：建站时自动写入 `directoryBrowse enabled="true"`，浏览器直接看到
  带日期/大小的文件列表，链接全部正确 URL 编码。
- **实测**：GET `/共享/` 返回 200，列出全部文件与子目录。

### 5. FTP 报 451（No mapping for the Unicode character）

- **根因（两层）**：
  1. 资源管理器 FTP 客户端对中文虚拟目录别名的代码页转换不可靠，IIS FTP 直接
     报 451，甚至列根目录时把中文别名整个吞掉；
  2. IIS FTP 的目录列表**不显示虚拟目录**（只显示站点根下的物理文件夹），
     即使别名正常用户从根进去也「看不见」共享。
- **修复**：
  - FTP 虚拟目录别名一律 ASCII 化：非 ASCII 共享名自动生成 `ftp-<哈希>` 稳定
    别名（FNV-1a，名字不变则别名不变），链接也直接用别名；
  - 站点物理根目录下同步创建 NTFS junction（联接点），共享在 FTP 根列表里
    真实可见；删除共享时联接点一并清理（只删联接本身，不动磁盘文件）。
- **实测**：`ftp://主机/ftp-9b1567d5/` 列出全部中文文件名（含子目录）；
  根列表可见 `ftp-9b1567d5` 与原有目录。

### 6. SFTP 打开默认连成 administrator

- **根因**：`sftp.exe 主机名` 不带用户时，OpenSSH 默认拿当前 Windows 账户
  （这里是 Administrator）去连，而共享授权的往往是别的账号。
- **修复**：点「打开」先弹出用户名输入框（预填上次用的账号并记住，存配置），
  以 `用户名@主机` 连接；WinSCP / FileZilla 分支同样带上用户名。

### 7. 仓库链接图标换成 GitHub 官方猫标

- 版本号旁的链接图标从通用链环换成 GitHub 官方 octocat 剪影（内置 SVG 路径
  转换器用 GDI+ 绘制，随主题色变化，悬停加深）。

## 升级方式

下载下方的 `WinShareManager.exe` 覆盖旧版即可，配置与已建共享不受影响。
已建站点的认证/SSL 修复会在下一次「重建 IIS 站点」或增删共享时自动补齐；
不想等的话，直接点一次「重建 IIS 站点」。

## 校验

| 文件 | 说明 |
|---|---|
| `WinShareManager.exe` | 单文件，双击即用，需管理员权限 |
