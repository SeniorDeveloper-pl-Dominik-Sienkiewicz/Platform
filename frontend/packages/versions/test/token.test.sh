#!/usr/bin/env bash
# Bin platform-bump bez tokenu: ~/.gradle/gradle.properties bez gpr.key nie może zakończyć skryptu po cichu
# (grep bez trafienia w $(...) pod set -euo pipefail); bin ma wypisać, skąd wziąć token, i zakończyć się kodem 1.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)/bin/platform-bump.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; echo "--- output ---" >&2; cat "$tmp/out" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$tmp/repo"
printf 'platformVersion=2.0.0\n' > "$tmp/repo/gradle.properties"
mkdir -p "$tmp/home/.gradle"
printf 'org.gradle.caching=true\n' > "$tmp/home/.gradle/gradle.properties"

rc=0
(cd "$tmp/repo" && env -u GPR_TOKEN -u GITHUB_TOKEN HOME="$tmp/home" bash "$src") > "$tmp/out" 2>&1 || rc=$?
[[ $rc -eq 1 ]] || fail "a missing token must end the bump with exit 1, got $rc"
grep -qF 'No token: set GPR_TOKEN or GITHUB_TOKEN, or gpr.key in ~/.gradle/gradle.properties.' "$tmp/out" \
  || fail 'gradle.properties without gpr.key must print where the token comes from'
echo 'OK: platform-bump explains a missing token instead of exiting silently'
