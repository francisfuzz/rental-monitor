#!/usr/bin/env bash
# simulate.sh — run the monitor pipeline locally against the fixture file.
# Usage: ./simulate.sh [path/to/response.json]
# Defaults to data/fixtures/sample-response.json when no argument is given.
#
# Each section maps directly to a named step in .github/workflows/monitor.yml
# so you can compare output side-by-side with a real Actions run.

set -euo pipefail

FIXTURE="${1:-data/fixtures/sample-response.json}"
SEEN_FILE="data/seen-listings.json"

if ! command -v yq > /dev/null 2>&1; then
  echo "ERROR: yq is required but not installed." >&2
  echo "       Install with: brew install yq  (macOS) or snap install yq  (Linux)" >&2
  exit 1
fi

divider() { printf '\n%s\n' "────────────────────────────────────────────────────────────────"; }
header()  { divider; printf '▶  STEP: %s\n' "$*"; divider; }

# ── Step: Parse config ──────────────────────────────────────────────────────

header "Parse config"

ZIP_CODE=$(yq '.zip_code' monitor-config.yml)
BEDROOMS=$(yq '.bedrooms // "2:3"' monitor-config.yml)

# Escape only oniguruma metacharacters in each street name (e.g. the dot in "St. James Pl."),
# then join with | as the alternation operator. Spaces are NOT escaped — oniguruma matches them literally.
STREET_REGEX=$(yq '.streets[]' monitor-config.yml \
  | sed 's/[].*+?(){}^$|\\[]/\\&/g' \
  | tr '\n' '|' \
  | sed 's/|$//')

# Build a jq boolean expression like (.bedrooms == 2 and .price <= 5500) or (.bedrooms == 3 ...).
# Each price_cap key looks like "2br"; strip "br" to get the bedroom integer.
PRICE_FILTER=''
while IFS= read -r br_key; do
  cap=$(yq ".price_caps.\"$br_key\"" monitor-config.yml)
  br="${br_key%br}"
  clause="(.bedrooms == $br and .price <= $cap)"
  PRICE_FILTER="${PRICE_FILTER:+$PRICE_FILTER or }$clause"
done < <(yq '.price_caps | keys | .[]' monitor-config.yml)
[ -z "$PRICE_FILTER" ] && PRICE_FILTER='true'

echo "  zip_code    : $ZIP_CODE"
echo "  bedrooms    : $BEDROOMS"
echo "  street_regex: $STREET_REGEX"
echo "  price_filter: $PRICE_FILTER"

# ── Step: Resolve zip code ───────────────────────────────────────────────────

header "Resolve zip code"
# No dispatch override in a local run; always use the config value.
RESOLVED_ZIP="$ZIP_CODE"
echo "  zip_code (resolved): $RESOLVED_ZIP"

# ── Step: Fetch and filter listings (using fixture) ──────────────────────────

header "Fetch and filter listings  [SIMULATED — using $FIXTURE]"

RESPONSE=$(cat "$FIXTURE")

if ! echo "$RESPONSE" | jq -e 'type == "array"' > /dev/null; then
    echo "ERROR: fixture is not a JSON array" >&2
    exit 1
fi

TOTAL_COUNT=$(echo "$RESPONSE" | jq 'length')

FILTERED=$(echo "$RESPONSE" | jq \
    --arg street_regex "$STREET_REGEX" \
    '[.[] | select((.addressLine1 // "") | test($street_regex; "i")) | select(.price != null and ('"$PRICE_FILTER"'))]')

FILTERED_COUNT=$(echo "$FILTERED" | jq 'length')

echo "  total listings in fixture : $TOTAL_COUNT"
echo "  after street + price filter: $FILTERED_COUNT"
echo
echo "  Passing listings:"
echo "$FILTERED" | jq -r '.[] | "    • \(.addressLine1)  [\(.bedrooms)br, $\(.price)/mo]  id=\(.id)"'

echo
echo "  Excluded listings:"
EXCLUDED=$(echo "$RESPONSE" | jq \
    --arg street_regex "$STREET_REGEX" \
    '[.[] | select( ((.addressLine1 // "") | test($street_regex; "i")) and (.price != null and ('"$PRICE_FILTER"')) | not )]')
echo "$EXCLUDED" | jq -r '.[] | "    ✗ \(.addressLine1)  [\(.bedrooms)br, $\(.price)/mo]  id=\(.id)"'

# ── Step: Check for new listings ─────────────────────────────────────────────

header "Check for new listings"

SEEN=$(cat "$SEEN_FILE" 2>/dev/null || echo '[]')
[ -z "$SEEN" ] && SEEN='[]'

FILTERED_IDS=$(echo "$FILTERED" | jq '[.[] | select(.id) | .id]')
SEEN_IDS=$(echo "$SEEN" | jq '[.[] | if type == "object" then .id else . end | select(. != null)]')

NEW_IDS=$(jq -n \
    --argjson filtered "$FILTERED_IDS" \
    --argjson seen_ids "$SEEN_IDS" \
    '[$filtered[] | select(. as $id | $seen_ids | index($id) | not)]')

NEW_COUNT=$(echo "$NEW_IDS" | jq 'length')

echo "  already seen : $(echo "$SEEN_IDS" | jq 'length')"
echo "  new this run : $NEW_COUNT"
if [ "$NEW_COUNT" -gt 0 ]; then
    echo "$NEW_IDS" | jq -r '.[] | "    + \(.)"'
fi

# ── Step: Build issue body ───────────────────────────────────────────────────

header "Build issue body"

if [ "$NEW_COUNT" -eq 0 ]; then
    echo "  (no new listings — issue body step would be skipped)"
else
    TODAY=$(TZ=America/Los_Angeles date +"%B %d, %Y")

    BODY=$(echo "$FILTERED" | jq -r \
        --argjson new_ids "$NEW_IDS" \
        --arg today "$TODAY" '
        "## Rental Digest — " + $today + "\n\n" +
        ([ .[]
          | select(.id as $id | $new_ids | index($id) != null)
          | "### " + (.addressLine1 // "Unknown address") + "\n"
          + "- **Beds:** " + ((.bedrooms // "N/A") | tostring) + " | **Baths:** " + ((.bathrooms // "N/A") | tostring) + "\n"
          + "- **Rent:** $" + ((.price // "N/A") | tostring) + "/mo\n"
          + "- **Sq ft:** " + ((.squareFootage // "N/A") | tostring) + "\n"
          + "- **First spotted:** " + $today + "\n"
          + (if .listingUrl then "- **Listing:** " + .listingUrl + "\n" else "" end)
        ] | join("\n\n---\n\n"))
    ')

    echo "$BODY"
fi

# ── Step: Write heartbeat ────────────────────────────────────────────────────

header "Write heartbeat  [DRY RUN — nothing written]"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n \
    --arg lastRun "$NOW" \
    --argjson totalInZip "$TOTAL_COUNT" \
    --argjson afterFilter "$FILTERED_COUNT" \
    --argjson newListings "$NEW_COUNT" \
    '{lastRun: $lastRun, totalInZip: $totalInZip, afterFilter: $afterFilter, newListings: $newListings}'

divider
printf '\n✓  Simulation complete. No files were written and no issues were opened.\n'
printf '   To test with real API data, pass a response file:  ./simulate.sh /path/to/response.json\n\n'
