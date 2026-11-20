# The `docker` shim

`alias docker=container` breaks quickly: apple/container names its subcommands differently
(`list`, `delete`, `image list`, `registry login`) and its flags only partly match Docker's. Basket
ships a small translating command instead, `basket-docker`, which takes a docker command line,
rewrites it for Apple's `container` CLI and runs that. When turned on, it's installed as
`~/.basket/bin/docker`, so muscle memory and scripts keep working after leaving OrbStack or
Docker Desktop.

- **Translator**: `Sources/BasketCore/DockerShim/DockerCommandTranslator*.swift`. Pure function
  `DockerCommandTranslator.translate(_:) -> DockerTranslation`, table-tested in
  `Tests/BasketCoreTests/DockerCommandTranslatorTests.swift`.
- **Executable**: `Sources/basket-docker/`. Finds `container` the same way the app does
  (`BASKET_CONTAINER_CLI` → the path from Basket's settings → Homebrew → `/usr/local/bin` → `PATH`),
  prints warnings to stderr, then `execv`s `container`, so stdin, stdout, stderr, the TTY
  (`docker exec -it`), signals and the exit code pass through unchanged. Commands that become
  several `container` calls (`restart`, `build -t a -t b`) run one after the other and stop at the
  first failure.
- **Installer**: `DockerShimInstaller` (BasketCore), driven by the onboarding window and Settings.
- **Bundle**: `scripts/build-app.sh` puts the binary at `Basket.app/Contents/Helpers/basket-docker`
  and signs it with the app's identity (hardened runtime) before it signs the app.

## Behaviour

| Situation | What the shim does |
|---|---|
| Flag with an apple/container equivalent | translated (`-p`, `-v`, `-e`, `--rm`, …) |
| Flag with no equivalent that doesn't change what you get | dropped, `WARNING: ignoring --restart: …` on stderr |
| Flag whose absence would change what you get | refused: message on stderr, exit code 125 (Docker's code for CLI errors), nothing runs |
| Unknown flag or command | refused the same way |
| `docker <cmd> --help` | shows `container <cmd> --help`, with a note that docker flags are translated |
| `docker`, `docker --help`, `docker help` | short help listing the supported commands |
| `docker … prune` without `-f` | asks `Are you sure you want to continue? [y/N]` first, like Docker |
| `BASKET_DOCKER_DRYRUN=1 docker …` | prints the `container` command(s) instead of running them (same warnings and refusals) |

Exit codes: `container`'s own exit code; 125 for refused commands; 127 when the `container` CLI
isn't installed; 1 when a prune prompt is declined.

## Mapping

Verified against `container` 1.7.1 (`container <cmd> --help`, plus test containers for the
value formats).

### Containers

| docker | container | Notes |
|---|---|---|
| `ps [-a] [-q]`, `container ls` | `list [--all] [--quiet]` | `--no-trunc` ignored; `-s` dropped; `--filter`, `-n`, `-l` refused |
| `run`, `create` | `run`, `create` | flags below; everything after the image is passed as is |
| `start [-a] [-i] C…` | `start [--attach] [--interactive] C` | one `start` per container |
| `stop [-t N] [-s SIG] C…` | `stop [--time N] [--signal SIG] C…` | |
| `restart [-t N] C…` | `stop [--time N] C…` then `start C` for each | refused for containers started with `--rm` (apple/container deletes those when they stop) |
| `kill [-s SIG] C…` | `kill [--signal SIG] C…` | |
| `rm [-f] C…` | `delete [--force] C…` | `-v` dropped (anonymous volumes stay; remove them with `docker volume rm`) |
| `logs [-f] [--tail N\|-n N] C` | `logs [--follow] [-n N] C` | `--tail all` = no `-n`; `--since`, `--until`, `-t` dropped |
| `exec [-d] [-i] [-t] [-e] [--env-file] [-u] [-w] C CMD…` | `exec …` (same flags) | `--privileged` refused |
| `inspect [--type T] X…` | `inspect` / `image inspect` / `volume inspect` / `network inspect` | without `--type`, X is a container; `-f` Go templates refused (`-f json` ok) |
| `cp SRC DST` | `copy SRC DST` | `-` (tar stream) refused; `-a`, `-L` dropped |
| `stats [--no-stream] [C…]` | `stats [--no-stream] [C…]` | `-a` dropped (running containers only) |
| `commit C IMAGE` | `commit C IMAGE` | `-a`, `-m` dropped; `-c` refused; an image name is required |
| `export [-o F] C` | `export [--output F] C` | |
| `container prune [-f]` | `prune` | asks first unless `-f` |

### `run` / `create` flags

| Kept | `-d` (run only), `-i`, `-t`, `--name`, `-e/--env`, `--env-file`, `--rm`, `-w`, `-u`, `--entrypoint`, `-l/--label`, `--mount`, `-m/--memory`, `--platform`, `--init`, `--read-only`, `--tmpfs`, `--dns`, `--dns-search`, `--dns-option`/`--dns-opt`, `--cap-add`, `--cap-drop`, `--ulimit`, `--shm-size`, `--cidfile` |
|---|---|
| Translated | `-p 80` → `-p 80:80` (no random host ports; also `ip::80`); `-v src:dst:cached` → options `cached`, `delegated`, `consistent`, `z`, `Z`, `nocopy` removed; `--cpus 1.5` → `--cpus 2` (whole CPUs); `--network bridge` → default network; `-q` → `--progress none` |
| Dropped with a warning | `--restart`, `--health-*`, `--no-healthcheck`, `--log-driver`, `--log-opt`, `--pull` (pulls only when missing), `-a/--attach`, `-h/--hostname` (the hostname is the container name), `--domainname`, `--expose`, `--stop-signal`, `--stop-timeout`, `--runtime`, `-c/--cpu-shares` and other CPU/memory/blkio tuning, `--network-alias`, `--ip`, `--ip6`, `--mac-address`, `--security-opt`, `--sysctl`, `--group-add`, `--cgroup-parent`, `--storage-opt`, `--annotation`, `--isolation`, `--volume-driver`, `--detach-keys` |
| Ignored (same as the default) | `--disable-content-trust`, `--sig-proxy`, `--restart no`, `--pull missing` |
| Refused | `--privileged`, `--gpus`, `--device`, `--device-cgroup-rule`, `--add-host`, `-P/--publish-all`, `--network host`, `--network container:…`, `--pid`/`--ipc`/`--uts`/`--userns`/`--cgroupns` `host` or `container:…`, `--volumes-from`, `--link`, `--label-file`, `--use-api-socket` |

Note: Docker's `-c` means `--cpu-shares` and `-a` means `--attach`; in apple/container they mean
`--cpus` and `--arch`, which is why the shim never passes unknown short flags through.

### Images

| docker | container | Notes |
|---|---|---|
| `images`, `image ls` | `image list` | `-q` → `--quiet`, `--digests` → `--verbose`; `-a`, `--no-trunc` ignored; a REPOSITORY filter, `--filter`, `--tree` refused |
| `pull IMAGE` | `image pull --platform linux/arm64 IMAGE` | Docker pulls only the host's platform; without `--platform`, apple/container stores every variant of a multi-arch image. An explicit `--platform` wins. `-q` → `--progress none`; `-a` refused |
| `push IMAGE` | `image push IMAGE` | `--platform` kept; `-a` refused |
| `tag SRC DST` | `image tag SRC DST` | |
| `rmi [-f] IMAGE…`, `image rm` | `image delete [--force] IMAGE…` | apple/container's `--force` ignores missing images |
| `save [-o F] IMAGE…` | `image save [--output F] IMAGE…` | without `-o` the archive goes to stdout, as with Docker |
| `load [-i F]` | `image load [--input F]` | without `-i` it reads stdin |
| `image inspect IMAGE…` | `image inspect IMAGE…` | |
| `image prune [-a] [-f]` | `image prune [--all]` | asks first unless `-f` |
| `build [-t T…] [CONTEXT]`, `buildx build`, `image build` | `build [--tag T] [CONTEXT]` | extra `-t` → `image tag`; `--push` → `image push` per tag |

`build` keeps `-f`, `--build-arg`, `--target`, `--no-cache`, `--platform`, `--progress`
(`quiet` → `--quiet`, others → `plain`), `-q`, `--label`, `--pull`, `--secret`, `--ssh`,
`-o/--output`, `-m`; ignores `--load`, `--rm`, `--force-rm`; drops cache, metadata and builder
tuning flags with a warning; refuses `-f -`, URL/git/stdin contexts, `--add-host`,
`--build-context`, `--call`, `--check`.

### Volumes, networks, registry, system

| docker | container | Notes |
|---|---|---|
| `volume create [--name] NAME` | `volume create NAME` | `--label`, `-o` → `--opt`; `-d local` ignored, other drivers refused; a name is required |
| `volume ls [-q]` | `volume list [--quiet]` | |
| `volume rm NAME…` | `volume delete NAME…` | `-f` dropped |
| `volume inspect NAME…` | `volume inspect NAME…` | |
| `volume prune --all [-f]` | `volume prune` | apple/container also removes unused *named* volumes, which Docker does only with `--all`; without it the shim refuses |
| `network create NAME` | `network create NAME` | `--subnet` (IPv6 → `--subnet-v6`), `--internal`, `--label`, `-o` → `--option`; `-d bridge` ignored; `--gateway`, `--ip-range`, other drivers refused |
| `network ls`, `rm`, `inspect`, `prune` | `network list`, `delete`, `inspect`, `prune` | prune asks first unless `-f`; `connect`/`disconnect` refused |
| `login [-u U] [--password-stdin] [SERVER]` | `registry login [--username U] [--password-stdin] SERVER` | no server = `docker.io`; `https://index.docker.io/v1/` → `docker.io`; `http://` → `--scheme http`; `-p` refused (use `--password-stdin`) |
| `logout [SERVER]` | `registry logout SERVER` | |
| `version` | `system version` | `-f json` ok |
| `info`, `system info` | `system status` | |
| `system df` | `system df` | `-v` dropped |
| `system prune [-a] [-f]` | `prune`, `network prune`, `image prune [--all]` | asks first unless `-f`; build cache isn't pruned; `--volumes` refused |
| `--version`, `-v` | `--version` | |
| `-D/--debug` | `--debug` before the subcommand | |

`--format json` works where apple/container has JSON output (`ps`, `images`, `volume ls`,
`network ls`, `stats`, `system df`, `version`, `info`), with a warning that the fields are
apple/container's. Go templates (`--format '{{.Names}}'`) are refused.

### Not supported

- `docker compose …`: use Basket's **Containers → Compose Up…** (⇧⌘O). Hook for a future
  helper: if `BASKET_COMPOSE_CLI` names an executable, or an executable `basket-compose` sits next
  to the running shim, `docker compose ARGS…` execs it with `ARGS…`
  (`DockerTranslation.delegate`).
- Global `--context`, `-c`, `-H/--host`, `--config`, `--tls*`: the shim always talks to the local
  apple/container service. OrbStack and other engines keep their own `docker` binary.
- `attach`, `diff`, `events`, `history`, `import`, `pause`, `unpause`, `port`, `rename`, `search`,
  `top`, `update`, `wait`, `network connect/disconnect`, swarm, plugins, contexts, `buildx` other
  than `build`.

## Shell integration

`DockerShimInstaller` (public API used by the onboarding window and Settings):

- `install()` copies the bundled `basket-docker` to `~/.basket/bin/docker` (temp file + rename,
  mode 0755, quarantine attribute removed) and adds a marked block to the login shell's rc file:
  zsh `~/.zshrc`; bash `~/.bash_profile` (or `~/.bash_login` / `~/.profile` when one of those
  already exists, because a new `.bash_profile` would stop bash from reading `.profile`); fish
  `~/.config/fish/conf.d/basket.fish`. Idempotent: an up-to-date block is left alone, an older one
  is replaced in place.
- The block puts `~/.basket/bin` first on `PATH`, so `docker` resolves to the shim ahead of
  `/usr/local/bin/docker` (OrbStack, Docker Desktop):

  ```sh
  # >>> basket docker shim >>>
  # Added by Basket: `docker` runs Apple's container CLI via ~/.basket/bin/docker.
  # Turn it off in Basket's settings, or delete this block.
  case ":$PATH:" in
    *":$HOME/.basket/bin:"*) ;;
    *) export PATH="$HOME/.basket/bin:$PATH" ;;
  esac
  # <<< basket docker shim <<<
  ```

- rc files are edited only between the markers. Symlinked rc files (dotfile repos) are written
  through the link, permissions are kept, and the file is copied once to `<rc>.basket-backup`
  before Basket first changes it. A start marker without an end marker makes `install()` fail
  without touching anything.
- `uninstall()` removes the block (and the blank line Basket put before it) from every rc file it
  may have written, deletes rc files Basket created and that are now empty, and removes
  `~/.basket/bin/docker` (plus `~/.basket/bin` and `~/.basket` if they end up empty). Backups stay.
- `refreshShimIfNeeded()` replaces an outdated `~/.basket/bin/docker` after an app update.
- `status()` reports whether the shim and a block are present, the rc files with a block, the login
  shell, which `docker` a new shell would run and whether that's OrbStack's.
- `plannedChanges()` returns the rc file and the exact block `install()` adds, for the UI to show
  before the user agrees.

Open terminals keep their old `PATH`; new ones pick up the shim. To compare with the real Docker
CLI while the shim is on, call it by path (`/usr/local/bin/docker`).
