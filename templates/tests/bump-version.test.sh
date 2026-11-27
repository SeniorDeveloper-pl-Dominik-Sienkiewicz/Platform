#!/usr/bin/env bash
# bump-version.sh, przypadek po przypadku: semver backendu, changeset w pustym masterze Liquibase i nazwa repozytorium
# jako autor oraz numeracja nowych changesetów po najwyższym istniejącym prefiksie.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- semver-and-changesets ---
# bump-version.sh: semver backendu (patch, jawna wersja, nieznana akcja bez zmiany pliku), changeset Liquibase
# do pustej listy master oraz autor changesetu = nazwa repo, także gdy skrypt biegnie z worktree <repo>/.worktrees/<x>.
(
canon="$(cd "$(dirname "$0")/.." && pwd)/bump-version.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# app <dir>: repo w układzie konsumenta ze skryptem w scripts/.
app() {
  mkdir -p "$1/scripts" "$1/backend/src/main/resources/db/changelog"
  cp "$canon" "$1/scripts/bump-version.sh"
  printf 'version=1.2.3\norg.gradle.caching=true\n' > "$1/backend/gradle.properties"
  printf 'databaseChangeLog: []\n' > "$1/backend/src/main/resources/db/changelog/db.changelog-master.yaml"
}

plain="$tmp/Plain"
app "$plain"
bash "$plain/scripts/bump-version.sh" backend patch > /dev/null
grep -qx 'version=1.2.4' "$plain/backend/gradle.properties" || fail '(a) patch must turn 1.2.3 into 1.2.4'
bash "$plain/scripts/bump-version.sh" backend 2.0.0 > /dev/null
grep -qx 'version=2.0.0' "$plain/backend/gradle.properties" || fail '(b) an explicit version must be set as given'
cp "$plain/backend/gradle.properties" "$tmp/before"
if bash "$plain/scripts/bump-version.sh" backend bogus > /dev/null 2>&1; then fail '(c) an unknown action must fail'; fi
cmp -s "$tmp/before" "$plain/backend/gradle.properties" || fail '(c) an unknown action must leave gradle.properties unchanged'

bash "$plain/scripts/bump-version.sh" db new-migration add-users > /dev/null
master="$plain/backend/src/main/resources/db/changelog/db.changelog-master.yaml"
[[ "$(head -1 "$master")" == 'databaseChangeLog:' ]] || fail '(e) an empty master list must become a block list'
grep -qx '      file: db/changelog/changes/0001-add-users.yaml' "$master" || fail '(e) the changeset must be included in the master'
grep -qx '      author: plain' "$plain/backend/src/main/resources/db/changelog/changes/0001-add-users.yaml" \
  || fail '(f) outside git the author is the lower-cased directory name'

repo="$tmp/MyApp"
app "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m init
git -C "$repo" worktree add -q "$repo/.worktrees/feat-x"
bash "$repo/.worktrees/feat-x/scripts/bump-version.sh" db new-migration add-users > /dev/null
changeset="$repo/.worktrees/feat-x/backend/src/main/resources/db/changelog/changes/0001-add-users.yaml"
grep -qx '      author: myapp' "$changeset" || fail "(d) a worktree must write the repository name, got: $(grep author "$changeset")"

echo 'OK: bump-version bumps semver, writes changesets into an empty master and names the repository as author from a worktree'
)

# --- changeset-numbering ---
# bump-version.sh db new-migration numeruje nowy changeset Liquibase po najwyższym istniejącym
# 4-cyfrowym prefiksie i pomija pliki bez niego.
(
canon="$(cd "$(dirname "$0")/.." && pwd)/bump-version.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT


repo="$tmp/app"
changes="$repo/backend/src/main/resources/db/changelog/changes"
mkdir -p "$repo/scripts" "$changes"
cp "$canon" "$repo/scripts/bump-version.sh"
printf 'databaseChangeLog: []\n' > "$repo/backend/src/main/resources/db/changelog/db.changelog-master.yaml"
touch "$changes/0001-baseline.yaml" "$changes/0009-index.yaml" "$changes/0010-users.yaml" "$changes/README.md"

bash "$repo/scripts/bump-version.sh" db new-migration orders > /dev/null
[[ -f "$changes/0011-orders.yaml" ]] || fail "the next changeset after 0010 must be 0011-orders.yaml: $(ls "$changes")"
grep -q 'file: db/changelog/changes/0011-orders.yaml' "$repo/backend/src/main/resources/db/changelog/db.changelog-master.yaml" \
  || fail 'the new changeset must be included in the master changelog'

empty="$tmp/empty"
mkdir -p "$empty/scripts" "$empty/backend/src/main/resources/db/changelog"
cp "$canon" "$empty/scripts/bump-version.sh"
printf 'databaseChangeLog: []\n' > "$empty/backend/src/main/resources/db/changelog/db.changelog-master.yaml"
bash "$empty/scripts/bump-version.sh" db new-migration first > /dev/null
[[ -f "$empty/backend/src/main/resources/db/changelog/changes/0001-first.yaml" ]] || fail 'the first changeset must be 0001'

echo 'OK: bump-version numbers new changesets after the highest existing prefix'
)

# --- missing-version ---
# bump-version.sh backend przy gradle.properties bez `version=`: grep bez trafienia w $(...) pod set -euo pipefail nie
# może zakończyć skryptu po cichu; skrypt ma powiedzieć, czego brakuje, i zakończyć się kodem 1.
(
canon="$(cd "$(dirname "$0")/.." && pwd)/bump-version.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app/scripts" "$tmp/app/backend"
cp "$canon" "$tmp/app/scripts/bump-version.sh"
printf 'org.gradle.caching=true\n' > "$tmp/app/backend/gradle.properties"
rc=0
bash "$tmp/app/scripts/bump-version.sh" backend patch > "$tmp/out" 2>&1 || rc=$?
[[ $rc -eq 1 ]] || fail "a gradle.properties without version= must end with exit 1, got $rc"
grep -qF "No 'version=' in" "$tmp/out" || fail "a gradle.properties without version= must say so: $(cat "$tmp/out")"
echo 'OK: bump-version names the missing version= instead of exiting silently'
)

# --- english-changeset ---
# Nowy changeset Liquibase, który bump-version.sh wpisuje do repo konsumenta, ma komentarz po angielsku.
(
canon="$(cd "$(dirname "$0")/.." && pwd)/bump-version.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app/scripts" "$tmp/app/backend/src/main/resources/db/changelog"
cp "$canon" "$tmp/app/scripts/bump-version.sh"
printf 'databaseChangeLog: []\n' > "$tmp/app/backend/src/main/resources/db/changelog/db.changelog-master.yaml"
bash "$tmp/app/scripts/bump-version.sh" db new-migration orders > /dev/null
changeset="$tmp/app/backend/src/main/resources/db/changelog/changes/0001-orders.yaml"
grep -qx '      # TODO: add the operations (createTable/addColumn/sql...); migrations are forward-only.' "$changeset" \
  || fail "the changeset comment must be English: $(cat "$changeset")"
echo 'OK: bump-version writes an English changeset'
)
