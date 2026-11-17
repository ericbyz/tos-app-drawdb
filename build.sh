#!/usr/bin/env bash
# ============================================================
# Build TOS deb packages for drawdb (x86_64 + aarch64)
# ============================================================
# Pure static app: both architectures ship the identical webui dist; only
# the control Architecture differs (TOS requires per-arch packages).
#
# Usage:
#   ./build.sh              # build both platforms
#   ./build.sh x86_64       # build one platform
#   ./build.sh aarch64
#
# Prereq: webui/ dist present (./scripts/build_web.sh) — build.sh verifies
# the dist against webui/SHA256SUMS before packing.
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

BUILD_DIR="build"
OUTPUT_DIR="${BUILD_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

# ---- parse UPSTREAM pin ----
declare -A PIN
while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" =~ ^# ]] && continue
    PIN["${key}"]="${value}"
done < UPSTREAM

APP_ID="drawdb"
VERSION="${PIN[UPSTREAM_VERSION]}"
COMMIT="${PIN[UPSTREAM_COMMIT]}"

# ---- keep config.ini version in lockstep with the pin ----
CONFIG_VERSION=$(python3 -c "import json; print(json.load(open('config.ini'))['version'])")
if [[ "${CONFIG_VERSION}" != "${VERSION}" ]]; then
    echo "ERROR: config.ini version (${CONFIG_VERSION}) != UPSTREAM version (${VERSION})" >&2
    echo "  run: ./scripts/bump_upstream.sh <new-version> <new-commit>   # or update config.ini" >&2
    exit 1
fi

# ---- verify the committed dist before packing ----
python3 - <<'PYEOF'
import hashlib, os, sys

if not os.path.exists("webui/index.html") or not os.path.exists("webui/SHA256SUMS"):
    print("ERROR: webui dist missing — run ./scripts/build_web.sh first", file=sys.stderr)
    sys.exit(1)
bad = []
n = 0
for line in open("webui/SHA256SUMS", encoding="utf-8"):
    if not line.strip():
        continue
    digest, rel = line.split(None, 1)
    rel = rel.strip()
    p = os.path.join("webui", rel)
    if not os.path.exists(p):
        bad.append(f"{rel}: missing")
        continue
    if hashlib.sha256(open(p, "rb").read()).hexdigest() != digest:
        bad.append(f"{rel}: sha256 mismatch")
    n += 1
if bad:
    print("ERROR: webui dist does not match SHA256SUMS:", file=sys.stderr)
    for b in bad[:5]:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
print(f"  webui dist verified against SHA256SUMS ({n} files)")
PYEOF

# platform -> dpkg architecture
platform_to_dpkg() {
    case "$1" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "ERROR: unknown platform $1" >&2; exit 1 ;;
    esac
}

build_platform() {
    local platform="$1"
    local dpkg_arch
    dpkg_arch="$(platform_to_dpkg "${platform}")"
    local staging="${BUILD_DIR}/${platform}/staging"

    echo "=== Building ${APP_ID} v${VERSION} for ${platform} (${dpkg_arch}) ==="
    rm -rf "${BUILD_DIR}/${platform}"
    mkdir -p "${staging}/usr/local/${APP_ID}/images/icons" \
             "${staging}/usr/local/${APP_ID}/nginx" \
             "${staging}/usr/share/doc/${APP_ID}" \
             "${staging}/DEBIAN"

    # Debian doc files (copyright/changelog are expected by lintian and by
    # the AGPL-3.0 redistribution obligations — see NOTICE)
    cat > "${staging}/usr/share/doc/${APP_ID}/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: DrawDB
Upstream-Homepage: ${PIN[UPSTREAM_REPO]}
Source: ${PIN[UPSTREAM_REPO]} (commit ${COMMIT})

Files: *
Copyright: $(date +%Y) DrawDB contributors
License: AGPL-3.0-or-later
 The complete text of the AGPL-3.0 license is available upstream at
 https://github.com/drawdb-io/drawdb/blob/${COMMIT}/LICENSE and in the
 LICENSE file of the packaging repository. On Debian systems it can be
 found in /usr/share/common-licenses/AGPL-3.
 The complete corresponding source of the built web application is the
 upstream source tree at the pinned commit above; the build recipe is
 scripts/build_web.sh in this repository (no modifications to upstream
 sources).
EOF
    {
        echo "drawdb (${VERSION}) upstream; urgency=low"
        echo
        echo "  * Built from source ${PIN[UPSTREAM_REPO]} at pinned commit ${COMMIT}"
        echo "    (vite --base=/drawdb/, monaco/fonts/pdfobject bundled locally for"
        echo "    intranet use). Dist SHA256 manifest pinned as webui/SHA256SUMS."
        echo
        echo " -- ericbyz <ericbyz@users.noreply.github.com>  $(date -R)"
    } | gzip -9 > "${staging}/usr/share/doc/${APP_ID}/changelog.gz"

    # application payload (static dist + metadata; no bin/, no services)
    cp -r webui "${staging}/usr/local/${APP_ID}/webui"
    install -m 644 config.ini "${staging}/usr/local/${APP_ID}/config.ini"
    install -m 644 drawdb.lang "${staging}/usr/local/${APP_ID}/drawdb.lang"
    install -m 644 images/icons/drawdb.svg "${staging}/usr/local/${APP_ID}/images/icons/drawdb.svg"
    install -m 644 nginx/drawdb.conf "${staging}/usr/local/${APP_ID}/nginx/drawdb.conf"

    install -m 644 DEBIAN/control "${staging}/DEBIAN/control"
    python3 - "$staging" "${dpkg_arch}" "${platform}" <<'PYEOF'
import json, sys
staging, dpkg_arch, platform = sys.argv[1], sys.argv[2], sys.argv[3]
app_root = f"{staging}/usr/local/drawdb"
cfg = json.load(open(f"{app_root}/config.ini", encoding="utf-8"))
cfg["platform"] = platform
with open(f"{app_root}/config.ini", "w", encoding="utf-8", newline="\n") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
ctl = open(f"{staging}/DEBIAN/control", encoding="utf-8").read()
import re
ctl = re.sub(r"^Architecture:.*$", f"Architecture: {dpkg_arch}", ctl, flags=re.M)
with open(f"{staging}/DEBIAN/control", "w", encoding="utf-8", newline="\n") as f:
    f.write(ctl)
print(f"  config.ini platform={platform}, control Architecture={dpkg_arch}")
PYEOF

    # maintainer scripts
    for s in postinst prerm postrm; do
        install -m 755 "DEBIAN/${s}" "${staging}/DEBIAN/${s}"
    done

    # ---- pack ----
    local out="${OUTPUT_DIR}/${APP_ID}_${platform}.deb"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb --build --root-owner-group "${staging}" "${out}"
    else
        python3 scripts/build_deb.py --staging "${staging}" --output "${out}"
    fi
    (cd "${OUTPUT_DIR}" && sha256sum "$(basename "${out}")" > "$(basename "${out}").sha256")

    # ---- unpack + verify ----
    python3 scripts/unpack_check.py "${out}" "${platform}" "${VERSION}"
    echo "=== done: ${out}"
}

PLATFORMS=("$@")
[[ ${#PLATFORMS[@]} -eq 0 ]] && PLATFORMS=(x86_64 aarch64)
for p in "${PLATFORMS[@]}"; do
    build_platform "${p}"
done

echo
echo "=== Artifacts ==="
ls -lh "${OUTPUT_DIR}"
