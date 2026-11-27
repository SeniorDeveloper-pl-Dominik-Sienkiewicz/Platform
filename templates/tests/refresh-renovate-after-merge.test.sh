#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"

# Uruchamiamy blok tagowania z workflow na atrapach poleceń GitHuba i skryptu tagującego.
ruby -ryaml -e '
  steps = YAML.safe_load(File.read(ARGV.fetch(0))).fetch("jobs").fetch("release").fetch("steps")
  tag = steps.find { |step| step["run"].to_s.include?("bash scripts/tag-dependency-release.sh") }
  puts tag.fetch("run")
' "$root/.github/workflows/dependency-release.yml" > tag-step.sh
mkdir -p bin scripts gradle/build-logic frontend/packages/example
cp "$root"/scripts/{release-notes,changelog-section}.sh scripts/
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main
git config user.name Fixture
git config user.email fixture@example.invalid
printf 'platformVersion=2.1.0\n' > gradle/build-logic/gradle.properties
printf '{\n  "version": "2.1.0"\n}\n' > frontend/packages/example/package.json
printf '# Changelog\n\n## [Unreleased]\n\n## [2.1.0] - 2026-11-26\n' > CHANGELOG.md
git add gradle frontend CHANGELOG.md
git commit -qm 'chore: initial release'
git tag v2.1.0
base=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$base"
for branch in first second; do
  git switch -qc "renovate/$branch" "$base"
  echo '1.2.3' > "$branch.version"
  git add "$branch.version"
  git commit -qm "fix(deps): update $branch dependency"
  [[ $(bash "$root/scripts/prepare-dependency-release.sh" "$base") == 2.1.1 ]]
  git commit -qam 'chore(deps): refresh generated dependency files'
done
git switch -q main
git merge -q --no-ff renovate/first -m 'fix(deps): merge first update'
export MERGE_SHA REVIEWED_HEAD
MERGE_SHA=$(git rev-parse HEAD)
REVIEWED_HEAD=$(git rev-parse renovate/first)
git update-ref refs/remotes/origin/main "$MERGE_SHA"
cat > scripts/tag-dependency-release.sh <<'SH'
[[ $1 == "$MERGE_SHA" && $2 == "$REVIEWED_HEAD" ]] || exit 1
[[ $TAG_STATUS == 0 ]] || exit 1
git tag v2.1.1 "$1"
SH
cat > bin/gh <<'SH'
#!/usr/bin/env bash
set -eu
[[ $* == "api --method POST repos/$GITHUB_REPOSITORY/dispatches -f event_type="* ]]
printf '%s\n' "${!#}" >> events
SH
chmod +x bin/gh
export PATH="$fixture/bin:$PATH" GITHUB_REPOSITORY=fixture/platform

if TAG_STATUS=1 bash -e tag-step.sh; then echo 'FAIL: a failed tag must fail the release step' >&2; exit 1; fi
[[ ! -e events ]] || { echo 'FAIL: a rejected merge triggered a refresh' >&2; exit 1; }
TAG_STATUS=0 bash -e tag-step.sh
[[ -s events ]] || { echo 'FAIL: tagging the first PR did not trigger a refresh of the remaining PRs' >&2; exit 1; }

ruby -ryaml -rjson - "$root/.github/workflows/daily-dependencies.yml" <<'RUBY'
  daily = YAML.safe_load(File.read(ARGV.fetch(0)))
  triggers = daily["on"] || daily.fetch(true)
  event = File.read("events").strip.delete_prefix("event_type=")
  events = triggers.dig("repository_dispatch", "types") || []
  abort "FAIL: the daily workflow does not handle the refresh event" unless events.include?(event)
  propose = daily.fetch("jobs").fetch("propose")
  env = propose.fetch("steps").map { |step| step["env"] }.compact.find { |vars| vars.key?("RENOVATE_FORCE") }
  config = JSON.parse(env.fetch("RENOVATE_FORCE"))
  abort "FAIL: remaining branches must be rebased onto main" unless config["rebaseWhen"] == "behind-base-branch"
RUBY

# Renovate odtwarza wyłącznie zmianę zależności na nowej bazie i oddaje ją do przygotowania wydania.
git switch -q --detach "$MERGE_SHA"
git cherry-pick renovate/second^ >/dev/null
first_notes=$(bash scripts/changelog-section.sh 2.1.1)
[[ $(bash "$root/scripts/prepare-dependency-release.sh" "$MERGE_SHA") == 2.1.2 ]]
grep -Fxq 'platformVersion=2.1.2' gradle/build-logic/gradle.properties
[[ $(bash scripts/changelog-section.sh 2.1.1) == "$first_notes" ]]
bash scripts/changelog-section.sh 2.1.2 | grep -Fq 'update second dependency'
echo 'OK: tagging the first 2.1.1 candidate triggers a refresh and the remaining candidate prepares 2.1.2'
