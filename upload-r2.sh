#!/usr/bin/env bash
# Publish Hopper's release binaries to Cloudflare R2 (so the Vercel site can link public,
# zero-egress download URLs while the code repo stays private).
#
# It pulls the 4 binaries from your private GitHub release, then uploads them to R2 via the
# S3 API with correct content-types + long cache (filenames are version-stamped, so immutable).
#
# ── Prereqs ──────────────────────────────────────────────────────────────────
#   • gh        (authenticated — to download from the private release)
#   • awscli    (R2 is S3-compatible)        brew install awscli
#
# ── One-time R2 setup ────────────────────────────────────────────────────────
#   1. Cloudflare dashboard → R2 → Create bucket  (e.g. "hopper-downloads")
#   2. Bucket → Settings → enable Public access (gives a https://pub-XXXX.r2.dev URL),
#      or attach a custom domain (e.g. downloads.yoursite.com).
#   3. R2 → Manage API Tokens → create a token → note the Access Key ID + Secret.
#   4. Put that public URL into index.html → DL_BASE.
#
# ── Run ──────────────────────────────────────────────────────────────────────
#   export R2_ACCOUNT_ID=xxxxxxxxxxxxxxxx           # R2 dashboard (top-right "Account ID")
#   export R2_ACCESS_KEY_ID=xxxxxxxx
#   export R2_SECRET_ACCESS_KEY=xxxxxxxx
#   export R2_BUCKET=hopper-downloads
#   ./upload-r2.sh                                   # defaults to v0.1.1
#   ./upload-r2.sh v0.1.2                            # a later release
#
# (rclone alternative — if you prefer it: configure an `r2` remote, then
#   rclone copy "$tmp" r2:$R2_BUCKET --header-upload "Cache-Control: public, max-age=31536000, immutable" )
set -euo pipefail

VER="${1:-v0.1.1}"
GH_REPO="${GH_REPO:-leonardovilla99/Hopper}"   # the release lives in the code repo, not this folder
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"
: "${R2_BUCKET:?set R2_BUCKET}"

command -v gh  >/dev/null || { echo "gh CLI required";  exit 1; }
command -v aws >/dev/null || { echo "awscli required (brew install awscli)"; exit 1; }

endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "Pulling $VER binaries from ${GH_REPO} ..."
gh release download "$VER" --repo "$GH_REPO" -D "$tmp" -p '*.dmg' -p '*.exe' -p '*.AppImage' -p '*.deb'

ctype() {
  case "$1" in
    *.dmg)      echo "application/x-apple-diskimage" ;;
    *.exe)      echo "application/vnd.microsoft.portable-executable" ;;
    *.AppImage) echo "application/x-appimage" ;;
    *.deb)      echo "application/vnd.debian.binary-package" ;;
    *)          echo "application/octet-stream" ;;
  esac
}

echo "▶ uploading to r2://$R2_BUCKET …"
for f in "$tmp"/*; do
  name="$(basename "$f")"
  aws s3 cp "$f" "s3://$R2_BUCKET/$name" \
    --endpoint-url "$endpoint" \
    --content-type "$(ctype "$name")" \
    --cache-control "public, max-age=31536000, immutable"
  echo "   ✓ $name"
done

echo
echo "✓ done. Confirm the bucket is public and that DL_BASE in index.html matches that URL, e.g.:"
echo "    var DL_BASE = \"https://pub-XXXX.r2.dev\";   (or your custom domain)"
