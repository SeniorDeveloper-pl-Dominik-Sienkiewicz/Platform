# ADR-0035: Promotion by commit replaces SSH deploy for a cluster managed by Argo CD

## Status

Accepted — 2026-11-05

Partly superseded (2026-11-20): `deploy.yml` lost its SSH deploy in 1.13.0, so the `ssh-deploy` input, the SSH path
and the callers that still deployed over SSH described below no longer exist. The decision to promote by commit holds.
Until 1.13.1 `promote.yml` keeps calling the `deploy.yml` of v1.10.1 with `ssh-deploy: false` (moved on
2026-11-27, see the update below).

## Context

`deploy.yml` builds and pushes images, then deploys them to one host over SSH
([ADR-0016](0016-production-deploys-from-the-release-branch.md)). A cluster that Argo CD keeps in sync with a Git
repository has no host to deploy to: the desired state is a commit, and a workflow that reaches into the cluster
would bypass the one place that records what runs. The consumers that still deploy over SSH must not change.

## Decision

- A consumer that targets such a cluster stops deploying over SSH and promotes instead: its release builds
  and scans the images, then commits the new image tags to the GitOps repository. Argo CD deploys the commit.
  Rolling back is reverting that commit.
- `promote.yml` is a reusable workflow that does both. Its `build` job calls `deploy.yml` with
  `ssh-deploy: false`, so building, scanning and pushing stay in one place and the SSH path is untouched:
  the input defaults to `true`, and with it nothing changes for existing callers. Its `promote` job writes the
  tags with `scripts/promote-image.sh`, taken from Platform at `platform-ref`.
- The commit is pushed with a GitHub App token that is limited to the GitOps repository and carries only
  `contents: write`, minted per run and revoked after it. The workflow passes its secrets explicitly and has no
  `concurrency` of its own, because the group of `deploy.yml` already serializes builds per application.

## Consequences

- The release workflow of a consumer no longer needs SSH secrets, `DEPLOY_PATH` or the `production` environment;
  it needs the App key as a repository secret, since environment secrets do not reach a reusable workflow
  without `secrets: inherit`. The key writes to the GitOps repository, and so indirectly to the cluster, which
  is why the caller must run it only from the release branch.
- There is no smoke test after the promotion: the runner cannot reach the cluster. Alerts and a manual check
  take its place.
- The build runs in a nested reusable workflow, called by its full reference at a commit. Version 1.8.9 used `./`,
  and its first real runs failed at startup with "workflow was not found": when a caller pins an annotated tag,
  GitHub looks a relative reference up at the tag object instead of its commit
  ([reported bug, no date for a fix](https://github.com/orgs/community/discussions/206746)). Platform's tags are
  annotated because they carry the changelog ([ADR-0002](0002-release-and-versioning-contract.md)).
- A change to `deploy.yml` reaches `promote.yml` only when that pin moves, in a later release; `RELEASING.md` has the
  step.
- Nothing is committed when the build fails. The App token and the push run in the own job of `promote.yml`, not in
  the nested call.

## Revisit when

The build moves out of `deploy.yml` into a workflow of its own that both `deploy.yml` and `promote.yml` call.
That is future work: it would change the SSH path, which has no tests that execute it, and would require
rewriting the tests that pin `deploy.yml`. Until then `promote.yml` wraps `deploy.yml`.

GitHub resolves a relative reference at the commit of an annotated tag. `promote.yml` can then return to `./`, and the
pin goes.

## Update (2026-11-27)

The pin stayed at v1.10.1 past 1.13.1, so promotions kept building with the `deploy.yml` of 1.10.1: none of the
later action bumps, registry changes or gate fixes reached the only production path. `promote.yml` now calls the
`deploy.yml` of v2.1.0 by the commit of that tag, without `ssh-deploy` and `platform-ref`, which that `deploy.yml`
no longer declares; `platform-ref` stays an input of `promote.yml`, whose `promote` job takes
`scripts/promote-image.sh` from it. The other inputs, the secrets and the `backend-tag` and `frontend-tag` outputs are
unchanged. `templates/tests/promote-workflow.test.sh` now fails on a pin older than v2.1.0, on a pin whose SHA is not
the commit of its tag when the tag is present, and on an input that the `deploy.yml` in the tree does not declare.

The certificate subject of a promoted image ends in the pinned commit, so the subject changes with the pin. A cluster
whose admission policy matches the documented `deploy.yml@` regular expression needs nothing; one that pins
`deploy.yml@d88288965f4377fbab95db2f850aa70a1d0a2d3f` must allow
`deploy.yml@1337c3f7db80b969d4462d9728c4c95bd03a5c47` before it promotes with the release that carries this pin.
Changes to `deploy.yml` after 2.1.0 reach promotions only after the next release and another pin move.
