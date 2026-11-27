#!/usr/bin/env bash
# Test bloków python z bin/platform-bump.sh, które wybierają wersję docelową i pokazują notatki
# wydań, przez które bump przechodzi (docs/adr/0002-release-and-versioning-contract.md).
#
# Bloki są WYCINANE ze skryptu po markerach (`# platform-bump:target` / `# platform-bump:notes`)
# i uruchamiane na fiksturach JSON — bez sieci i bez GitHub API, ale na kodzie z produkcji.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/bin/platform-bump.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { local message="$1"; echo "FAIL: $message"; exit 1; }

# Wycina ciało heredoca od linii z markerem do terminatora `PY` (bez niego).
extract() { local marker="$1"; awk -v m="$marker" 'index($0, m) { f = 1 } f && $0 == "PY" { exit } f' "$SRC"; }

extract '# platform-bump:target' > "$WORK/target.py"
extract '# platform-bump:notes' > "$WORK/notes.py"
[[ -s "$WORK/target.py" ]] || fail "no '# platform-bump:target' block in $SRC"
[[ -s "$WORK/notes.py" ]] || fail "no '# platform-bump:notes' block in $SRC"

# --- Target: newest release of the current MAJOR, never a new MAJOR by default ---------------
cat > "$WORK/versions.json" <<'JSON'
[{"name": "1.5.30"}, {"name": "2.0.0"}, {"name": "1.6.0"}, {"name": "1.5.31"}, {"name": "2.0.0-rc1"}]
JSON
[[ "$(python3 "$WORK/target.py" "$WORK/versions.json" 1.5.31)" == "1.6.0 2.0.0" ]] \
  || fail 'without an argument the bump must stay in the current MAJOR and report the newest release'
[[ "$(python3 "$WORK/target.py" "$WORK/versions.json" 2.0.0)" == "2.0.0 2.0.0" ]] \
  || fail 'a consumer already on the newest MAJOR must get its newest release'
[[ "$(python3 "$WORK/target.py" "$WORK/versions.json" "")" == "2.0.0 2.0.0" ]] \
  || fail 'without a known current pin the bump must take the newest release'
printf '[{"name":"2.0.0"}]\n' > "$WORK/versions.json"
if python3 "$WORK/target.py" "$WORK/versions.json" 1.13.1 > "$WORK/target" 2> "$WORK/error"; then
  fail 'a listing with only the new major must require an explicit version from the consumer'
fi
grep -qF 'explicit version' "$WORK/error" || fail 'the failure must explain how to select a major'

# --- Notes: every release in (current, target], oldest first, and their consumer actions ------
cat > "$WORK/releases.json" <<'JSON'
[
  {"tag_name": "v1.7.0", "body": "### Consumer action required\r\n\r\n- Beyond the target.\r\n"},
  {"tag_name": "v1.6.1", "body": "### Consumer action required\r\n\r\nNone.\r\n\r\n### Fixed\r\n\r\n- A fix.\r\n"},
  {"tag_name": "v1.6.0", "body": "### Consumer action required\r\n\r\n- Grant packages: read.\r\n\r\n### Changed\r\n\r\n- A gate.\r\n\r\n**Full diff:** https://example.invalid/compare\r\n"},
  {"tag_name": "v1.5.31", "body": "### Consumer action required\r\n\r\nNone.\r\n"},
  {"tag_name": "latest", "body": "not a version"}
]
JSON
notes=$(python3 "$WORK/notes.py" "$WORK/releases.json" 1.5.31 1.6.1 "$WORK/actions.txt")
grep -q '^===== Platform 1.6.0 =====$' <<<"$notes" || fail 'the notes of 1.6.0 must be printed'
grep -q '^===== Platform 1.6.1 =====$' <<<"$notes" || fail 'the notes of the target must be printed'
if grep -Eq 'Platform 1\.5\.31|Platform 1\.7\.0|Beyond the target' <<<"$notes"; then
  fail 'only releases after the current pin and up to the target may be printed'
fi
[[ "$(grep -n '===== Platform' <<<"$notes" | head -1)" == *'1.6.0'* ]] || fail 'the notes must be printed oldest first'
[[ "$(cat "$WORK/actions.txt")" == "$(printf 'Platform 1.6.0:\n- Grant packages: read.')" ]] \
  || { cat "$WORK/actions.txt"; fail 'the consumer actions must list exactly the releases whose action is not None'; }

python3 "$WORK/notes.py" "$WORK/releases.json" 1.6.1 1.6.1 "$WORK/none.txt" | grep -q 'No release notes' \
  || fail 'a bump to the current version must say there are no notes'
[[ ! -s "$WORK/none.txt" ]] || fail 'a bump without releases must not report consumer actions'

# --- Notes past the first page of 100 releases: every page counts --------------------------------
printf '[{"tag_name": "v1.6.2", "body": "None."}]\n' > "$WORK/page-1.json"
printf '[{"tag_name": "v1.5.32", "body": "### Consumer action required\\n\\n- Old action.\\n"}]\n' > "$WORK/page-2.json"
notes=$(python3 "$WORK/notes.py" "$WORK/page-1.json" 1.5.31 1.6.2 "$WORK/paged.txt" "$WORK/page-2.json")
grep -q '^===== Platform 1.5.32 =====$' <<<"$notes" || fail 'the notes of a release on the second page must be printed'
grep -qF -- '- Old action.' "$WORK/paged.txt" || fail 'the consumer action of a release on the second page must be reported'

# --- The fetch follows rel="next" of the releases listing -------------------------------------------
awk 'index($0, "# platform-bump:releases-end") { exit } f { print } index($0, "# platform-bump:releases") { f = 1 }' "$SRC" > "$WORK/releases.sh"
[[ -s "$WORK/releases.sh" ]] || fail "no '# platform-bump:releases' block in $SRC"
mkdir -p "$WORK/bin" "$WORK/snapshot"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" headers="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) headers="$2"; shift ;;
    -H | --proto | --proto-redir) shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  *'releases?per_page=100&page=1') cp "$PAGE_1" "$out"; printf 'Link: <https://api.github.com/page2>; rel="next"\r\n' > "$headers" ;;
  *'releases?per_page=100&page=2') cp "$PAGE_2" "$out"; : > "$headers" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$WORK/bin/curl"
# shellcheck disable=SC2016 # zmienne rozwija dopiero uruchomiony blok
printf '%s\n' 'printf "%s\n" "$RELEASE_NOTES_READ" "${RELEASE_PAGES[@]}"' >> "$WORK/releases.sh"
pages=$(cd "$WORK" && PATH="$WORK/bin:$PATH" PAGE_1="$WORK/page-1.json" PAGE_2="$WORK/page-2.json" CURRENT=1.5.31 TOKEN=t OWNER=o \
  SNAPSHOT="$WORK/snapshot" bash "$WORK/releases.sh")
[[ "$(head -1 <<<"$pages")" == true ]] || fail "a paged listing must count as read: $pages"
[[ "$(sed -n 3p <<<"$pages")" == *2.json ]] && cmp -s "$(sed -n 3p <<<"$pages")" "$WORK/page-2.json" \
  || fail "the fetch must follow rel=next to the second page: $pages"

echo 'OK: platform-bump stays in the current MAJOR and prints the notes and consumer actions it crosses'
