# WinShareManager for Linux v1.0.0

一站式管理 SMB / WebDAV / FTP / SFTP / DLNA 局域网共享（苹果风 GUI，Python3 + Tkinter）。

## 安装

### Ubuntu / Debian（deb）

```bash
sudo apt install -y ./WinShareManager-Linux_1.0.0_all.deb
# 或
sudo dpkg -i WinShareManager-Linux_1.0.0_all.deb
sudo apt -f install   # 补依赖
```

### CachyOS / Arch（pacman）

```bash
# 方式一：PKGBUILD
mkdir wsm && cd wsm
cp ../PKGBUILD . && makepkg -si

# 方式二：便携包
tar xzf WinShareManager-Linux_1.0.0_portable.tar.gz
sudo install -m755 WinShareManager-Linux/winsharemanager /usr/bin/
sudo install -m644 WinShareManager-Linux/winsharemanager.desktop /usr/share/applications/
sudo install -m644 WinShareManager-Linux/winsharemanager.png /usr/share/icons/hicolor/256x256/apps/
```

> 注意：CachyOS 是 Arch 系，**不能安装 .deb**；请用 PKGBUILD 或便携包。

## 启动

- 应用菜单：**共享管理器**（自动经 pkexec 提权）
- 命令行：`sudo winsharemanager` 或 `pkexec winsharemanager`
- 部署自检：`winsharemanager --probe`

## 协议实现方式

| 协议 | 后端 | 说明 |
|------|------|------|
| SMB | samba | smb.conf 标记块管理，smbpasswd 同步账号 |
| WebDAV | 内置 Python 服务器 | systemd 服务 `winsharemanager-webdav` 常驻，Basic 认证 |
| FTP | vsftpd | 共享目录 bind-mount 到 `/srv/winsharemanager/ftp/`，fstab 持久化 |
| SFTP | sshd | 原生支持，绝对路径访问 |
| DLNA | minidlna | 自动生成 `/etc/minidlna.conf`，电视/手机自动发现 |

- 配置文件：`/etc/winsharemanager/config.json`（root 600）
- samba/vsftpd/minidlna 依赖按需自动安装（apt / pacman 自动区分）
- 若系统启用 ufw，会自动放行 21 / 445 / 8081 / 8200 / 1900

## 已知说明

- DLNA 与 SMB 一样无精细权限体系，DLNA 对整个局域网只读开放
- FTP 登录使用系统账号；中文共享名自动转 ASCII 别名（如 `ftp-1a2b3c4d`）
- 卸载 deb 不会删除你的共享目录与 `/etc/winsharemanager/config.json`
