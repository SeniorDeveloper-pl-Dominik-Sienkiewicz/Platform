#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=templates/tests/lib/release-ci.sh
source "$root/templates/tests/lib/release-ci.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail() { echo "FAIL: $*" >&2; exit 1; }

release="$root/scripts/release.sh"
awk '
  /^require_green_main_ci\(\) \{/ { inside = 1 }
  inside { print }
  inside && /^\}/ { exit }
' "$release" > "$tmp/guard.sh"
[[ -s "$tmp/guard.sh" ]] || fail 'release.sh must define the CI guard'
# shellcheck disable=SC2016 # literal shell source
guard_line=$(grep -nFx 'require_green_main_ci "$planned_head"' "$release" | cut -d: -f1)
# shellcheck disable=SC2016 # literal shell source
bump_line=$(grep -nFx 'for f in "${PROPERTY_FILES[@]}"; do' "$release" | cut -d: -f1)
[[ -n "$guard_line" && "$guard_line" -lt "$bump_line" ]] || fail 'check the planned source SHA before bumping versions'

use_green_release_ci "$tmp"
git init -qb main "$tmp/repo"
cd "$tmp/repo"
git -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm 'chore: source commit'
git remote add origin https://github.com/example/Platform.git
sha=$(git rev-parse HEAD)
# shellcheck disable=SC1090 # test extracts the production guard
source "$tmp/guard.sh"

require_green_main_ci "$sha" > "$tmp/out" || fail 'green CI for the exact main SHA must allow release'
for result in missing wrong-sha wrong-branch wrong-event pending failed api-error; do
  if (export RELEASE_CI_RESULT="$result"; require_green_main_ci "$sha") > "$tmp/out" 2>&1; then
    fail "$result must block release"
  fi
  grep -Fq "$sha" "$tmp/out" || fail "$result must identify the required SHA"
done

echo 'OK: release requires successful push CI on the exact main SHA'
