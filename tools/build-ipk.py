#!/usr/bin/env python3
"""Local opkg ipk builds without an OpenWrt SDK.

Produces the same layout the SDK CI build produces (ar-format ipk:
debian-binary + control.tar.gz + data.tar.gz) so package behavior can be
tested on a live router between CI runs.

Usage: python tools/build-ipk.py [outdir]   (default: artifacts/local)
"""

import io
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = "1.0.11-r1"


def tar_gz(entries):
    """entries: list of (arcname, source_path_or_None, mode)."""
    buf = io.BytesIO()
    now = int(time.time())
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for arcname, src, mode in entries:
            ti = tarfile.TarInfo(arcname)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            ti.mtime = now
            if src is None:
                ti.type = tarfile.DIRTYPE
                ti.size = 0
                tf.addfile(ti)
            else:
                data = Path(src).read_bytes()
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def ar(members):
    out = io.BytesIO()
    out.write(b"!<arch>\n")
    for name, data in members:
        hdr = f"{name:<16}{int(time.time()):<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}".encode()
        out.write(hdr + b"`\n" + data)
        if len(data) % 2:
            out.write(b"\n")
    return out.getvalue()


def control_text(pkg):
    lines = [
        f"Package: {pkg['name']}",
        f"Version: {VERSION}",
        "Architecture: all",
        "Maintainer: Bianka5441",
        "Section: net",
        f"Description: {pkg['desc']}",
    ]
    if pkg["deps"]:
        lines.append(f"Depends: {pkg['deps']}")
    return ("\n".join(lines) + "\n").encode()


def with_parent_dirs(files):
    entries = []
    seen = set()
    for arcname, src, mode in files:
        parts = arcname.split("/")
        for i in range(1, len(parts)):
            d = "/".join(parts[:i])
            if d not in seen:
                seen.add(d)
                entries.append(("./" + d, None, 0o755))
        entries.append(("./" + arcname, str(ROOT / src), mode))
    return entries


PACKAGES = [
    dict(
        name="campus-auth",
        deps="curl, openssl-util",
        desc="Automatic authentication for gportal-based campus network portals",
        conffiles="/etc/config/campus-auth\n",
        files=[
            ("usr/bin/campus-auth", "campus-auth/files/campus-auth.sh", 0o755),
            ("usr/bin/campus-auth-loop", "campus-auth/files/campus-auth-loop.sh", 0o755),
            ("etc/init.d/campus-auth", "campus-auth/files/campus-auth.init", 0o755),
            ("usr/libexec/rpcd/campus-auth", "campus-auth/files/campus-auth.rpcd", 0o755),
            ("usr/share/campus-auth/proto/gportal.sh", "campus-auth/files/proto-gportal.sh", 0o644),
            ("usr/share/campus-auth/proto/ruijie.sh", "campus-auth/files/proto-ruijie.sh", 0o644),
            ("etc/config/campus-auth", "campus-auth/files/campus-auth.config", 0o600),
        ],
    ),
    dict(
        name="luci-app-campus-auth",
        deps="luci-base, campus-auth",
        desc="LuCI web interface for campus-auth",
        conffiles=None,
        files=[
            ("usr/share/luci/menu.d/luci-app-campus-auth.json",
             "luci-app-campus-auth/files/usr/share/luci/menu.d/luci-app-campus-auth.json", 0o644),
            ("usr/share/rpcd/acl.d/luci-app-campus-auth.json",
             "luci-app-campus-auth/files/usr/share/rpcd/acl.d/luci-app-campus-auth.json", 0o644),
            ("www/luci-static/resources/view/campus-auth/status.js",
             "luci-app-campus-auth/files/www/luci-static/resources/view/campus-auth/status.js", 0o644),
            ("www/luci-static/resources/view/campus-auth/settings.js",
             "luci-app-campus-auth/files/www/luci-static/resources/view/campus-auth/settings.js", 0o644),
            ("usr/lib/lua/luci/controller/campus-auth.lua",
             "luci-app-campus-auth/files/usr/lib/lua/luci/controller/campus-auth.lua", 0o644),
            ("usr/lib/lua/luci/model/cbi/campus-auth/settings.lua",
             "luci-app-campus-auth/files/usr/lib/lua/luci/model/cbi/campus-auth/settings.lua", 0o644),
            ("usr/lib/lua/luci/view/campus-auth/status.htm",
             "luci-app-campus-auth/files/usr/lib/lua/luci/view/campus-auth/status.htm", 0o644),
        ],
    ),
]


def build(pkg, outdir: Path):
    ctl_tmp = outdir / f".control-{pkg['name']}"
    ctl_tmp.write_bytes(control_text(pkg))
    control_entries = [("./control", str(ctl_tmp), 0o644)]
    conffiles_tmp = None
    if pkg["conffiles"]:
        conffiles_tmp = outdir / f".conffiles-{pkg['name']}"
        conffiles_tmp.write_bytes(pkg["conffiles"].encode())
        control_entries.append(("./conffiles", str(conffiles_tmp), 0o644))

    control = tar_gz(control_entries)
    data = tar_gz(with_parent_dirs(pkg["files"]))
    ctl_tmp.unlink()
    if conffiles_tmp:
        conffiles_tmp.unlink()

    # OpenWrt ipk layout (matches SDK output): the outer container is a
    # gzipped tar holding ./debian-binary, ./data.tar.gz and
    # ./control.tar.gz -- NOT an ar archive.
    outer = outdir / f"{pkg['name']}_{VERSION}_all.ipk"
    with tarfile.open(outer, mode="w:gz") as tf:
        db = io.BytesIO(b"2.0\n")
        ti = tarfile.TarInfo("./debian-binary")
        ti.size = db.getbuffer().nbytes
        ti.mode = 0o644
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        ti.mtime = int(time.time())
        tf.addfile(ti, db)
        for name, blob_bytes in (("./data.tar.gz", data), ("./control.tar.gz", control)):
            ti = tarfile.TarInfo(name)
            ti.size = len(blob_bytes)
            ti.mode = 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            ti.mtime = int(time.time())
            tf.addfile(ti, io.BytesIO(blob_bytes))
    print(f"built {outer} ({outer.stat().st_size} bytes)")


def main():
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "artifacts" / "local"
    outdir.mkdir(parents=True, exist_ok=True)
    for pkg in PACKAGES:
        build(pkg, outdir)


if __name__ == "__main__":
    main()
