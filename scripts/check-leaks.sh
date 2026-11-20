#!/usr/bin/env bash
# Confidentiality scan: credentials, personal paths/identities and private words must never
# reach this public repository. See AGENTS.md §1.
#
#   scripts/check-leaks.sh                 # staged content (what the next commit would publish)
#   scripts/check-leaks.sh --all           # tracked + untracked (not ignored) files in the working tree
#   scripts/check-leaks.sh --range <revs>  # every file version + message of the commits in <revs> (CI);
#                                          #   a single rev means it and all its ancestors
#   scripts/check-leaks.sh --message <f>   # a commit message file (commit-msg hook)
#
# Private words come from `.leak-denylist` (gitignored; one case-insensitive ERE per line,
# `#` comments) in this checkout or the main checkout of a linked worktree, from
# ~/.config/basket/leak-denylist, and/or the LEAK_DENYLIST environment variable (CI secret).
# Outside CI the local identity (macOS user name, full name, git e-mail) is checked too.
# Text is scanned after un-escaping JSON `\/`; binary files are scanned through `strings`.
# A line containing `leak-check: allow` is skipped. Private words and identities are never
# echoed; other matches are masked, and in CI only the rule and location are printed.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
MODE="${1:---staged}"

# name|case-insensitive(0/1)|ERE
RULES=(
  "private-key|0|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"
  "aws-access-key|0|(AKIA|ASIA)[0-9A-Z]{16}"
  "github-token|0|(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})"
  "slack-token|0|(xox[abposr]-[A-Za-z0-9-]{10,}|xapp-[0-9]-[A-Za-z0-9-]{20,})"
  "llm-api-key|0|sk-(ant-|proj-)?[A-Za-z0-9_-]{32,}"
  "google-api-key|0|(AIza[0-9A-Za-z_-]{35}|ya29\.[A-Za-z0-9_-]{20,})"
  "service-token|0|(glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36}|hf_[A-Za-z0-9]{30,}|dckr_pat_[A-Za-z0-9_-]{20,}|pypi-AgE[A-Za-z0-9_-]{50,}|(sk|rk)_live_[A-Za-z0-9]{20,})"
  "jwt|0|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
  "credential-assignment|1|(api[_-]?key|secret|token|passw(or)?d|credential)[a-z0-9_]*[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'[:space:]]{16,}[\"']"
  "credential-env|1|(api[_-]?key|secret|token|passw(or)?d|credential)[a-z0-9_]*[[:space:]]*=[[:space:]]*[^\"'[:space:]\$<{]{16,}"
  "docker-auth|1|\"auth\"[[:space:]]*:[[:space:]]*\"[A-Za-z0-9+/=]{20,}\""
  "bearer-token|1|bearer[[:space:]]+[A-Za-z0-9._~+/-]{20,}=*"
  "signing-identity|0|(Developer ID|Apple Development|Apple Distribution)( Application| Installer)?: [A-Z][^\"'()]* \([A-Z0-9]{10}\)"
  "personal-email|1|[a-z0-9._%+-]+@(gmail|googlemail|qq|163|126|outlook|hotmail|live|icloud|me|yahoo|proton|protonmail)\.(com|me)"
  "home-path|0|/Users/[A-Za-z0-9._-]+"
  "linux-home-path|0|/home/[A-Za-z0-9._-]+"
)
# Paths and values that are fine to publish.
HOME_PATH_OK='^/(Users|home)/(demo|Shared|runner|username|someone|you|me|example|user|node|app|ubuntu|debian|nonroot|vscode|linuxbrew|basket)$'
PLACEHOLDER='(basket|example|changeme|placeholder|dummy|demo|redacted|x{4,}|\*{3,}|\.\.\.)'

# Files that legitimately contain the patterns above.
SKIP_PATHS='^(scripts/check-leaks\.sh|\.githooks/(pre-commit|commit-msg))$'

DENY=()
load_denylist() {
  local line
  # The list is gitignored, so a linked worktree (agents commit from those) doesn't have its own
  # copy: also read the main checkout's, and a per-user one.
  local common main_root file files=("$ROOT/.leak-denylist")
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  main_root="$(dirname "$common")"
  [[ -n "$common" && "$main_root" != "$ROOT" ]] && files+=("$main_root/.leak-denylist")
  files+=("$HOME/.config/basket/leak-denylist")
  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"; line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -n "$line" ]] && DENY+=("$line")
    done < "$file"
  done
  if [[ -n "${LEAK_DENYLIST:-}" ]]; then
    while IFS= read -r line; do
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -n "$line" ]] && DENY+=("$line")
    done <<< "$LEAK_DENYLIST"
  fi
  return 0
}

# The local identity: things that identify the person running this, not meant for the repo.
# Skipped in CI (the runner's identity is not personal). Tokens are matched literally.
IDENTITY=()
load_identity() {
  [[ -n "${CI:-}" ]] && return 0
  local u full email
  u="$(id -un 2>/dev/null || true)"
  if [[ ${#u} -ge 3 && ! "$u" =~ ^(root|admin|user|runner|demo|test)$ ]]; then IDENTITY+=("$u"); fi
  full="$(id -F 2>/dev/null || true)"
  if [[ "$full" == *" "* ]]; then IDENTITY+=("$full"); fi
  email="$(git config user.email 2>/dev/null || true)"
  if [[ -n "$email" && "$email" != *noreply* ]]; then IDENTITY+=("$email"); fi
  return 0
}

mask() { # keep the first 4 characters
  local s="$1"
  if (( ${#s} <= 6 )); then printf '%s' "${s:0:1}***"; else printf '%s' "${s:0:4}***(${#s} chars)"; fi
}

FINDINGS=0
report() { # label rule match
  FINDINGS=$((FINDINGS + 1))
  # Private words and identities are never echoed (not even masked); CI logs are public.
  if [[ "$2" == private-word || "$2" == local-identity || -n "${CI:-}" ]]; then
    printf '  %s  [%s]\n' "$1" "$2" >&2
  else
    printf '  %s  [%s]  %s\n' "$1" "$2" "$(mask "$3")" >&2
  fi
}

# scan <label> <file-with-content>
scan() {
  local label="$1" file="$2" text_file="$TMP/text" rule name ci re hits lineno text m
  [[ -s "$file" ]] || return 0
  if grep -Iq . "$file" 2>/dev/null; then
    sed 's#\\/#/#g' "$file" > "$text_file"          # JSON escapes: \/Users\/x → /Users/x
  else
    strings -a -n 6 "$file" > "$text_file" 2>/dev/null || return 0   # PNG text chunks, icns, …
    label="$label (binary)"
  fi
  for rule in "${RULES[@]}"; do
    name="${rule%%|*}"; rule="${rule#*|}"; ci="${rule%%|*}"; re="${rule#*|}"
    if [[ "$ci" == 1 ]]; then hits="$(grep -nEi -- "$re" "$text_file" || true)"; else hits="$(grep -nE -- "$re" "$text_file" || true)"; fi
    [[ -z "$hits" ]] && continue
    while IFS= read -r lineno_text; do
      lineno="${lineno_text%%:*}"; text="${lineno_text#*:}"
      [[ "$text" == *"leak-check: allow"* ]] && continue
      if [[ "$ci" == 1 ]]; then m="$(printf '%s\n' "$text" | grep -oEi -- "$re" || true)"; else m="$(printf '%s\n' "$text" | grep -oE -- "$re" || true)"; fi
      while IFS= read -r one; do
        [[ -z "$one" ]] && continue
        case "$name" in
          home-path|linux-home-path) [[ "$one" =~ $HOME_PATH_OK ]] && continue ;;
          credential-*|docker-auth|bearer-token)
            printf '%s' "$one" | grep -qEi -- "$PLACEHOLDER" && continue ;;
        esac
        report "$label:$lineno" "$name" "$one"
      done <<< "$m"
    done <<< "$hits"
  done
  local word
  for word in ${DENY[@]+"${DENY[@]}"}; do
    hits="$(grep -nEi -- "$word" "$text_file" || true)"
    [[ -z "$hits" ]] && continue
    while IFS= read -r lineno_text; do
      lineno="${lineno_text%%:*}"; text="${lineno_text#*:}"
      [[ "$text" == *"leak-check: allow"* ]] && continue
      report "$label:$lineno" "private-word" ""
    done <<< "$hits"
  done
  if (( ${#IDENTITY[@]} > 0 )); then
    # A GitHub handle may equal the user name: repository URLs and owner/repo slugs are public.
    while IFS= read -r lineno; do
      [[ -n "$lineno" ]] && report "$label:$lineno" "local-identity" ""
    done < <(perl -ne '
      BEGIN { @ids = map { quotemeta } split /\x1f/, $ENV{BASKET_IDS} }
      next if /leak-check: allow/;
      s{\[[^\]]*\]\(https?://github\.com/[^)]*\)}{}gi;   # [handle](https://github.com/handle)
      s{(github\.com|githubusercontent\.com|ghcr\.io|github\.io)[/:][\w.-]+}{}gi;
      s{\b[\w.-]+/basket\b}{}gi;
      s{(?<![\w.])\@[\w-]+}{}g;   # @handle mentions (CODEOWNERS); e-mail addresses keep their @
      for my $id (@ids) { if (/$id/i) { print "$.\n"; last } }
    ' "$text_file")
  fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
load_denylist
load_identity
export BASKET_IDS
BASKET_IDS="$(printf '%s\x1f' ${IDENTITY[@]+"${IDENTITY[@]}"})"; BASKET_IDS="${BASKET_IDS%$'\x1f'}"

SEP=$'\x1f'   # rev/path separator (not IFS whitespace, so an empty rev survives `read`)
SCANNED=0
scan_path_list() { # reads "rev<SEP>path" lines; rev "" = working tree, ":" = index, else a commit
  local rev path out="$TMP/blob"
  while IFS="$SEP" read -r rev path; do
    [[ -z "$path" ]] && continue
    [[ "$path" =~ $SKIP_PATHS ]] && continue
    case "$rev" in
      "") [[ -f "$path" ]] || continue; cp "$path" "$out" ;;
      ":") git show ":$path" > "$out" 2>/dev/null || continue ;;
      *) git show "$rev:$path" > "$out" 2>/dev/null || continue ;;
    esac
    SCANNED=$((SCANNED + 1))
    if [[ -z "$rev" || "$rev" == ":" ]]; then scan "$path" "$out"; else scan "${rev:0:8}:$path" "$out"; fi
    # File names are published too.
    printf '%s\n' "$path" > "$out"; scan "path:$path" "$out"
  done
}

prefix() { awk -v p="$1" -v s="$SEP" '{ printf "%s%s%s\n", p, s, $0 }'; }

# Build the list in a file and scan in this shell (a pipeline would lose FINDINGS in a subshell).
LIST="$TMP/list"; : > "$LIST"
case "$MODE" in
  --staged)
    git diff --cached --name-only --diff-filter=ACMR -z | tr '\0' '\n' | prefix ":" > "$LIST" ;;
  --all)
    git ls-files -co --exclude-standard -z | tr '\0' '\n' | prefix "" > "$LIST" ;;
  --range)
    RANGE="${2:?usage: check-leaks.sh --range <rev-range>}"
    # Fails loudly on an unknown revision instead of scanning nothing.
    COMMITS="$(git rev-list "$RANGE")" || { echo "check-leaks: cannot resolve range '$RANGE'" >&2; exit 2; }
    # Each commit's version of each file it touched (root commits included), so content later
    # removed is still caught, plus every commit message.
    for c in $COMMITS; do
      git diff-tree --root --no-commit-id --name-only -r --diff-filter=ACMR -z "$c" | tr '\0' '\n' | prefix "$c" >> "$LIST"
      git log -1 --format='%B' "$c" > "$TMP/msg"; scan "commit-message:${c:0:8}" "$TMP/msg"
    done ;;
  --message)
    MSG="${2:?usage: check-leaks.sh --message <file>}"
    grep -v '^#' "$MSG" > "$TMP/msg" || true; scan "commit-message" "$TMP/msg" ;;
  *) echo "usage: $0 [--staged|--all|--range <revs>|--message <file>]" >&2; exit 64 ;;
esac
scan_path_list < "$LIST"

if (( FINDINGS > 0 )); then
  printf 'check-leaks: %d finding(s) — remove them (see AGENTS.md §1). Do not bypass with --no-verify.\n' "$FINDINGS" >&2
  exit 1
fi
printf 'check-leaks: clean (%d files, %d private words, %d identity tokens)\n' "$SCANNED" "${#DENY[@]}" "${#IDENTITY[@]}"
