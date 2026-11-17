#!/usr/bin/env bash
# Bump the pinned upstream version: UPSTREAM + config.ini + control in lockstep.
# Usage: ./scripts/bump_upstream.sh <version> <commit>
# After bumping: run scripts/build_web.sh (rebuild dist + SHA256SUMS),
# then ./build.sh && ./scripts/validate.py
set -euo pipefail

NEW_VERSION="${1:?usage: bump_upstream.sh <version> <commit>}"
NEW_COMMIT="${2:?usage: bump_upstream.sh <version> <commit>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

sed -i "s/^UPSTREAM_TAG=.*/UPSTREAM_TAG=v${NEW_VERSION}/" UPSTREAM
sed -i "s/^UPSTREAM_VERSION=.*/UPSTREAM_VERSION=${NEW_VERSION}/" UPSTREAM
sed -i "s/^UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=${NEW_COMMIT}/" UPSTREAM

python3 - "$NEW_VERSION" <<'PYEOF'
import json, sys
cfg = json.load(open("config.ini", encoding="utf-8"))
cfg["version"] = sys.argv[1]
with open("config.ini", "w", encoding="utf-8", newline="\n") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF

sed -i "s/^Version:.*/Version: ${NEW_VERSION}/" DEBIAN/control

echo "bumped to ${NEW_VERSION} (commit ${NEW_COMMIT})"
echo "NEXT STEPS:"
echo "  1. ./scripts/build_web.sh          # rebuild dist at the new pin + SHA256SUMS"
echo "  2. review the webui/ diff for new external CDN references"
echo "  3. ./build.sh && ./scripts/validate.py"
echo "  4. commit, tag v${NEW_VERSION} and push to trigger CI"
