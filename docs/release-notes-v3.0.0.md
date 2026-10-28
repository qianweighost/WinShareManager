# WinShareManager v3.0.0 发布说明 — Linux 版首发

> Windows 版保持 v2.1.2（见 docs/release-notes-v2.1.2.md）。本版本为 Linux 移植首发，
> 适配 **Ubuntu / Debian 系** 与 **CachyOS / Arch 系**。

## 下载

| 文件 | 适用 |
|------|------|
| `WinShareManager-Linux_1.0.0_all.deb` | Ubuntu / Debian（`sudo apt install ./xxx.deb`） |
| `WinShareManager-Linux_1.0.0_portable.tar.gz` | 任意发行版免安装 |
| `packaging/PKGBUILD` | CachyOS / Arch（`makepkg -si`） |

> **注意**：CachyOS 是 Arch 系，不能安装 .deb 包，请使用 PKGBUILD 或便携包。

## 功能（与 Windows 版对齐）

- **SMB** → samba：smb.conf 标记块管理（不碰用户已有配置），smbpasswd 同步账号，中文共享名自动 ASCII 别名
- **WebDAV** → 内置纯 Python 服务器：systemd 服务 `winsharemanager-webdav` 常驻（关掉 GUI 也在服务），Basic 认证，支持 PROPFIND/GET/PUT/MKCOL/DELETE/MOVE/COPY 与 Range 断点，路径穿越防护
- **FTP** → vsftpd：共享目录 bind-mount 到 `/srv/winsharemanager/ftp/`，fstab 标记块持久化，重启不丢
- **SFTP** → sshd：原生支持，无需额外配置
- **DLNA** → minidlna：自动生成 `/etc/minidlna.conf`，电视/手机自动发现

## 设计要点

- **跨发行版收敛**：`/etc/os-release` 自动识别 Debian 系（apt + smbd/ssh 服务名）与 Arch 系（pacman + smb/sshd 服务名），包名与服务名差异全部收敛到一张映射表
- **依赖按需安装**：勾选哪个协议才装哪个包（apt / pacman 自动区分）
- **GUI**：Python3 + Tkinter，苹果风浅色界面，协议卡片 + 共享列表 + 日志面板
- **提权**：桌面入口默认 pkexec，命令行 sudo 均可
- **配置**：`/etc/winsharemanager/config.json`（root 600），卸载不删用户数据
- **防火墙**：检测到 ufw 时自动放行 21 / 445 / 8081 / 8200 / 1900

## 验证

- WebDAV 引擎实测 10 项全过：OPTIONS / 401 挑战 / PROPFIND 207 / PUT / GET / Range 206 / MKCOL / DELETE / 删除后 404 / `../` 路径穿越封锁
- deb 包结构深度校验：ar 归档三成员 + control(postinst/prerm 权限) + data(usr 层级与 755 权限)
- 主程序 py_compile 通过

## 已知限制

- GUI 尚未在真机桌面环境过测（开发环境为 Windows），首次运行如遇问题请先跑 `winsharemanager --probe` 收集环境信息并提 issue
- WebDAV 锁（LOCK/UNLOCK）未实现，部分办公客户端的协作锁场景不适用（文件读写不受影响）
