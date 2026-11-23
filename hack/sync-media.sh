#!/usr/bin/env bash
# Sync media/ to the S3 bucket served at https://media.n8r.ch/.
#
# Usage: ./hack/sync-media.sh [s5cmd global flags, e.g. --dry-run]

set -euo pipefail

CREDENTIALS="${HOME}/git/github.com/clementnuss/dev-docs/blog/credentials"
ENDPOINT="https://sos-ch-gva-2.exo.io"
BUCKET="s3://media-n8r-ch"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${CREDENTIALS}" ]]; then
  # shellcheck source=/dev/null
  source "${CREDENTIALS}"
fi

# public-read is required: the media.n8r.ch worker fetches objects anonymously,
# and s5cmd uploads private objects by default (-> 403).
s5cmd --endpoint-url "${ENDPOINT}" "$@" \
  sync --acl public-read "${REPO_ROOT}/media/" "${BUCKET}/"
