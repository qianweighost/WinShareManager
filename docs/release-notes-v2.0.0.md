# WinShareManager v2.0.0

首个开源版本。一个界面统一管理 Windows 原生 **SMB / WebDAV / FTP / SFTP** 四种共享协议，四种协议共用同一套 Windows 本地账户与 NTFS 权限。

## 下载

`WinShareManager.exe` —— 单文件，双击即用。

- 约 310 KB，全部代码与图标内嵌，不需要安装、不需要 .NET SDK、不联网
- 启动请求管理员权限（UAC），修改共享 / 服务 / 防火墙所必需
- Windows 10 / 11 x64

## 这个版本做了什么

**统一权限模型**
四种协议都落到同一套 Windows 账户和 NTFS ACL：加一个用户，四种协议同时生效；改一次目录权限，四种协议同时受限。

**每个协议独立管控**
每张协议卡都有自己的「安装组件」按钮和启停滑块，启停走站点级 / 服务级控制，WebDAV 与 FTP 不会互相连带。

**共享按名字分组**
同一个共享名下的多个协议收拢成一组，每行可单独删除某个协议，也可以整条删除；链接一键复制。

**权限页看得懂**
账户名去掉计算机名前缀、内置组翻译成中文、权限级别折算成语义化描述、区分「继承」与「直接设置」，并过滤掉只作用于子目录的 `InheritOnly` 条目（这类 ACE 在 Windows 里会显示成 `268435456` 这种数字）。

**OpenSSH 安装全自动**
这一步在本项目里踩坑最多，现在已全部自动化：

1. 先探测 `wuauserv`（Windows Update）是否可用 —— 缺它时报的是误导性的 `0x80070424 指定的服务未安装`，实际与 sshd 无关
2. 不可用就不再白等，直接下载官方便携版解压到 `C:\Program Files\OpenSSH\`
3. 自动生成 `sshd_config` 与四把主机密钥
4. **收紧主机私钥权限**（`%ProgramData%\ssh` 默认把 `Authenticated Users:读取` 继承给私钥，sshd 会因此拒绝加载全部密钥并以 `no hostkeys available` 退出）
5. 补齐服务特权 `RequiredPrivileges`（`SeAssignPrimaryTokenPrivilege` / `SeTcbPrivilege` 等）
6. 注册服务、设为自动启动、轮询确认真的 Running、放行防火墙 22

启动仍失败时会直接贴出 `sshd.log` 末尾几行并列出常见原因，不用去翻事件查看器。

**界面不再「未响应」**
安装组件、重建站点这类长耗时操作交给自身子进程执行，主进程只轮询进度并实时 tail 日志，消息泵始终在转。

**单文件与图标**
ps2exe 真编译，清单直接声明 `requireAdministrator`，没有多级进程、任务栏只有一个图标。图标以 base64 注入，标题栏 / 任务栏 / Alt-Tab 三处一致（≤64 的 ICO 帧用 32bpp DIB 编码，避免 GDI+ 读小尺寸 PNG 帧出错）。

## 已知限制

- SMB 入站并发受 SKU 限制，Windows 10/11 桌面版约 20 个连接，多人办公需要 Windows Server
- FTP 与 WebDAV（非 HTTPS）都是明文传输密码，仅建议内网使用；对外网开放前请先配好 SSL 证书
- SFTP 无法对单个共享做 Chroot，登录后按绝对路径访问，权限由 NTFS 决定
- 权限页会隐藏 `SYSTEM` / `Administrators` / `TrustedInstaller` 等系统账户条目，避免刷屏

## 从源码构建

```powershell
Install-Module ps2exe -Scope CurrentUser -Force
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
```

版本号只有一处：`ShareManager.Core.ps1` 里的 `$script:AppVersion`，构建脚本会解析并同步到 exe 版本资源和界面显示。

## 许可

MIT
