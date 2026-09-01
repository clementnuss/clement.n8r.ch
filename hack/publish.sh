#!/usr/bin/env bash
# Publish the Hugo site to the appl-clement-blog PVC in the home k8s cluster.
#
# Usage: ./hack/publish.sh
#
# What it does:
#   1. Builds the site with Hugo (output -> public/)
#   2. tars public/ and pipes it into the running clement-blog pod, replacing
#      the contents of /usr/share/nginx/html (with --delete semantics via tar)
#
# Prereqs:
#   - hugo and git-lfs installed locally (for the build)
#   - kubectl configured with access to the planchettes63 cluster
#   - the appl-clement-blog namespace + Deployment already deployed (via Flux)

set -euo pipefail

NAMESPACE="appl-clement-blog"
DEPLOYMENT="clement-blog"
CONTAINER="nginx"
WEB_ROOT="/usr/share/nginx/html"
BASE_URL="https://clement.n8r.ch/"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Cleaning public/ (removes stale build artifacts, e.g. images that
    are no longer referenced)"
rm -rf "${REPO_ROOT}/public"

echo "==> Building Hugo site (baseURL=${BASE_URL})"
# Ensure Hugo themes/modules are vendored/present (go.mod is used for theme import)
hugo --minify --baseURL "$BASE_URL" -d public

echo "==> Finding a running ${DEPLOYMENT} pod in ${NAMESPACE}"
POD="$(kubectl -n "${NAMESPACE}" get pod -l "app=${DEPLOYMENT}" \
  -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | head -n1)"

if [[ -z "${POD}" ]]; then
  echo "ERROR: no running pod found for app=${DEPLOYMENT} in ns=${NAMESPACE}" >&2
  exit 1
fi
echo "    using pod: ${POD}"

echo "==> Syncing public/ -> ${POD}:${WEB_ROOT}"
# Stream the built site into the container, replacing its web root.
# --no-same-owner: the container runs as UID 101; preserve no host ownership.
# We tar to stdout and untar in the container into a clean staging dir, then
# atomically swap it into place. This avoids serving a half-updated tree.
STAGING="$(kubectl -n "${NAMESPACE}" exec "${POD}" -c "${CONTAINER}" -- mktemp -d)"

tar -C public --no-same-owner -cf - . \
  | kubectl -n "${NAMESPACE}" exec -i "${POD}" -c "${CONTAINER}" -- tar -x -C "${STAGING}" -f -

kubectl -n "${NAMESPACE}" exec "${POD}" -c "${CONTAINER}" -- sh -e -c '
  web_root="$1"; staging="$2"
  rm -rf "${web_root:?}"/* "${web_root:?}"/.[!.]* 2>/dev/null || true
  mv "${staging}"/* "${staging}"/.[!.]* "${web_root}/" 2>/dev/null || true
  rmdir "${staging}"
' -- "${WEB_ROOT}" "${STAGING}"

echo "==> Publish complete. Site: ${BASE_URL}"
echo "    (nginx serves from memory; new content is live immediately)"