# WinShareManager v2.1.0 发布说明

发布日期：2026-10-27

## 新功能

### DLNA 共享协议（第五种协议，零依赖内置）

新增 **DLNA** 协议：电视、机顶盒、游戏机、手机播放器自动发现本机媒体服务器，无需输入任何地址。

- **纯内置实现**：SSDP（UDP 1900）负责设备发现 + HttpListener（TCP 8420）提供
  设备描述 / ContentDirectory 浏览 / 媒体流，全部用 .NET 原生能力，**不需要安装
  任何第三方软件**。
- **使用方式**：「新增共享」时勾选 DLNA → 「协议」页拨动开关（或启动时自动拉起）
  → 电视 / 播放器的媒体列表里选「WinShareManager (主机名)」即可浏览点播。
- **支持进度拖动**：媒体流实现 HTTP Range（实测 206 分段），视频可拖进度条。
- **媒体类型**：常见视频（mp4/mkv/avi/mov/wmv/ts…）、音频（mp3/flac/m4a/wav…）、
  图片（jpg/png/gif…），按目录逐层浏览。
- **端口可在「管理设置」调整**（默认 8420；8200 在部分机器上被其它程序占用）。
- **安全提示**：DLNA 协议本身不支持账号密码，勾选 DLNA 的目录对整个局域网只读
  开放，请只在内网使用。程序界面上有明确提示。
- 局域网 IP 自动识别时排除 WSL / Hyper-V 虚拟网卡，避免「看得见连不上」。

### 安装包改名

exe 产物名带上版本号：`WinShareManager_v2.1.0.exe`，一眼看出下载的是哪个版本。

### 管理设置改进

- 「管理设置」新增 DLNA 端口输入框，保存后自动生效（WebDAV / FTP 仍需重建站点）。
- 修正端口输入框标签被截断的问题（对话框加宽、布局重排）。

## 修复（v2.0.2 全部内容也包含在本版中）

1. **WebDAV 浏览器打开报 401.2**：安装链自动启用 `IIS-BasicAuthentication` +
   `IIS-WindowsAuthentication`，并确保站点挂上 `BasicAuthenticationModule`
   （401 现在带 `WWW-Authenticate` 质询头，浏览器正常弹登录框）。
2. **WebDAV 登录后报 403.14**：建站自动开启目录浏览，浏览器直接看到文件列表。
3. **FTP 报 451 / 根列表看不到共享**：FTP 目录别名一律 ASCII 化
   （非 ASCII 共享名 → `ftp-<哈希>` 稳定别名），并在站点根下创建 NTFS junction
   让共享在 FTP 根列表可见；同时修复 ssl 默认 `SslRequire` 导致的 534 登录失败。
4. **SFTP 打开默认连成 administrator**：弹出用户名输入框（记住上次账号），
   以 `用户名@主机` 连接。
5. **仓库链接图标**换成 GitHub 官方 octocat 剪影（内置 SVG path → GDI+ 转换器绘制）。

## 校验

| 文件 | 说明 |
|---|---|
| `WinShareManager_v2.1.0.exe` | 单文件，双击即用，需管理员权限 |
