# WinShareManager v2.0.1

修复 v2.0.0 的三个问题：启动极慢（进程在但窗口迟迟不出来）、复制的部分链接打不开、仓库地址以明文形式挤在状态栏。

## 下载

`WinShareManager.exe` —— 单文件，双击即用。约 320 KB，Windows 10 / 11 x64。

## 修复内容

### 启动从 30 秒以上降到 1 秒以内

v2.0.0 在窗口出现前要做一轮状态探测，里面有两类很重的调用：

| 调用 | 单次耗时 | 问题 |
|---|---|---|
| `Get-WindowsOptionalFeature`（DISM） | 首次约 5 秒 | DISM 全局只有一个会话锁，多开几个实例会互相排队，实测能拖到分钟级 |
| `Get-SmbShare`（CIM / SMB 模块） | 首次 5–7 秒 | 仅为数一下共享个数 |

现在改为：

- **IIS / WebDAV / FTP 特性探测**改看 `inetsrv` 下的文件与注册表键（`w3wp.exe` / `webdav.dll` / `ftpsvc.dll`），毫秒级；只有在认不出的特性名上才回落 DISM
- **共享数量与共享名列表**改读 `HKLM\SYSTEM\...\LanmanServer\Shares` 注册表键（实测 6 ms），注意这里**特意绕开了 PowerShell 管道**——`Get-ItemProperty` + `Where-Object` 的组合实测要多花 900 ms
- **探测结果带进程内缓存**，重复刷新不再重复付出代价
- **首轮刷新挪到 120 ms 后的一次性 Timer**：`Shown` 事件在窗口画出第一帧之前同步执行，把重活放在那里就会表现为「点了没反应、进程在但没窗口」

实测：窗口出现 0.9–1.1 秒，首轮状态刷新 1.6 秒内完成。同时新增 `WSM_TRACE=1` 环境变量，会把「界面层开始 / 窗体构建完成 / Shown 触发 / 首轮刷新完成」各阶段耗时写进 `ops.log`，以后再遇到启动慢可以直接看日志定位。

### 修复启动时的「不能对 Null 值表达式调用方法」

v2.0.0 在启动后 120 ms 会弹一个 .NET 未处理异常框。原因是启动 Timer 的回调里引用了定义处的局部变量 `$startupTimer`，而**事件处理器的执行作用域看不到它**，于是 `$startupTimer.Stop()` 变成了对 null 调方法。

修法：Timer 挂到 `$script:`，回调用 `param($s, $e)` 拿发送者；首轮刷新抽成独立函数 `Invoke-StartupRefresh`，界面自检现在会真正走到这条路径（v2.0.0 的自检根本没有触发它，所以测不出来）。

### 链接可用了

v2.0.0 生成的链接有三处硬伤：

| 协议 | 原来 | 问题 |
|---|---|---|
| WebDAV | `http://主机:8081/共享` | 中文共享名没做 URL 编码，裸非 ASCII 字符 |
| FTP | `ftp://主机:21/共享` | 同上，且现代浏览器已全面移除 FTP 支持 |
| SFTP | `sftp://主机/D:/共享` | **不成立**——`/D:/` 是把 Windows 盘符塞进 URL，任何 SFTP 客户端都解析不了 |

现在：

- WebDAV / FTP 的路径部分做 `EscapeDataString` 编码
- SFTP 链接只给 `sftp://主机`，远程路径由「打开」按钮复制到剪贴板
- 新增**「打开」列**：SMB / WebDAV / FTP 交给资源管理器或浏览器；SFTP 复制服务器上的 Windows 绝对路径并提示用 WinSCP / FileZilla

### 仓库地址改为图标

状态栏不再放明文地址，版本号右边是一个自绘的链环图标，悬停显示仓库与 Release 地址，点击在浏览器打开。

## 校验值

```text
SHA256  见 Release 资产说明
```
