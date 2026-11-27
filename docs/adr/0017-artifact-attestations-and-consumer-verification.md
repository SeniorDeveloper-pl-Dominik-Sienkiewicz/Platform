# ADR-0017: Artifacts carry GitHub attestations, and consumers can verify them

## Status

Accepted — 2026-10-19

## Context

Consumers resolve Platform from GitHub Packages with a token. Without provenance, a compromised token or a
mistaken manual publish could put bytes into the registry that no workflow built.

## Decision

- `release.yml` attests every file it publishes with `actions/attest` (Decision 25): the jars, the catalog TOML,
  the npm tarballs and the release assets.
- `platform-bump` verifies the attestation of the package it runs (from 1.6.0 on), `backend-ci.yml` verifies every
  Platform jar with `verify-provenance: true` (PLAT-PROV-001). A weekly rebuild of the latest tag that compared
  the digests with the registry ran until 2026-11-20 and was dropped because nothing depended on it.

## Consequences

- A consumer can tell a Platform artifact from any other file with `gh attestation verify`.
- Reproducible archives are part of the contract: a release that does not rebuild to its published jars opens an
  issue.

## Revisit when

GitHub Packages offers signature verification of its own.

## Update 2026-11-27

The jars were not the whole release: the catalog TOML was attested but never verified, and `platform-bom`, which
publishes only a POM and Gradle module metadata, was neither. A substituted registry could lower the CVE floors or
point an alias elsewhere while the gate stayed green. `release.yml` now also attests the POM and module metadata of
every publication (`build/publications/*/pom-default.xml` and `module.json`, the bytes Gradle uploads), and
`backend-ci.yml` verifies every jar and catalog TOML, and the `.pom` and `.module` files of releases from 2.1.1 on.
Releases up to 2.1.0 attested no metadata, so their metadata is skipped rather than failed; consumers pinned to
them keep a green gate.
