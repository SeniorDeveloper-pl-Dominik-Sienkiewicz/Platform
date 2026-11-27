#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for job in backend frontend; do
  work="$tmp/$job"
  mkdir -p "$work/tool" "$work/canon"
  ln -s "$root/scripts" "$work/tool/scripts"
  cd "$work"
  ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
    before_scan = steps.take_while { |step| !step.fetch("uses", "").start_with?("anchore/scan-action@") }
    abort "Missing Grype scan" if before_scan == steps
    puts before_scan.find { |step| step.fetch("name", "").end_with?("accepted findings") }.fetch("run")
  ' "$root/.github/workflows/canon-cve-scan.yml" "$job" > prepare.sh

  cat > tool/.grype.yaml <<'YAML'
ignore:
  # expires: 2999-12-31; tracking: https://example.test/1; reason: pending release
  - vulnerability: CVE-2099-0001
  # expires: 2000-01-01; tracking: https://example.test/2; reason: expired
  - vulnerability: CVE-2099-0002
    package:
      name: tomcat-embed-core
      version: "11.0.29"
      type: java-archive
YAML
  if bash -e prepare.sh > output 2>&1; then fail "$job accepted an expired exception"; fi
  grep -q '^::error file=\.grype\.yaml,line=5::.*2000-01-01' output || fail "$job did not identify the expired rule in the repository"

  cp tool/.grype.yaml original.yaml
  for edit in 's/2000-01-01/2099-02-30/' '/expires: 2000-01-01/d'; do
    sed "$edit" original.yaml > tool/.grype.yaml
    if bash -e prepare.sh > output 2>&1; then fail "$job accepted an invalid expiry"; fi
    grep -q 'YYYY-MM-DD' output || fail "$job did not explain the expected expiry format"
  done

  mv original.yaml canon/.grype.yaml
  rm tool/.grype.yaml
  bash -e prepare.sh
  [[ ! -e .grype.yaml ]] || fail "$job picked up a policy from the scanned ref"

  for empty_policy in '# No accepted findings' 'ignore:' 'ignore: []'; do
    echo "$empty_policy" > tool/.grype.yaml
    bash -e prepare.sh
    cmp tool/.grype.yaml .grype.yaml || fail "$job must accept a policy without rules"
  done

  sed "s/2000-01-01/$(date -u +%F)/" canon/.grype.yaml > tool/.grype.yaml
  bash -e prepare.sh
  cmp tool/.grype.yaml .grype.yaml || fail "$job must use the exact policy through its expiry date"
done

echo "OK: both canon scans enforce Grype exception expiry"
