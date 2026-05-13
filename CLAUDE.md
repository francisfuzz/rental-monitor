# CLAUDE.md

Agent guidance for working on this repository.

---

## Project overview

`rental-monitor` is a GitHub Actions template that polls the Rentcast long-term
rental listings API on a schedule, filters results by street name and per-bedroom
price caps, and opens a GitHub Issue digest for every new match. Users fork/template
the repo, edit `monitor-config.yml`, set one secret, and push — no workflow editing
required.

---

## Repository layout

```
.
├── .github/workflows/
│   ├── monitor.yml          # Daily monitor: fetch → filter → diff → issue → commit
│   └── setup.yml            # One-shot validator: config fields + API key presence
├── data/
│   ├── fixtures/
│   │   └── sample-response.json  # 6 synthetic listings for local testing (3 pass, 3 fail)
│   ├── last-run.json             # Heartbeat written on every run (committed by workflow)
│   └── seen-listings.json        # Persisted listing IDs + firstSeen dates
├── monitor-config.yml       # User-editable: zip_code, streets, price_caps, bedrooms
├── simulate.sh              # Local dry-run: replays the full workflow against the fixture
├── README.md
├── NOTICE                   # Rentcast attribution + personal-use scope
└── LICENSE                  # MIT
```

---

## Data flow

```
monitor-config.yml
  └─ Parse config (yq)
       ├── ZIP_CODE, BEDROOMS      → Rentcast API query params
       ├── STREET_REGEX            → jq test() filter (oniguruma, case-insensitive)
       └── PRICE_FILTER            → jq select() expression
            └─ Fetch + filter
                 └─ Diff vs seen-listings.json
                      └─ New IDs → Issue body → GitHub Issue
                      └─ Updated seen-listings.json + last-run.json → git commit
```

---

## Language and tooling conventions

- **Bash + yq only** — no Python. All YAML parsing uses `yq` (mikefarah/yq v4).
  `yq` is pre-installed on GitHub-hosted ubuntu-latest runners.
- **jq** for all JSON manipulation. Never parse JSON with sed/awk.
- `set -euo pipefail` at the top of every multi-line `run:` block.
- Step outputs use `KEY=VALUE` for scalars and the `KEY<<DELIM` / `DELIM` heredoc
  syntax (with `openssl rand -hex 8` as the delimiter) for multi-line values.
  See: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#multiline-strings

---

## Regex escaping rules

The street regex passed to `jq test()` uses the **oniguruma** engine. Key rules:

- Metacharacters to escape: `. ^ $ * + ? ( ) [ ] { } | \`
- Spaces must **NOT** be escaped — `\ ` is not a literal space in oniguruma.
- The `sed` escaper in the workflow and `simulate.sh`:
  ```bash
  sed 's/[].*+?(){}^$|\\[]/\\&/g'
  ```
- Do not use Python's `re.escape()` — it escapes spaces in Python 3.7+, which
  breaks oniguruma matches.

---

## Local testing

`simulate.sh` replays every named workflow step against the fixture file — no API
calls, no file writes, no issues opened:

```bash
./simulate.sh                              # uses data/fixtures/sample-response.json
./simulate.sh /path/to/real-response.json  # test against actual API data
```

Expected output with the default fixture: **3 listings pass** (fixture-001/002/003),
**3 excluded** (fixture-004 over 2br cap, fixture-005 wrong street, fixture-006 over
3br cap). If the counts are wrong, the street regex or price filter is broken.

`yq` must be installed locally (`brew install yq` on macOS).

---

## Key constraints

- **No Python** anywhere in the workflows or simulate.sh. If you need to process
  YAML, use `yq`. If you need to process JSON, use `jq`.
- **`inputs.dry_run`** is a boolean in the workflow YAML (`type: boolean`). Compare
  with `true`/`false` (unquoted), not `'true'`/`'false'` (strings).
- **No inline `${{ }}` in `run:` scripts** — pass all workflow expression values
  through `env:` and reference them as `$VAR`. This applies to `inputs.*`,
  `steps.*.outputs.*`, and any other expression whose value could be attacker-influenced.
  Inline interpolation evaluates before bash runs, enabling code injection.
- **`[skip ci]`** in the data-commit message prevents the automated push from
  triggering a new workflow run (infinite loop guard).
- The failure-notification step re-creates the `monitor-failure` label with
  `--force 2>/dev/null || true` in case the "Ensure labels exist" step was itself
  the step that failed.

---

## Making changes

1. Edit `monitor-config.yml` to change search parameters — no workflow edits needed.
2. After any workflow change, run `./simulate.sh` to confirm the fixture still
   produces exactly 3 passing listings.
3. Test setup validation logic by temporarily breaking `monitor-config.yml` and
   running the relevant `yq`/bash checks from `setup.yml` manually.
4. Do not commit `data/seen-listings.json` or `data/last-run.json` by hand — the
   workflow manages those files.
