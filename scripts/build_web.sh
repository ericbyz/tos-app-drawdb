#!/usr/bin/env bash
# ============================================================
# Build the DrawDB SPA dist for TOS (reproducible).
# ============================================================
# - downloads upstream source tarball at the commit pinned in UPSTREAM
#   (via gh api — the codeload channel survives flaky github.com routes)
# - applies ONE declared packaging patch: BrowserRouter -> HashRouter
#   (upstream hosts at a domain root with no basename; under /drawdb/
#   every BrowserRouter route would 404 — see NOTICE)
# - npm ci + vite build with --base=/drawdb/ (CLI override, sources
#   otherwise unmodified)
# - post-processes the dist for intranet use: bundles monaco editor,
#   pdfobject, bootstrap-icons + font-awesome CSS/fonts locally and
#   rewrites the runtime CDN URLs in the built JS
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
if [[ -z "${NODE_BIN}" ]]; then
    NODE_BIN="${CACHE}/node-v${NODE_VERSION}-win-x64/node.exe"
fi
NODE_MAJOR=$("${NODE_BIN}" -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
    PORTABLE="${CACHE}/node-v${NODE_VERSION}-win-x64"
    if [[ ! -x "${PORTABLE}/node.exe" ]]; then
        echo "== fetching portable node v${NODE_VERSION} (build toolchain only)"
        curl -fsSL --retry 3 -o "${CACHE}/node22.zip" "${NODE_DIST_URL}/v${NODE_VERSION}/node-v${NODE_VERSION}-win-x64.zip"
        mkdir -p "${CACHE}/node22x"
        WIN_ZIP=$(cygpath -w "${CACHE}/node22.zip")
        WIN_OUT=$(cygpath -w "${CACHE}/node22x")
        python3 -c "import zipfile; zipfile.ZipFile(r'$WIN_ZIP').extractall(r'$WIN_OUT')"
        rm -rf "${PORTABLE}"; mv "${CACHE}/node22x/node-v${NODE_VERSION}-win-x64" "${PORTABLE}"
    fi
    NODE_BIN="${PORTABLE}/node.exe"
fi
# portable node ships its own npm — invoke its cli via NODE_BIN so the build
# never mixes runtimes (system npm would fetch linux-only native bindings)
NPM_CLI="$(dirname "${NODE_BIN}")/node_modules/npm/bin/npm-cli.js"
if [[ ! -f "${NPM_CLI}" ]]; then
    NPM_CLI="$(command -v npm || echo npm)"
fi
echo "== node: $(${NODE_BIN} --version) | npm-cli: ${NPM_CLI}"

# ---- fetch / verify upstream source at the pinned commit ----
mkdir -p "${CACHE}"
TARBALL="${CACHE}/drawdb-${COMMIT}.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
    echo "== downloading source tarball ${REPO} @ ${COMMIT}"
    gh api "repos/${REPO#https://github.com/}/tarball/${COMMIT}" > "${TARBALL}"
fi
if [[ ! -f "${SRC}/package.json" || ! -f "${SRC}/src/App.jsx" ]] || ! grep -q '"name"' "${SRC}/package.json"; then
    echo "== extracting source"
    rm -rf "${SRC}"
    mkdir -p "${SRC}"
    tar -xzf "${TARBALL}" -C "${SRC}" --strip-components=1
fi
grep -q '"name"' "${SRC}/package.json" || { echo "ERROR: bad source tree" >&2; exit 1; }

# ---- TOS packaging patch (declared in NOTICE): HashRouter for sub-path ----
# DrawDB uses BrowserRouter with no basename; under /drawdb/ every route
# would hit the NotFound page. One-line import swap to HashRouter resolves
# all routes under the app sub-path (URL /drawdb/#/editor). No other change.
APP_PATCH="${SRC}/src/App.jsx"
if ! grep -q "HashRouter as BrowserRouter" "${APP_PATCH}"; then
    echo "== applying HashRouter patch (TOS packaging)"
    python3 - "${APP_PATCH}" <<'PATCHPY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
src = src.replace(
    'import { BrowserRouter, Routes, Route, useLocation } from "react-router-dom";',
    'import { HashRouter as BrowserRouter, Routes, Route, useLocation } from "react-router-dom";')
open(p, "w", encoding="utf-8", newline="\n").write(src)
print("  patched: HashRouter as BrowserRouter")
PATCHPY
fi
grep -q "HashRouter as BrowserRouter" "${APP_PATCH}" || { echo "ERROR: HashRouter patch failed" >&2; exit 1; }

# ---- dependencies ----
if [[ "${1:-}" != "--no-install" ]]; then
    echo "== npm ci (node ${NODE_VERSION})"
    (cd "${SRC}" && rm -rf node_modules && "${NODE_BIN}" "${NPM_CLI}" ci --no-audit --no-fund)
    # rolldown native binding: npm optional-deps bug can skip the win32 package
    (cd "${SRC}" && "${NODE_BIN}" "${NPM_CLI}" install @rolldown/binding-win32-x64-msvc --no-save --no-audit --no-fund >/dev/null 2>&1 || true)
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
(cd "${DIST}" && BASE="${BASE}" python3 - <<'ENDPY'
import glob, os, sys, urllib.request

dist = os.getcwd()
base = os.environ["BASE"].rstrip("/") + "/"

MONACO = "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs"
PDFOBJECT = "https://cdnjs.cloudflare.com/ajax/libs/pdfobject/2.1.1/pdfobject.min.js"
BI_CSS = "https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"
FA_CSS = "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css"

def fetch(url, out, tries=4):
    if os.path.exists(out) and os.path.getsize(out) > 0:
        return
    d = os.path.dirname(out)
    if d:
        os.makedirs(d, exist_ok=True)
    import time
    req = urllib.request.Request(url, headers={"User-Agent": "tos-app-drawdb/1.0"})
    last = None
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=90) as r, open(out, "wb") as f:
                f.write(r.read())
            return
        except Exception as e:
            last = e
            time.sleep(3 * (attempt + 1))
    raise SystemExit(f"ERROR: download failed after {tries} tries: {url} ({last})")

os.makedirs("assets/vendor", exist_ok=True)
os.makedirs("assets/fonts/bootstrap-icons", exist_ok=True)
os.makedirs("assets/fonts/webfonts", exist_ok=True)
os.makedirs("monaco", exist_ok=True)

# monaco editor (npm tarball; ~18MB, holds min/vs)
if not os.path.exists("monaco/min/vs/loader.js"):
    tgz = "monaco.tgz"
    fetch("https://registry.npmjs.org/monaco-editor/-/monaco-editor-0.52.2.tgz", tgz)
    import tarfile
    with tarfile.open(tgz) as tf:
        for m in tf.getmembers():
            if m.name.startswith("package/min/") and m.isfile():
                rel = os.path.relpath(m.name, "package")
                out = os.path.join("monaco", rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with tf.extractfile(m) as f, open(out, "wb") as g:
                    g.write(f.read())
    os.remove(tgz)
assert os.path.exists("monaco/min/vs/loader.js"), "monaco min/vs missing"

fetch(PDFOBJECT, "assets/vendor/pdfobject.min.js")
fetch(BI_CSS, "assets/vendor/bootstrap-icons.css")
for f in ("bootstrap-icons.woff2", "bootstrap-icons.woff"):
    fetch(f"https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/fonts/{f}",
          f"assets/fonts/bootstrap-icons/{f}")
fetch(FA_CSS, "assets/vendor/font-awesome.css")
for f in ("fa-brands-400", "fa-regular-400", "fa-solid-900", "fa-v4compatibility"):
    fetch(f"https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/webfonts/{f}.woff2",
          f"assets/fonts/webfonts/{f}.woff2")

p = "assets/vendor/bootstrap-icons.css"
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8", newline="\n").write(s.replace("./fonts/", "../fonts/bootstrap-icons/"))
p = "assets/vendor/font-awesome.css"
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8", newline="\n").write(s.replace("../webfonts/", "../fonts/webfonts/"))

def patch(p):
    s = open(p, encoding="utf-8", errors="ignore").read()
    orig = s
    s = s.replace(BI_CSS, f"{base}assets/vendor/bootstrap-icons.css")
    s = s.replace(FA_CSS, f"{base}assets/vendor/font-awesome.css")
    s = s.replace(MONACO, f"{base}monaco/min/vs")
    s = s.replace(PDFOBJECT, f"{base}assets/vendor/pdfobject.min.js")
    if s != orig:
        open(p, "w", encoding="utf-8", newline="\n").write(s)

patch("index.html")
for p in glob.glob("assets/*.js") + glob.glob("assets/*.css"):
    patch(p)
print("  vendors bundled and urls localized")
ENDPY
)

# ---- verify: no external asset sources left ----
echo "== verifying dist"
(cd "${DIST}" && BASE="${BASE}" python3 - <<'ENDPY'
import glob, os, re, sys

base = os.environ["BASE"].rstrip("/") + "/"

FORBIDDEN = [
    "cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com",
    "fonts.googleapis.com", "fonts.gstatic.com",
]

haystack = open("index.html", encoding="utf-8").read()
for p in glob.glob("assets/*.css"):
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

html_text = open("index.html", encoding="utf-8").read()
for attr, url in re.findall(r'((?:src|href))="(/[^"]+)"', html_text):
    if not url.startswith(base):
        if url not in ("/config.js", "/robots.txt"):
            raise SystemExit(f"ERROR: index.html {attr}={url!r} outside {base}")

if not os.path.exists("monaco/min/vs/loader.js"):
    raise SystemExit("ERROR: bundled monaco missing")
if not os.path.exists("assets/vendor/pdfobject.min.js"):
    raise SystemExit("ERROR: bundled pdfobject missing")
fonts = sum(len(fs) for _, _, fs in os.walk("assets/fonts"))
if fonts < 6:
    raise SystemExit("ERROR: bundled icon fonts incomplete")
app_src = open("../src/App.jsx", encoding="utf-8").read()
if "HashRouter as BrowserRouter" not in app_src:
    raise SystemExit("ERROR: HashRouter patch missing in source")
print("  dist verified: localized, drive-path free, vendors bundled")
ENDPY
)

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
