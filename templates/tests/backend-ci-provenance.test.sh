#!/usr/bin/env bash
# verify-provenance of backend-ci.yml (N-REL-16): every Platform jar and catalog TOML in the Gradle cache, and the
# POM and Gradle module metadata of releases after 2.1.0 (platform-bom among them), must verify against the
# attestations of Platform's release.yml; sources and javadoc jars are skipped, an unverified file or an empty cache
# fails with PLAT-PROV-001. The block is cut out between its markers and run against a stub gh.
# shellcheck disable=SC2016 # literal GitHub expressions
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
workflow="$root/.github/workflows/backend-ci.yml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; echo "$OUT" >&2; exit 1; }
OUT=""
awk 'index($0, "# >>> verify-provenance") { inside = 1; next } index($0, "# <<< verify-provenance") { inside = 0 } inside { sub(/^          /, ""); print }' \
  "$workflow" > "$tmp/verify.sh"
[[ -s "$tmp/verify.sh" ]] || fail 'backend-ci.yml has no verify-provenance block between its markers'
grep -qF 'if: ${{ inputs.verify-provenance }}' <(sed -n '/- name: Verify the provenance of the Platform artifacts/,/run:/p' "$workflow") \
  || fail 'the check must be opt-in'

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
[[ "$3" == *unattested* ]] && exit 1
exit 0
GH
chmod +x "$tmp/bin/gh"
cache="$tmp/home/caches/modules-2/files-2.1"
artifact() { local version=$3; mkdir -p "$cache/$1/$2/$version/abc"; : > "$cache/$1/$2/$version/abc/$2-$version.$4"; }
jar() { local version=${4:-1.6.0}; mkdir -p "$cache/$1/$2/$version/abc"; : > "$cache/$1/$2/$version/abc/$2-$version$3.jar"; }
run() { : > "$tmp/calls"; RC=0; OUT=$(GRADLE_USER_HOME="$tmp/home" GH_CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" bash "$tmp/verify.sh" 2>&1) || RC=$?; }

run
[[ $RC -eq 1 ]] && grep -qF '[PLAT-PROV-001] No Platform jar in the Gradle cache' <<<"$OUT" || fail 'an empty cache must fail'

jar pl.seniordeveloper platform-test-fixtures ""
jar pl.seniordeveloper platform-test-fixtures -sources
jar pl.seniordeveloper.gradle build-logic ""
jar org.example other ""
run
[[ $RC -eq 0 ]] || fail 'attested Platform jars must pass'
[[ $(wc -l < "$tmp/calls") -eq 2 ]] || fail 'only the two Platform main jars are verified'
grep -qF -- '--signer-workflow DominikSienkiewicz/Platform/.github/workflows/release.yml' "$tmp/calls" || fail 'the signer must be release.yml'

jar pl.seniordeveloper platform-test-fixtures "" 2.0.0
run
[[ $RC -eq 0 ]] || fail 'mixed historical and organization jars must pass with their respective signers'
org=SeniorDeveloper-pl-Dominik-Sienkiewicz/Platform
grep -F 'platform-test-fixtures-2.0.0.jar ' "$tmp/calls" | grep -Fq -- "--repo $org --signer-workflow $org/.github/workflows/release.yml --source-ref refs/tags/v2.0.0" || fail 'a 2.x jar requires the organization release workflow'
grep -F 'platform-test-fixtures-1.6.0.jar ' "$tmp/calls" | grep -Fq -- '--signer-workflow DominikSienkiewicz/Platform/.github/workflows/release.yml --source-ref refs/tags/v1.6.0' || fail 'a 1.x jar requires its original signer'

jar pl.seniordeveloper platform-unattested ""
run
[[ $RC -eq 1 ]] || fail 'an unattested jar must fail'
grep -qF '[PLAT-PROV-001] platform-unattested-1.6.0.jar carries no attestation' <<<"$OUT" || fail 'the failure must name the jar'
rm -r "$cache/pl.seniordeveloper/platform-unattested"

# Katalog decyduje o każdej wersji: TOML ma atestację od 1.6.0, tak jak jary.
artifact pl.seniordeveloper platform-catalog 1.6.0 toml
run
[[ $RC -eq 0 ]] || fail 'an attested catalog TOML must pass'
grep -qF 'platform-catalog-1.6.0.toml ' "$tmp/calls" || fail 'the catalog TOML must be verified'
artifact pl.seniordeveloper platform-catalog-unattested 1.6.0 toml
run
[[ $RC -eq 1 ]] && grep -qF '[PLAT-PROV-001] platform-catalog-unattested-1.6.0.toml carries no attestation' <<<"$OUT" \
  || fail 'an unattested catalog TOML must fail'
rm -r "$cache/pl.seniordeveloper/platform-catalog-unattested"

# POM i .module (platform-bom: ograniczenia i podłogi CVE) mają atestację dopiero po 2.1.0; starsze wydania przechodzą.
artifact pl.seniordeveloper platform-bom 2.1.0 pom
artifact pl.seniordeveloper platform-bom 2.1.0 module
run
[[ $RC -eq 0 ]] || fail 'the metadata of a release without metadata attestations must not fail'
! grep -qF 'platform-bom-2.1.0' "$tmp/calls" || fail 'the metadata of 2.1.0 and older carries no attestation to verify'
artifact pl.seniordeveloper platform-bom 2.1.1 pom
artifact pl.seniordeveloper platform-bom 2.1.1 module
artifact pl.seniordeveloper.gradle build-logic 2.10.0 pom
run
[[ $RC -eq 0 ]] || fail 'attested metadata must pass'
for file in platform-bom-2.1.1.pom platform-bom-2.1.1.module build-logic-2.10.0.pom; do
  grep -qF "$file --repo $org " "$tmp/calls" || fail "$file must be verified against the organization release workflow"
done
artifact pl.seniordeveloper platform-bom-unattested 2.2.0 module
run
[[ $RC -eq 1 ]] && grep -qF '[PLAT-PROV-001] platform-bom-unattested-2.2.0.module carries no attestation' <<<"$OUT" \
  || fail 'unattested metadata of a newer release must fail'
echo 'OK: backend-ci verify-provenance checks every Platform jar, the catalog and newer metadata against release.yml attestations'
