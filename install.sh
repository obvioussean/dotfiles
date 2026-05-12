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

# TEMP: Skip the ~/.copilot clone in Codespaces.
#
# Something in ~/.copilot (likely the skills/ tree or settings.json) triggers
# the Copilot CLI to start MCP servers, which loads a native runtime binding
# prebuilt against GLIBC 2.33+. github/github codespaces (and any others
# pinned to Ubuntu 20.04) ship GLIBC 2.31, so the .node fails to dlopen with
# "Cannot find native binding". Until that's resolved upstream — or we bisect
# which specific file is the trigger and exclude it — bail out cleanly so the
# CLI can at least launch in Codespaces.
#
# Set FORCE_COPILOT_DOTFILES=1 to override (e.g. on a newer-base codespace).
if [[ "${CODESPACES:-}" == "true" && "${FORCE_COPILOT_DOTFILES:-}" != "1" ]]; then
  log "Codespaces detected; skipping ~/.copilot clone (GLIBC compatibility — see install.sh)."
  log "Set FORCE_COPILOT_DOTFILES=1 to override."
  exit 0
fi

if [[ -z "${OBVIOUSSEAN_PAT:-}" ]]; then
  warn "OBVIOUSSEAN_PAT is not set; skipping ${REPO} clone."
  warn "Add it as a Codespaces user secret at https://github.com/settings/codespaces"
  warn "and grant it access to ${REPO}."
  exit 0
fi

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

log "Done. ~/.copilot is ready."
