#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_deb.py — 用纯 Python 构建 Debian .deb 包（不依赖 dpkg/ar，Windows/macOS/Linux 通用）。

产物：dist/WinShareManager-Linux_<ver>_all.deb
  /usr/bin/winsharemanager                              主程序（python3 单文件）
  /usr/share/doc/winsharemanager/copyright              版权说明
  /usr/share/applications/winsharemanager.desktop       桌面入口
  /usr/share/icons/hicolor/256x256/apps/winsharemanager.png  图标
control 依赖：python3, python3-tk, pkexec(polkit) — samba/vsftpd/minidlna 按需由应用自动装
"""
import io
import os
import struct
import sys
import tarfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 仓库根（本脚本在 packaging/ 下）
LINUX_DIR = os.path.join(ROOT, 'linux')
ASSETS_DIR = os.path.join(ROOT, 'packaging')
DIST = os.path.join(ROOT, 'dist')
VERSION = '1.0.0'
DEBVERSION = VERSION + '-1'


def ar_add(ar, name, data):
    """向 ar 归档写入一个成员（GNU ar 格式，字段空格填充）。"""
    header = ((name + '/').ljust(16) +
              str(int(time.time())).ljust(12) +
              '0'.ljust(6) + '0'.ljust(6) +
              '100644'.ljust(8) +
              str(len(data)).ljust(10) +
              '`\n').encode('ascii')
    assert len(header) == 60, len(header)
    ar.write(header)
    ar.write(data)
    if len(data) % 2:
        ar.write(b'\n')


def make_tar_gz(entries):
    """entries: [(arcname, filesystem_path, mode)]；统一 uid/gid=0，时间固定保证可重现。"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as tf:
        for arcname, src, mode in entries:
            ti = tf.gettarinfo(src, arcname=arcname)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = 1700000000
            ti.mode = mode
            with open(src, 'rb') as f:
                tf.addfile(ti, f)
    return buf.getvalue()


def build_text_tar_gz(files):
    """files: [(arcname, text_content, mode)]"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as tf:
        for arcname, content, mode in files:
            data = content.encode('utf-8')
            ti = tarfile.TarInfo(arcname)
            ti.size = len(data)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = 1700000000
            ti.mode = mode
            tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def main():
    os.makedirs(DIST, exist_ok=True)
    out_path = os.path.join(DIST, 'WinShareManager-Linux_{}_all.deb'.format(VERSION))

    # ---- data.tar.gz ----
    data_entries = [
        ('usr/bin/winsharemanager', os.path.join(LINUX_DIR, 'winsharemanager'), 0o755),
        ('usr/share/applications/winsharemanager.desktop',
         os.path.join(ASSETS_DIR, 'winsharemanager.desktop'), 0o644),
        ('usr/share/icons/hicolor/256x256/apps/winsharemanager.png',
         os.path.join(ASSETS_DIR, 'winsharemanager.png'), 0o644),
        ('usr/share/doc/winsharemanager/copyright',
         os.path.join(ASSETS_DIR, 'copyright'), 0o644),
    ]
    data_tgz = make_tar_gz(data_entries)

    # ---- control.tar.gz ----
    control_files = [
        ('./control', open(os.path.join(ASSETS_DIR, 'control'), encoding='utf-8').read()
         .replace('@VERSION@', DEBVERSION), 0o644),
        ('./postinst', open(os.path.join(ASSETS_DIR, 'postinst'), encoding='utf-8').read(), 0o755),
        ('./prerm', open(os.path.join(ASSETS_DIR, 'prerm'), encoding='utf-8').read(), 0o755),
    ]
    control_tgz = build_text_tar_gz(control_files)

    # ---- ar 归档 ----
    with open(out_path, 'wb') as ar:
        ar.write(b'!<arch>\n')
        ar_add(ar, 'debian-binary', b'2.0\n')
        ar_add(ar, 'control.tar.gz', control_tgz)
        ar_add(ar, 'data.tar.gz', data_tgz)

    size = os.path.getsize(out_path)
    print('BUILT: {} ({} bytes)'.format(out_path, size))
    # 自校验：重读归档头部
    with open(out_path, 'rb') as f:
        magic = f.read(8)
        assert magic == b'!<arch>\n', 'ar 魔数错误'
        f.seek(8)
        for expect in (b'debian-binary', b'control.tar.gz', b'data.tar.gz'):
            hdr = f.read(60)
            name = hdr[:16].rstrip(b'\x00/ ').decode()
            assert name == expect.decode(), '成员顺序错误: ' + name
            sz = int(hdr[48:58].split()[0])
            f.seek(sz + (sz % 2), 1)
        print('DEB-STRUCTURE-OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
