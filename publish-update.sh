#!/usr/bin/env bash
# Publish a SIGNED auto-update to R2 (under updates/), so existing Hopper installs can update
# in place. It collects each platform's updater artifact + its .sig signature, writes latest.json
# (the manifest the app fetches), and uploads everything.
#
# Prereqs:
#   - gh, awscli
#   - a SIGNED build: build Hopper with TAURI_SIGNING_PRIVATE_KEY set so the bundler emits the
#     updater artifacts (.app.tar.gz / .AppImage / -setup.exe) each with a matching .sig.
#     (build-all.sh auto-exports the key from ~/.tauri/hopper.key if present.)
#
# Where artifacts come from:
#   - macOS  : local universal build at $HOPPER_DIR/src-tauri/target/universal-apple-darwin/.../macos/
#   - Win/Lin: the GitHub release  $GH_REPO @ v<version>  (CI builds them; .sig uploaded as assets)
#
# Usage:
#   export R2_ACCOUNT_ID=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… R2_BUCKET=hopper-downloads
#   ./publish-update.sh 0.1.2 "What changed in this release"
set -euo pipefail

VER="${1:?usage: publish-update.sh <version> [notes]   e.g. 0.1.2}"
NOTES="${2:-Bug fixes and improvements.}"
PUB_BASE="${PUB_BASE:-https://pub-82a3472bb4564b52a20cb1bafb7e3e5f.r2.dev}"   # R2 public URL (match index.html DL_BASE)
GH_REPO="${GH_REPO:-leonardovilla99/Hopper}"
HOPPER_DIR="${HOPPER_DIR:-$HOME/Documents/Project/Hopper}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" "${R2_BUCKET:?}"
command -v gh     >/dev/null || { echo "gh required"; exit 1; }
command -v aws    >/dev/null || { echo "awscli required"; exit 1; }
command -v python3>/dev/null || { echo "python3 required"; exit 1; }

endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
shopt -s nullglob

echo "Collecting signed updater artifacts for v$VER ..."
# macOS (local signed build)
macdir="$HOPPER_DIR/src-tauri/target/universal-apple-darwin/release/bundle/macos"
for f in "$macdir"/*.app.tar.gz "$macdir"/*.app.tar.gz.sig; do [ -f "$f" ] && cp "$f" "$stage/"; done
# Windows + Linux (from the GitHub release built by CI)
gh release download "v$VER" --repo "$GH_REPO" -D "$stage" \
  -p '*.AppImage' -p '*.AppImage.sig' -p '*-setup.exe' -p '*-setup.exe.sig' \
  -p '*.nsis.zip' -p '*.nsis.zip.sig' 2>/dev/null || true

# build latest.json from every *.sig present (robust JSON via python) -------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$stage" "$VER" "$NOTES" "$ts" "$PUB_BASE" > "$stage/latest.json" <<'PY'
import json, os, sys, glob
stage, ver, notes, ts, pub = sys.argv[1:6]
plats = {}
def add(key, art):
    with open(os.path.join(stage, art + ".sig")) as f:
        plats[key] = {"signature": f.read().strip(), "url": f"{pub}/updates/{art}"}
for sig in glob.glob(os.path.join(stage, "*.sig")):
    art = os.path.basename(sig)[:-4]
    if art.endswith(".app.tar.gz"):
        add("darwin-aarch64", art); add("darwin-x86_64", art)   # universal → both arch keys
    elif art.endswith(".AppImage"):
        add("linux-x86_64", art)
    elif art.endswith("-setup.exe") or art.endswith(".nsis.zip"):
        add("windows-x86_64", art)
if not plats:
    sys.stderr.write("No signed artifacts (.sig) found — build with TAURI_SIGNING_PRIVATE_KEY set.\n")
    sys.exit(1)
json.dump({"version": ver, "notes": notes, "pub_date": ts, "platforms": plats}, sys.stdout, indent=2)
PY

echo "Manifest:"; cat "$stage/latest.json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("  v%s -> %s"%(d["version"], ", ".join(d["platforms"])))'

# upload artifacts + manifest (sigs are inlined into latest.json, not uploaded) ----
echo "Uploading to r2://$R2_BUCKET/updates/ ..."
for f in "$stage"/*; do
  name="$(basename "$f")"
  case "$name" in *.sig) continue ;; esac
  if [ "$name" = "latest.json" ]; then ct="application/json"; cc="public, max-age=60"      # manifest: short cache
  else                                  ct="application/octet-stream"; cc="public, max-age=31536000, immutable"; fi
  aws s3 cp "$f" "s3://$R2_BUCKET/updates/$name" --endpoint-url "$endpoint" --content-type "$ct" --cache-control "$cc"
  echo "  ok $name"
done
echo "Done. Installs will see v$VER on their next launch check (or via 'Check for Updates...')."
