#!/usr/bin/env bash
# scripts/canon-diff.py na repo-atrapie: zmiany katalogu, kanonu frontendu, kontraktu workflowów i szablonów
# porównane na sparsowanych wartościach, z regułą akcji konsumenta i wyjściem dla joba z etykietą.
# shellcheck disable=SC2016 # expected report lines carry literal Markdown backticks
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail() { echo "FAIL: $*" >&2; echo "--- report ---" >&2; cat "$tmp/report" >&2; exit 1; }
: > "$tmp/report"

repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name t
git -C "$repo" config user.email t@example.invalid
mkdir -p "$repo/gradle/catalog" "$repo/frontend/packages/versions" "$repo/templates/tests/fixtures"
write() {
  cat > "$repo/gradle/catalog/libs.versions.toml" <<TOML
[versions]
# $1
springBoot = "$2"
jimfs = "1.3.0"
[libraries]
jimfs = { group = "com.google.jimfs", name = "jimfs", version.ref = "jimfs" }
$3
[bundles]
[plugins]
TOML
  printf '{ "versions": { "next": "%s"%s } }\n' "$4" "$5" > "$repo/frontend/packages/versions/versions.json"
  printf '%s\n' "$6" > "$repo/templates/tests/fixtures/workflow-contract.txt"
  printf 'root = true\nindent = %s\n' "$7" > "$repo/templates/editorconfig"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$1"
}
base_contract='backend-ci.yml input working-directory type=string default=backend
backend-ci.yml input gradle-task type=string default=build
backend-ci.yml secret gpr_token required=false
backend-ci.yml permissions contents: read'
write base 4.1.0 '' 16.2.5 ', "postcss": "8.5.6"' "$base_contract" tab
base=$(git -C "$repo" rev-parse HEAD)

# Tylko komentarz i wersje: nic do zrobienia po stronie konsumenta.
write "only a comment" 4.1.1 '' 16.2.6 ', "postcss": "8.5.6"' "$base_contract" tab
(cd "$repo" && python3 "$root/scripts/canon-diff.py" "$base" HEAD --github-output "$tmp/quiet.out") > "$tmp/report"
grep -qF -- '- catalog `libs.versions.springBoot`: 4.1.0 → 4.1.1' "$tmp/report" || fail 'a version change must be reported'
grep -qF -- '- frontend canon `next`: 16.2.5 → 16.2.6' "$tmp/report" || fail 'a canon version change must be reported'
if grep -q 'comment' "$tmp/report"; then fail 'a comment-only edit is not a change'; fi
grep -qx 'None.' "$tmp/report" || fail 'versions alone need no consumer action'
grep -qx 'consumer_action=false' "$tmp/quiet.out" || fail 'the job output must say false'
quiet=$(git -C "$repo" rev-parse HEAD)

head_contract='backend-ci.yml input working-directory type=string default=.
backend-ci.yml input java-version type=string required=true
backend-ci.yml permissions contents: read
backend-ci.yml permissions packages: read'
write head 4.1.1 'boot-starter = { group = "org.springframework.boot", name = "spring-boot-starter" }' 16.2.6 '' "$head_contract" space
sed -i.bak '/jimfs/d' "$repo/gradle/catalog/libs.versions.toml" && rm -f "$repo/gradle/catalog/libs.versions.toml.bak"
git -C "$repo" commit -q -am 'drop jimfs'
(cd "$repo" && python3 "$root/scripts/canon-diff.py" "$quiet" HEAD --github-output "$tmp/loud.out") > "$tmp/report"
for expected in \
  '- catalog `libs.versions.jimfs` removed' \
  '- catalog `libs.jimfs` removed' \
  '- catalog `libs.boot.starter` added' \
  '- frontend canon `postcss` removed: the consumer owns its version from now on' \
  '- `backend-ci.yml` input `java-version` added (required)' \
  '- `backend-ci.yml` input `gradle-task` removed' \
  '- `backend-ci.yml` input `working-directory`: required=False default=backend → required=False default=.' \
  '- `backend-ci.yml` secret `gpr_token` removed' \
  '- `backend-ci.yml` needs `packages: read` (was none)' \
  '- template `templates/editorconfig` changed: repositories that keep a copy re-copy it' \
  '- a build that uses `libs.jimfs` no longer resolves it' \
  '- every caller of `backend-ci.yml` must pass the new required input `java-version`' \
  '- every caller of `backend-ci.yml` must grant `packages: read`'; do
  grep -qF -- "$expected" "$tmp/report" || fail "missing line: $expected"
done
grep -qx 'consumer_action=true' "$tmp/loud.out" || fail 'the job output must say true'
if grep -qF 'depends on `postcss`' "$tmp/report"; then fail 'a frontend canon removal is not a consumer action'; fi

# Samo usunięcie paczki z kanonu frontendu: konsument przejmuje jej wersję, więc nie ma akcji.
write canon-before 4.1.1 '' 16.2.6 ', "postcss": "8.5.6"' "$head_contract" space
canon_before=$(git -C "$repo" rev-parse HEAD)
write canon-after 4.1.1 '' 16.2.6 '' "$head_contract" space
(cd "$repo" && python3 "$root/scripts/canon-diff.py" "$canon_before" HEAD --github-output "$tmp/canon.out") > "$tmp/report"
grep -qF -- '- frontend canon `postcss` removed: the consumer owns its version from now on' "$tmp/report" || fail 'a canon removal must say the consumer owns the version'
grep -qx 'None.' "$tmp/report" || fail 'a canon removal alone needs no consumer action'
grep -qx 'consumer_action=false' "$tmp/canon.out" || fail 'a canon removal alone must not label the pull request'

# Sekret wymagany (nowy albo z false na true), zmiana typu wejścia i ruch toolchainu `java` to akcja (ADR-0002, pkt 4).
secrets_before='backend-ci.yml input timeout-minutes type=number default=30
backend-ci.yml secret gpr_token required=false
backend-ci.yml secret snyk_token required=true'
secrets_after='backend-ci.yml input timeout-minutes type=string default=30
backend-ci.yml secret gpr_token required=true
backend-ci.yml secret snyk_token required=false
backend-ci.yml secret sonar_token required=true
backend-ci.yml secret extra_token required=false'
write secrets-before 4.1.1 '' 16.2.6 '' "$secrets_before" space
sed -i.bak 's/^\[versions\]$/[versions]\njava = "27"/' "$repo/gradle/catalog/libs.versions.toml" && rm -f "$repo/gradle/catalog/libs.versions.toml.bak"
git -C "$repo" commit -q -am 'java 27'
secrets_base=$(git -C "$repo" rev-parse HEAD)
write secrets-after 4.1.1 '' 16.2.6 '' "$secrets_after" space
sed -i.bak 's/^\[versions\]$/[versions]\njava = "28"/' "$repo/gradle/catalog/libs.versions.toml" && rm -f "$repo/gradle/catalog/libs.versions.toml.bak"
git -C "$repo" commit -q -am 'java 28'
(cd "$repo" && python3 "$root/scripts/canon-diff.py" "$secrets_base" HEAD --github-output "$tmp/secrets.out") > "$tmp/report"
for expected in \
  '- catalog `libs.versions.java`: 27 → 28' \
  '- `backend-ci.yml` input `timeout-minutes`: type=number → type=string' \
  '- `backend-ci.yml` secret `gpr_token` became required' \
  '- `backend-ci.yml` secret `snyk_token` is no longer required' \
  '- `backend-ci.yml` secret `sonar_token` added (required)' \
  '- `backend-ci.yml` secret `extra_token` added' \
  '- the toolchain moves to Java 28: run CI and the final Dockerfile `FROM` on Java 28, or `platformRuntimeImageCheck` fails (PLAT-IMG-001)' \
  '- a caller of `backend-ci.yml` that passes `timeout-minutes` must pass a string' \
  '- every caller of `backend-ci.yml` must pass the secret `gpr_token`, which is now required' \
  '- every caller of `backend-ci.yml` must pass the new required secret `sonar_token`'; do
  grep -qxF -- "$expected" "$tmp/report" || fail "missing line: $expected"
done
actions=$(awk '/^### Consumer action required$/ { inside = 1; next } inside && /^- /' "$tmp/report")
if grep -qF -e 'snyk_token' -e 'extra_token' <<<"$actions"; then fail 'an optional secret is not a consumer action'; fi
grep -qx 'consumer_action=true' "$tmp/secrets.out" || fail 'a required secret, a type change and a toolchain move label the pull request'

echo 'OK: canon-diff compares parsed values and flags the changes that need consumer action'
