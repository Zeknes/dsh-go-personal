#!/usr/bin/env bash
# The numbers (docs/design/share-links.md §15), read from Workers Analytics
# Engine's SQL API with an API token. There is no public endpoint for them.
#
#   CF_TOKEN_FILE=<file> scripts/stats.sh              the last 14 days (UTC+8)
#   CF_TOKEN_FILE=<file> scripts/stats.sh --days 30
#   scripts/stats.sh --dry-run                         print the SQL, send nothing
#
# Report (scripts/stats-report.py):
#   downloads        button clicks per day, by route and version; people = distinct
#                    daily device codes; countries
#   update checks    near-daily-active: distinct daily device codes of apps that
#                    checked /beta/update.json (channel-token builds only; one
#                    code per IP + browser, so it undercounts behind NAT)
# The token needs Account → Account Analytics → Read. It's only read from
# CF_TOKEN_FILE and only sent to the API; never printed.
#   CF_API_BASE   default https://api.cloudflare.com/client/v4 (tests point it elsewhere)
#   STATS_TODAY   YYYY-MM-DD; default today in UTC+8 (tests)
set -euo pipefail

usage() { echo "usage: CF_TOKEN_FILE=<file> $0 [--days N] [--dry-run]" >&2; exit 2; }
DAYS=14
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) [[ "${2:-}" =~ ^[1-9][0-9]?$ ]] || usage; DAYS=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done

cd "$(dirname "$0")/.."
die() { echo "stats: $*" >&2; exit 1; }
API=${CF_API_BASE:-https://api.cloudflare.com/client/v4}
# The public tree's wrangler.jsonc has a placeholder account (tooling/oss-redact.txt).
source scripts/cloudflare.sh
real_id "$ACCOUNT" || die "no Cloudflare account id: set CF_ACCOUNT_ID or write it to $ACCOUNT_FILE"
if [[ $DRY == 0 ]]; then
  [[ -r "${CF_TOKEN_FILE:-}" && -s "${CF_TOKEN_FILE:-}" ]] || die "set CF_TOKEN_FILE to a token that can read Account Analytics"
  command -v curl >/dev/null && command -v python3 >/dev/null || die "needs curl and python3"
fi

# Points are filtered by when they arrived (one day of slack for UTC+8); the
# report keeps the days it asks for.
SPAN=$((DAYS + 1))
downloads_sql="SELECT blob1 AS day, blob2 AS route, blob3 AS version, blob4 AS country, blob5 AS device,
  SUM(_sample_interval) AS n
FROM dshgo_downloads
WHERE timestamp > NOW() - INTERVAL '$SPAN' DAY
GROUP BY day, route, version, country, device
FORMAT JSON"
checks_sql="SELECT blob1 AS day, blob2 AS device, blob3 AS app, blob4 AS abi,
  SUM(_sample_interval) AS n
FROM dshgo_checks
WHERE timestamp > NOW() - INTERVAL '$SPAN' DAY
GROUP BY day, device, app, abi
FORMAT JSON"
if [[ $DRY == 1 ]]; then
  echo "dry run: POST $API/accounts/$ACCOUNT/analytics_engine/sql (Authorization from CF_TOKEN_FILE), one query each:"
  printf '\n-- downloads\n%s\n\n-- checks\n%s\n' "$downloads_sql" "$checks_sql"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for name in downloads checks; do
  if [[ $name == downloads ]]; then sql=$downloads_sql; else sql=$checks_sql; fi
  code=$(curl -sS --retry 3 -o "$TMP/$name.json" -w '%{http_code}' -X POST \
    -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' <"$CF_TOKEN_FILE")") \
    --data-binary "$sql" "$API/accounts/$ACCOUNT/analytics_engine/sql") || die "can't reach $API"
  if [[ "$code" != 200 ]]; then
    # A dataset nobody has written to yet doesn't exist: no rows.
    if grep -qi 'unknown table\|does not exist\|not found' "$TMP/$name.json"; then echo '{"data":[]}' >"$TMP/$name.json"
    else die "$name: HTTP $code: $(head -c 300 "$TMP/$name.json")"
    fi
  fi
done
python3 scripts/stats-report.py "$TMP" "$DAYS" "${STATS_TODAY:-}"
