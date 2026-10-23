#!/bin/bash
# Fail (exit 1) if ops/rebuild/ contains anything key-shaped. Placeholders like ${REDIS_PASSWORD} are
# (and docker image `sha256:<64 hex>` digests, which are public) removed before matching, so a clean tree prints nothing and exits 0.
# Patterns: sk- keys, Twilio SID (AC + 32 hex), `secret`/`password`/`token` followed by a literal value,
# `password=`, 32+ hex runs, JWTs, long base64-looking runs.
set -u
DIR="${1:-$(dirname "$0")}"
hits=$(grep -rIn --exclude=scan_secrets.sh --exclude=pip-freeze-venv.txt -E '.' "$DIR" \
  | sed -E 's/\$\{[A-Z0-9_]+\}//g; s/sha256:[0-9a-f]{64}//g' \
  | grep -E -i \
    -e 'sk-[A-Za-z0-9_-]{8,}' \
    -e 'AC[0-9a-f]{32}' \
    -e '(secret|passw(or)?d|token|api_?key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'$]' \
    -e 'password=' \
    -e '[0-9a-f]{32,}' \
    -e 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.' \
    -e '[A-Za-z0-9+/]{40,}={0,2}' || true)
[ -z "$hits" ] || { echo "$hits"; exit 1; }
