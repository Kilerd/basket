# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub Security Advisories:

1. Open the repository's **Security** tab and choose **Report a vulnerability**
   (<https://github.com/Kilerd/basket/security/advisories/new>).
2. Describe the problem, the affected version or commit, the steps to reproduce it, and the
   impact you expect.

Do not open a public issue, pull request or discussion about a vulnerability until a fix has
shipped. When you send reproduction material, use synthetic data: public images, invented
names and placeholder values. Redact tokens, private image names, environment values and
`inspect` output.

Basket is maintained by volunteers, so responses are best effort. We aim to acknowledge a
report within a week, keep you updated in the advisory, and credit you in the advisory and the
changelog unless you would rather stay anonymous.

## Supported versions

Basket is in early development (`0.0.x`). Only the **latest release** and `main` receive
security fixes. A fix ships as the next patch version.

| Version | Supported |
|---|---|
| latest `0.0.x` release, `main` | yes |
| older releases | no |

## Scope

Basket is a native macOS app that drives Apple's `container` CLI. It is not sandboxed, because
it has to start that CLI. It uses the hardened runtime, has no telemetry, and makes no network
requests of its own (image pulls are done by `container`). These are the things it does that
matter for security:

- **Runs the `container` CLI** with `--format json` and with arguments built from your input
  (image references, names, ports, environment variables, mounts). It finds the CLI through
  `BASKET_CONTAINER_CLI`, the path set in Settings, the Homebrew locations or `$PATH`.
- **Reads OrbStack data, read-only.** It reads the size of OrbStack's data directory, the memory
  footprint of OrbStack's processes, and, for migration, OrbStack's Docker engine through
  `docker --context orbstack`. Only an allowlist of read-only commands is used: `image ls`,
  `image inspect`, `ps`, `inspect`, `version`, and `save -o <file>`. Basket must never start,
  stop, change or delete anything in OrbStack or Docker.
- **Writes temporary files.** A self-deleting `.command` file in the temporary directory, which
  Terminal opens for "Shell" actions; image archives (`docker save`) in a fresh temporary
  directory during migration, which is removed afterwards; and, while an image is being slimmed,
  an image archive under `~/Library/Application Support/Basket/`.
- **Performs destructive actions you confirm**, such as delete, prune, restart, stop idle
  containers and slim images. These must act only on the items you approved.

In scope, for example:

- running commands or programs that the user didn't ask for, such as shell or argument
  injection through names, image references or other values that end up in a `.command`
  file or a CLI call;
- any way to make Basket change or delete OrbStack or Docker state, or get past the read-only
  docker allowlist;
- destructive actions that touch more than the items the user approved;
- temporary files that other local users can read or overwrite, or that leak secrets
  (environment values, registry credentials);
- weaknesses in this repository's CI workflow or its leak scanner (`scripts/check-leaks.sh`)
  that could publish secrets.

Out of scope (please report these upstream instead):

- vulnerabilities in [apple/container](https://github.com/apple/container),
  Virtualization.framework, macOS, OrbStack, Docker, or the container images you run;
- attacks that need an already compromised user account or administrator access;
- the behaviour of locally built, unsigned or modified builds.

## If a secret was published

If you find a credential or personal data in this repository, its history, an issue or a CI
log, report it privately as described above instead of pointing to it in public. Rewriting git
history does not un-publish it, so the owner has to rotate the credential.
