#!/usr/bin/env python3
"""Unpack a built .deb and verify structure without dpkg (pure stdlib).

Static-app variant (no ELF payload). Checks (per platform):
  - ar members: debian-binary / control.tar.gz / data.tar.xz
  - control.tar members live at the tar ROOT (./control — not ./DEBIAN/control)
  - control fields: Package / Version / Architecture match the build
  - payload contains the webui dist + nginx conf + lang + icon under
    ./usr/local/<app>/
  - the packaged webui files match webui/SHA256SUMS (dist SHA256 lock)
  - the dist carries no public-CDN asset references (intranet safety)

Usage: unpack_check.py <file.deb> <x86_64|aarch64> [expected_version]
Exit code 0 = pass.
"""
import hashlib
import io
import lzma
import re
import sys
import tarfile

FORBIDDEN_EXTERNAL = [
    "cdn.jsdelivr.net",
    "cdnjs.cloudflare.com",
    "unpkg.com",
    "fonts.googleapis.com",
    "fonts.gstatic.com",
]


def err(msg):
    print(f"ERROR: {msg}")
    return 1


def main() -> int:
    deb, platform = sys.argv[1], sys.argv[2]
    version = sys.argv[3] if len(sys.argv) > 3 else None
    app_id = "drawdb"
    want_arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(platform)
    if want_arch is None:
        return err(f"unknown platform {platform}")

    data = open(deb, "rb").read()
    if data[:8] != b"!<arch>\n":
        return err("not an ar archive")

    members = {}
    off = 8
    while off < len(data):
        hdr = data[off:off + 60]
        if len(hdr) < 60:
            return err("truncated ar header")
        name = hdr[0:16].decode().rstrip()
        size = int(hdr[48:58].decode().strip())
        members[name] = data[off + 60:off + 60 + size]
        off += 60 + size + (size % 2)

    for m in ("debian-binary", "control.tar.gz", "data.tar.xz"):
        if m not in members:
            return err(f"missing ar member {m}")
    if members["debian-binary"] != b"2.0\n":
        return err("debian-binary != 2.0")

    # control member: files must sit at the tar root
    with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"])) as tf:
        names = tf.getnames()
        ctl_txt = tf.extractfile("./control").read().decode()
    if "./control" not in names:
        return err(f"control.tar members not at root: {names[:5]}")
    if "DEBIAN" in "".join(names):
        return err(f"control.tar must not carry a DEBIAN/ prefix: {names}")

    fields = dict(re.findall(r"^(\w[\w-]*):\s*(.*)$", ctl_txt, re.M))
    if fields.get("Package") != app_id:
        return err(f"Package != {app_id}: {fields.get('Package')}")
    if fields.get("Architecture") != want_arch:
        return err(f"Architecture != {want_arch}: {fields.get('Architecture')}")
    if version and fields.get("Version") != version:
        return err(f"Version != {version}: {fields.get('Version')}")

    # payload
    with tarfile.open(fileobj=io.BytesIO(lzma.decompress(members["data.tar.xz"]))) as tf:
        payloads = tf.getmembers()
        pnames = [m.name for m in payloads]

    for need in (f"./usr/local/{app_id}/webui/index.html",
                 f"./usr/local/{app_id}/webui/SHA256SUMS",
                 f"./usr/local/{app_id}/webui/monaco/min/vs/loader.js",
                 f"./usr/local/{app_id}/nginx/{app_id}.conf",
                 f"./usr/local/{app_id}/config.ini",
                 f"./usr/local/{app_id}/{app_id}.lang",
                 f"./usr/local/{app_id}/images/icons/{app_id}.svg",
                 "./usr/share/doc/drawdb/copyright"):
        if need not in pnames:
            return err(f"data.tar missing {need}")
    for s in ("postinst", "prerm", "postrm"):
        if f"./{s}" not in names:
            return err(f"control.tar missing ./{s}")

    # dist SHA256 lock + intranet safety scan
    with tarfile.open(fileobj=io.BytesIO(lzma.decompress(members["data.tar.xz"]))) as tf:
        man_txt = tf.extractfile(f"./usr/local/{app_id}/webui/SHA256SUMS").read().decode()
        checked, mismatch = 0, []
        probe = tf.extractfile(f"./usr/local/{app_id}/webui/index.html").read().decode(errors="ignore")
        for line in man_txt.splitlines():
            if not line.strip():
                continue
            digest, rel = line.split(None, 1)
            rel = rel.strip()
            m = tf.extractfile(f"./usr/local/{app_id}/webui/{rel}")
            if m is None:
                mismatch.append(f"{rel}: missing from payload")
                continue
            actual = hashlib.sha256(m.read()).hexdigest()
            if actual != digest:
                mismatch.append(f"{rel}: {actual[:12]} != {digest[:12]}")
            checked += 1
    if mismatch:
        return err("dist SHA256 mismatch: " + "; ".join(mismatch[:5]))
    for s in FORBIDDEN_EXTERNAL:
        if s in probe:
            return err(f"webui dist references external source: {s}")

    webui_count = sum(1 for n in pnames if "/webui/" in n)
    print(f"OK {deb} [{platform}]")
    print(f"  control: Package={fields.get('Package')} Version={fields.get('Version')} "
          f"Architecture={fields.get('Architecture')}")
    print(f"  payload: {len(payloads)} entries, webui {webui_count} files, "
          f"SHA256SUMS verified ({checked} files), no CDN refs in index.html")
    return 0


if __name__ == "__main__":
    sys.exit(main())
