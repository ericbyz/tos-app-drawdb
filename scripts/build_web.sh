#!/usr/bin/env bash
# ============================================================
# Build the DrawDB SPA dist for TOS (reproducible).
# ============================================================
# - downloads upstream source tarball at the commit pinned in UPSTREAM
#   (via gh api — the codeload channel survives flaky github.com routes)
# - npm ci + vite build with --base=/drawdb/ (upstream sources stay
#   unmodified; base is a CLI override)
# - post-processes the dist for intranet use:
#     * bundles monaco editor, pdfobject, bootstrap-icons + font-awesome
#       CSS/fonts locally; rewrites the runtime CDN URLs in the built JS
# - verifies no external asset URLs remain, emits webui/SHA256SUMS and
#   publishes dist -> repo webui/
#
# Requires: gh CLI (tarball channel), node >= 20.12 (see UPSTREAM
# NODE_VERSION — a portable node22 tree works without system install),
# bash, python3.
# Usage: ./scripts/build_web.sh [--no-install]
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CACHE="${REPO_ROOT}/.upstream-cache"
SRC="${CACHE}/drawdb-src"
WEBUI="${REPO_ROOT}/webui"

# Git Bash (MSYS) would rewrite the leading-slash vite --base argument into a
# Windows drive path. Exclude only --base args from conversion.
export MSYS2_ARG_CONV_EXCL="--base"
export MSYS2_ENV_CONV_EXCL="BASE"

# ---- parse UPSTREAM pin ----
declare -A PIN
while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" =~ ^# ]] && continue
    PIN["${key}"]="${value}"
done < UPSTREAM

REPO="${PIN[UPSTREAM_REPO]:?UPSTREAM_REPO missing}"
COMMIT="${PIN[UPSTREAM_COMMIT]:?UPSTREAM_COMMIT missing}"
BASE="${PIN[VITE_BASE]:?VITE_BASE missing}"
NODE_DIST_URL="${PIN[NODE_DIST_URL]:-https://nodejs.org/dist}"
NODE_VERSION="${PIN[NODE_VERSION]:-22.20.0}"

# ---- resolve a node >= 20 runtime (portable tree preferred, no install) ----
NODE_BIN="$(command -v node || true)"
NODE_MAJOR=0
[[ -n "${NODE_BIN}" ]] && NODE_MAJOR=$("${NODE_BIN}" -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
    PORTABLE="${CACHE}/node-v${NODE_VERSION}-win-x64"
    if [[ ! -x "${PORTABLE}/node.exe" ]]; then
        echo "== fetching portable node v${NODE_VERSION} (build toolchain only)"
        curl -fsSL --retry 3 -o "${CACHE}/node22.zip" "${NODE_DIST_URL}/v${NODE_VERSION}/node-v${NODE_VERSION}-win-x64.zip"
        mkdir -p "${CACHE}/node22x"
        (cd "${CACHE}/node22x" && python3 -c "
import zipfile
zipfile.ZipFile('${CACHE}/node22.zip').extractall('${CACHE}/node22x')
")
        rm -rf "${PORTABLE}"; mv "${CACHE}/node22x/node-v${NODE_VERSION}-win-x64" "${PORTABLE}"
    fi
    NODE_BIN="${PORTABLE}/node.exe"
fi
echo "== node: $(${NODE_BIN} --version)"

# ---- fetch / verify upstream source at the pinned commit ----
mkdir -p "${CACHE}"
TARBALL="${CACHE}/drawdb-${COMMIT}.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
    echo "== downloading source tarball ${REPO} @ ${COMMIT}"
    gh api "repos/${REPO#https://github.com/}/tarball/${COMMIT}" > "${TARBALL}"
fi
if [[ ! -f "${SRC}/package.json" ]] || ! grep -q '"name"' "${SRC}/package.json"; then
    echo "== extracting source"
    rm -rf "${SRC}"
    mkdir -p "${SRC}"
    tar -xzf "${TARBALL}" -C "${SRC}" --strip-components=1
fi
grep -q '"name"' "${SRC}/package.json" || { echo "ERROR: bad source tree" >&2; exit 1; }

# ---- dependencies ----
if [[ "${1:-}" != "--no-install" ]]; then
    echo "== npm ci (node ${NODE_VERSION})"
    (cd "${SRC}" && rm -rf node_modules && "${NODE_BIN}" ./node_modules/npm/bin/npm-cli.js ci --no-audit --no-fund 2>/dev/null) \
      || (cd "${SRC}" && npm ci --no-audit --no-fund)
fi

# ---- vite build (base overridden via CLI, upstream config untouched) ----
echo "== vite build --base=${BASE}"
(
    cd "${SRC}"
    VITE_APP_DISABLE_SENTRY=true "${NODE_BIN}" node_modules/vite/bin/vite.js build --base="${BASE}"
)

DIST="${SRC}/dist"
[[ -f "${DIST}/index.html" ]] || { echo "ERROR: ${DIST}/index.html missing" >&2; exit 1; }

# ---- bundle runtime vendors (monaco / pdfobject / icon fonts) ----
echo "== bundling runtime vendors (monaco, pdfobject, icon fonts)"
BASE="${BASE}" python3 - "${DIST}" <<'ENDPY'
import glob, os, sys, urllib.request

dist = sys.argv[1]
base = os.environ["BASE"].rstrip("/") + "/"

MONACO = "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs"
PDFOBJECT = "https://cdnjs.cloudflare.com/ajax/libs/pdfobject/2.1.1/pdfobject.min.js"
BI_CSS = "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"
FA_CSS = "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css"

def fetch(url, out):
    if os.path.exists(out) and os.path.getsize(out) > 0:
        return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "tos-app-drawdb/1.0"})
    with urllib.request.urlopen(req, timeout=90) as r, open(out, "wb") as f:
        f.write(r.read())

os.makedirs(f"{dist}/assets/vendor", exist_ok=True)
os.makedirs(f"{dist}/assets/fonts/bootstrap-icons", exist_ok=True)
os.makedirs(f"{dist}/assets/fonts/webfonts", exist_ok=True)
os.makedirs(f"{dist}/monaco", exist_ok=True)

# monaco editor (npm tarball; ~18MB, holds min/vs)
if not os.path.exists(f"{dist}/monaco/min/vs/loader.js"):
    tgz = f"{dist}/monaco.tgz"
    fetch("https://registry.npmjs.org/monaco-editor/-/monaco-editor-0.52.2.tgz", tgz)
    import tarfile
    with tarfile.open(tgz) as tf:
        for m in tf.getmembers():
            if m.name.startswith("package/min/"):
                tf.extract(m, f"{dist}/monaco", filter="data")
    os.remove(tgz)
assert os.path.exists(f"{dist}/monaco/min/vs/loader.js"), "monaco min/vs missing"

# pdfobject
fetch(PDFOBJECT, f"{dist}/assets/vendor/pdfobject.min.js")

# icon fonts (css + woff/woff2)
fetch(BI_CSS, f"{dist}/assets/vendor/bootstrap-icons.css")
for f in ("bootstrap-icons.woff2", "bootstrap-icons.woff"):
    fetch(f"https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/fonts/{f}",
          f"{dist}/assets/fonts/bootstrap-icons/{f}")
fetch(FA_CSS, f"{dist}/assets/vendor/font-awesome.css")
for f in ("fa-brands-400", "fa-regular-400", "fa-solid-900", "fa-v4compatibility"):
    fetch(f"https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/webfonts/{f}.woff2",
          f"{dist}/assets/fonts/webfonts/{f}.woff2")

# rewrite css-internal font urls to the bundled files
p = f"{dist}/assets/vendor/bootstrap-icons.css"
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8", newline="\n").write(s.replace("./fonts/", "../fonts/bootstrap-icons/"))
p = f"{dist}/assets/vendor/font-awesome.css"
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8", newline="\n").write(s.replace("../webfonts/", "../fonts/webfonts/"))

# patch html + runtime JS: CDN urls -> local paths
def patch(p):
    s = open(p, encoding="utf-8", errors="ignore").read()
    orig = s
    s = s.replace(BI_CSS, f"{base}assets/vendor/bootstrap-icons.css")
    s = s.replace(FA_CSS, f"{base}assets/vendor/font-awesome.css")
    s = s.replace(MONACO, f"{base}monaco/min/vs")
    s = s.replace(PDFOBJECT, f"{base}assets/vendor/pdfobject.min.js")
    if s != orig:
        open(p, "w", encoding="utf-8", newline="\n").write(s)

patch(f"{dist}/index.html")
for p in glob.glob(f"{dist}/assets/*.js") + glob.glob(f"{dist}/assets/*.css"):
    patch(p)
print("  vendors bundled and urls localized")
ENDPY

# ---- verify: no external asset sources left ----
echo "== verifying dist"
BASE="${BASE}" python3 - "${DIST}" <<'ENDPY'
import glob, os, re, sys

dist = sys.argv[1]
base = os.environ["BASE"].rstrip("/") + "/"

FORBIDDEN = [
    "cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com",
    "fonts.googleapis.com", "fonts.gstatic.com",
]

haystack = open(os.path.join(dist, "index.html"), encoding="utf-8").read()
for p in glob.glob(os.path.join(dist, "assets", "*.css")):
    haystack += open(p, encoding="utf-8", errors="ignore").read()
for s in FORBIDDEN:
    if s in haystack:
        raise SystemExit(f"ERROR: external CDN reference remains in dist: {s}")

def assert_no_drive_path(text, what):
    scan = re.sub(r"https?://[^\s\"'<>)]+", "", text)
    scan = re.sub(r"data:[^\"')\s]+", "", scan)
    m = re.search(r"[A-Za-z]:[/\\][A-Za-z0-9_.~-]+[/\\]", scan)
    if m:
        i = m.start()
        raise SystemExit(f"ERROR: Windows drive path leaked into {what}: "
                         f"...{scan[max(0, i-40):i+20]}...")

assert_no_drive_path(haystack, "dist html/css")

html_text = open(os.path.join(dist, "index.html"), encoding="utf-8").read()
for attr, url in re.findall(r'((?:src|href))="(/[^"]+)"', html_text):
    if not url.startswith(base):
        if url not in ("/config.js", "/robots.txt"):
            raise SystemExit(f"ERROR: index.html {attr}={url!r} outside {base}")

if not os.path.exists(os.path.join(dist, "monaco", "min", "vs", "loader.js")):
    raise SystemExit("ERROR: bundled monaco missing")
if not os.path.exists(os.path.join(dist, "assets", "vendor", "pdfobject.min.js")):
    raise SystemExit("ERROR: bundled pdfobject missing")
fonts = sum(len(fs) for _, _, fs in os.walk(os.path.join(dist, "assets", "fonts")))
if fonts < 6:
    raise SystemExit("ERROR: bundled icon fonts incomplete")
print("  dist verified: localized, drive-path free, vendors bundled")
ENDPY

# ---- publish dist -> repo webui/ with SHA256 manifest ----
echo "== publishing dist -> webui/"
rm -rf "${WEBUI}"
mkdir -p "${WEBUI}"
(cd "${DIST}" && tar -cf - .) | (cd "${WEBUI}" && tar -xf -)
(cd "${WEBUI}" && python3 - <<'ENDPY'
import hashlib, os

lines = []
for cur, dirs, files in os.walk("."):
    dirs.sort()
    for f in sorted(files):
        p = os.path.join(cur, f)
        if os.path.normpath(p) == os.path.normpath("./SHA256SUMS"):
            continue
        h = hashlib.sha256(open(p, "rb").read()).hexdigest()
        lines.append(f"{h}  {os.path.relpath(p, '.').replace(os.sep, '/')}")
open("SHA256SUMS", "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
print(f"  SHA256SUMS: {len(lines)} files")
ENDPY
)

COUNT=$(find "${WEBUI}" -type f | wc -l)
SIZE=$(du -sh "${WEBUI}" | cut -f1)
echo "=== done: webui/ (${COUNT} files, ${SIZE})"
