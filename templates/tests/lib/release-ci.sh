#!/usr/bin/env bash

use_green_release_ci() {
  local bin="$1/release-ci-bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
sha=$(git rev-parse HEAD)
[[ $# == 18 && $1 == run && $2 == list && $3 == --repo && $4 == github.com/example/Platform &&
   $5 == --workflow && $6 == ci.yml && $7 == --branch && $8 == main &&
   $9 == --event && ${10} == push && ${11} == --commit && ${12} == "$sha" &&
   ${13} == --limit && ${14} == 1 && ${15} == --json && ${17} == --jq ]]
case "${RELEASE_CI_RESULT:-success}" in
  success) printf '%s|main|push|completed|success|https://github.com/example/Platform/actions/runs/1\n' "$sha" ;;
  missing) ;;
  wrong-sha) printf '%040d|main|push|completed|success|\n' 0 ;;
  wrong-branch) printf '%s|feature|push|completed|success|\n' "$sha" ;;
  wrong-event) printf '%s|main|pull_request|completed|success|\n' "$sha" ;;
  pending) printf '%s|main|push|in_progress||\n' "$sha" ;;
  failed) printf '%s|main|push|completed|failure|https://github.com/example/Platform/actions/runs/1\n' "$sha" ;;
  api-error) exit 1 ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

add_release_test_origin() {
  local work="$1" bare="$2" remote=https://github.com/example/Platform.git
  git -C "$work" config "url.$bare.insteadOf" "$remote"
  git -C "$work" remote add origin "$remote"
}
