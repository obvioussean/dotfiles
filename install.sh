#!/usr/bin/env bash
# Codespaces dotfiles install script.
#
# Clones obvioussean/.copilot into ~/.copilot using the OBVIOUSSEAN_PAT
# Codespaces user secret. The .copilot repo's own .gitignore keeps secrets
# (mcp-config.json, mcp-oauth-config/, session state, etc.) out of the
# checkout, so what lands here is just skills, instructions, and settings.

set -euo pipefail

readonly REPO="obvioussean/.copilot"
readonly DEST="${HOME}/.copilot"

log() { printf '[dotfiles] %s\n' "$*"; }
warn() { printf '[dotfiles] WARN: %s\n' "$*" >&2; }

if [[ -z "${OBVIOUSSEAN_PAT:-}" ]]; then
  warn "OBVIOUSSEAN_PAT is not set; skipping ${REPO} clone."
  warn "Add it as a Codespaces user secret at https://github.com/settings/codespaces"
  warn "and grant it access to ${REPO}."
  CLONE_COPILOT=0
else
  CLONE_COPILOT=1
fi

if [[ "${CLONE_COPILOT}" == "1" ]]; then

# Use a credential helper that reads the PAT from the environment so the
# token never ends up in the remote URL or in ~/.git-credentials on disk.
git_with_pat() {
  git \
    -c credential.helper= \
    -c "credential.helper=!f() { echo username=x-access-token; echo password=${OBVIOUSSEAN_PAT}; }; f" \
    "$@"
}

clone_url="https://github.com/${REPO}.git"

if [[ -d "${DEST}/.git" ]]; then
  log "${DEST} already exists; pulling latest."
  git_with_pat -C "${DEST}" fetch --quiet origin
  git_with_pat -C "${DEST}" reset --hard --quiet origin/HEAD
elif [[ -e "${DEST}" ]]; then
  # Directory exists but isn't a git repo — clone into a temp dir and rsync
  # the tracked files in so we don't clobber any runtime state the CLI
  # may have written before this script ran.
  log "${DEST} exists but is not a git checkout; merging in tracked files."
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  git_with_pat clone --quiet --depth 1 "${clone_url}" "${tmp}/copilot"
  rsync -a --exclude='.git' "${tmp}/copilot/" "${DEST}/"
  # Move the .git dir over so future runs hit the fast-path above.
  mv "${tmp}/copilot/.git" "${DEST}/.git"
else
  log "Cloning ${REPO} into ${DEST}."
  mkdir -p "$(dirname "${DEST}")"
  git_with_pat clone --quiet --depth 1 "${clone_url}" "${DEST}"
fi

## Scrub any node_modules / package-lock.json that might have been brought
## over from a non-Linux machine. The Copilot CLI's bundled MCP servers will
## reinstall their native deps for the codespace's arch on first launch;
## leaving Mac-built binaries in place triggers npm's optional-deps bug
## (https://github.com/npm/cli/issues/4828) with "Cannot find native binding".
if [[ -d "${DEST}/installed-plugins" ]]; then
  log "Scrubbing pre-built node_modules under installed-plugins/."
  find "${DEST}/installed-plugins" -type d -name node_modules -prune -exec rm -rf {} + 2>/dev/null || true
  find "${DEST}/installed-plugins" -type f -name package-lock.json -delete 2>/dev/null || true
fi
fi  # CLONE_COPILOT

## Install + configure atuin for cross-codespace shell history sync.
## Requires three Codespaces user secrets:
##   ATUIN_USERNAME, ATUIN_PASSWORD, ATUIN_KEY
## Get these by running on your Mac:
##   brew install atuin
##   atuin register -u <username> -e <email>   # choose a password
##   atuin key                                 # prints the encryption key
install_atuin() {
  if command -v atuin >/dev/null 2>&1; then
    log "atuin already installed ($(atuin --version 2>/dev/null))."
  else
    log "Installing atuin."
    if ! curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | bash >/dev/null 2>&1; then
      warn "atuin install failed; skipping shell history sync."
      return 0
    fi
    # The setup script drops the binary into ~/.atuin/bin — make sure it's on PATH.
    export PATH="${HOME}/.atuin/bin:${PATH}"
  fi

  # Wire atuin into bash and zsh. Idempotent — only adds the line if missing.
  local init_marker='# >>> atuin init >>>'
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "${rc}" ]] || touch "${rc}"
    if ! grep -qF "${init_marker}" "${rc}"; then
      local rc_basename="${rc##*/}"
      local shell_name="${rc_basename#.}"
      shell_name="${shell_name%rc}"
      cat >> "${rc}" <<EOF

${init_marker}
# atuin replaces shell history with a synced, searchable backend.
# Toggle off for one session with: ATUIN_NOBIND=true bash
[[ -x "\${HOME}/.atuin/bin/atuin" ]] && export PATH="\${HOME}/.atuin/bin:\${PATH}"
command -v atuin >/dev/null 2>&1 && eval "\$(atuin init ${shell_name})"
# <<< atuin init <<<
EOF
      log "Added atuin init to ${rc}."
    fi
  done

  # Auto-login + sync if credentials are available as Codespaces secrets.
  if [[ -n "${ATUIN_USERNAME:-}" && -n "${ATUIN_PASSWORD:-}" && -n "${ATUIN_KEY:-}" ]]; then
    if [[ ! -f "${HOME}/.local/share/atuin/session" ]]; then
      log "Logging in to atuin sync as ${ATUIN_USERNAME}."
      if atuin login -u "${ATUIN_USERNAME}" -p "${ATUIN_PASSWORD}" -k "${ATUIN_KEY}" >/dev/null 2>&1; then
        atuin sync >/dev/null 2>&1 || warn "atuin login succeeded but initial sync failed (will retry next shell)."
      else
        warn "atuin login failed — check ATUIN_USERNAME / ATUIN_PASSWORD / ATUIN_KEY secrets."
      fi
    else
      log "atuin already logged in; skipping login."
    fi
  else
    log "atuin credentials (ATUIN_USERNAME/PASSWORD/KEY) not set; install-only, no sync."
  fi
}

install_atuin

log "Done. ~/.copilot is ready."
