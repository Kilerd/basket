<!--
This PR is public. Don't include credentials, real container/image/volume names, `inspect`
output, environment values, hostnames, paths or screenshots from your own machine.
Title: a conventional commit, e.g. `fix(core): prune only the approved images`.
-->

## Summary

<!-- What changes and why, in a few sentences. Mention trade-offs or follow-ups. -->

Closes #

## How it was tested

<!-- Commands you ran and what you checked by hand. -->

## Screenshots

<!-- UI changes: before/after PNGs from `scripts/selftest.sh` runs on fixtures
(artifacts/selftest/<set>-<timestamp>/). Never screenshots of your real containers. -->

## Checklist

- [ ] Linked to an issue (`Closes #N`), or it is a trivial fix.
- [ ] Tests added or updated; `swift test` passes.
- [ ] `scripts/check-leaks.sh --all` is clean, and the pre-commit hook is enabled
      (`git config core.hooksPath .githooks`).
- [ ] UI changes: `scripts/selftest.sh demo`, `empty` and `stopped` and `scripts/e2e.sh demo` end
      with 0 errors and 0 warnings, I looked at the PNGs, and the screenshots above come from
      fixtures.
- [ ] New sections or controls follow the accessibility identifier contract
      (`docs/ARCHITECTURE.md` and the `contract` audit rule are updated together).
- [ ] Fixtures I added or changed contain only synthetic data in the raw CLI JSON shape.
- [ ] User-visible change: a line under `## [Unreleased]` in `CHANGELOG.md`.
- [ ] Docs updated where behaviour changed (`README.md`, `CONTRIBUTING.md`,
      `docs/ARCHITECTURE.md`, `docs/EVOLUTION.md`).
- [ ] Commits follow Conventional Commits and carry human authorship only: no AI co-author
      trailers and no "Generated with …" lines.
