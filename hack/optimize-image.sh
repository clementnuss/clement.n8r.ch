#!/usr/bin/env bash
# Shrink an image for static/images/ (targets documented in AGENTS.md).
#
# Usage: ./hack/optimize-image.sh [--text] <image>...
#   default: photo -> JPEG q80, max 1600px wide, metadata stripped (<name>.jpeg)
#   --text:  screenshot -> PNG quantized to 256 colors, max 1600px wide (<name>.png)
#
# The result replaces the original only if it is smaller. Uses ImageMagick,
# falls back to ffmpeg for photos.

set -euo pipefail

mode=photo
if [[ "${1:-}" == "--text" ]]; then
  mode=text
  shift
fi
[[ $# -gt 0 ]] || { sed -n '2,10p' "$0"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
have() { command -v "$1" >/dev/null; }

for in in "$@"; do
  if [[ "${mode}" == text ]]; then out="${in%.*}.png"; else out="${in%.*}.jpeg"; fi
  tmp="$(mktemp --suffix=".${out##*.}")"

  if have magick; then
    if [[ "${mode}" == text ]]; then
      magick "${in}" -auto-orient -resize '1600x>' -strip -colors 256 "${tmp}"
    else
      magick "${in}" -auto-orient -resize '1600x>' -strip -quality 80 "${tmp}"
    fi
  elif have ffmpeg && [[ "${mode}" == photo ]]; then
    # -q:v 3 is roughly ImageMagick's -quality 80; ffmpeg drops metadata by default.
    ffmpeg -loglevel error -y -i "${in}" -vf "scale='min(1600,iw)':-2" -q:v 3 "${tmp}"
  else
    echo "ImageMagick is required (sudo pacman -S imagemagick)" >&2
    rm -f "${tmp}"; exit 1
  fi

  before=$(stat -c%s "${in}"); after=$(stat -c%s "${tmp}")
  if (( after >= before )); then
    echo "${in}: kept original (${before} B, optimized would be ${after} B)"
    rm -f "${tmp}"; continue
  fi

  mv "${tmp}" "${out}"
  chmod 644 "${out}"
  [[ "${out}" != "${in}" ]] && rm "${in}"
  echo "${in} -> ${out}: ${before} B -> ${after} B"

  if [[ "${out}" != "${in}" ]]; then
    old="/${in#*static/}"
    if refs=$(grep -rlF -- "${old}" "${REPO_ROOT}/content"); then
      echo "  update references to ${old} in:"; echo "${refs}" | sed 's/^/    /'
    fi
  fi
done
