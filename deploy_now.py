# -*- coding: utf-8 -*-
"""部署已下载的 deb 到设备(带 SSH 重试)"""
import time, os, paramiko

HOST, USER, PWD = "192.168.1.189", "root", "1"
DEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "VCamPlus_latest.deb")
print("deb:", DEB, os.path.getsize(DEB), "bytes")

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ok = False
for i in range(10):
    try:
        c.connect(HOST, port=22, username=USER, password=PWD, timeout=8, allow_agent=False, look_for_keys=False)
        ok = True
        print("SSH connected (attempt %d)" % (i + 1))
        break
    except Exception as ex:
        print("  SSH attempt %d failed: %s" % (i + 1, ex))
        time.sleep(6)
if not ok:
    print("DEVICE UNREACHABLE - 请解锁设备/确认 WiFi")
    raise SystemExit(1)

def run(cmd, tag, t=40):
    print(f"\n======== {tag} ========")
    try:
        _, o, e = c.exec_command(cmd, timeout=t)
        out = o.read().decode("utf-8", errors="replace").strip()
        err = e.read().decode("utf-8", errors="replace").strip()
        if out: print(out)
        if err: print("--STDERR--\n" + err)
        if not out and not err: print("(empty)")
    except Exception as e:
        print("ERR: %s" % e)

sftp = c.open_sftp()
sftp.put(DEB, "/tmp/VCamPlus_latest.deb")
sftp.close()
run('dpkg -i /tmp/VCamPlus_latest.deb 2>&1', "dpkg -i", t=30)
run('JR=$(/usr/bin/jbroot); /usr/bin/jb_ctl trustcache add "$JR/usr/lib/TweakInject/VCamPlus.dylib" 2>&1 || /usr/bin/jbctl trustcache add "$JR/usr/lib/TweakInject/VCamPlus.dylib" 2>&1; echo exit=$?', "trustcache add", t=30)
run('rm -f /rootfs/private/var/tmp/vcam_*.txt 2>/dev/null; echo cleared', "清旧日志", t=10)
run('killall -9 SpringBoard 2>&1; echo respring=$?', "Respring", t=10)
print("等待系统重启 (25s)...")
time.sleep(25)
run('killall -9 mediaserverd 2>&1; echo kill=$?', "killall mediaserverd", t=15)
time.sleep(12)

PLIST = ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
         '<key>enabled</key><true/><key>isLive</key><true/><key>metaFix</key><true/>'
         '<key>activePlaybackPath</key><string>/var/mobile/Media/DCIM/vcam.mp4</string>'
         '<key>paused</key><false/>'
         '</dict></plist>')
VC_REAL = "/rootfs/private/var/mobile/Media/DCIM/vc.plist"
sftp = c.open_sftp()
with sftp.open(VC_REAL, "w") as f: f.write(PLIST)
sftp.close()
print("vc.plist enabled=YES metaFix=YES written")
time.sleep(8)

run('grep "Loading in process" /rootfs/private/var/tmp/vcam_tweak_log.txt 2>/dev/null | tail -4', "进程加载记录")
run('tail -6 /rootfs/private/var/tmp/vcam_core_log.txt 2>/dev/null', "Core log 尾部")
c.close()
