#!/bin/bash

# NODAR SDK installation module
# Usage: ./install.sh -uuid <uuid|download-url> [-activation-key <key>]
#
# Wraps NODAR's own nodar-quickstart.sh (fetched fresh from docs.nodarsensor.net)
# to install the hammerhead and nodar_viewer .deb packages, then activates the
# node-locked licence.
#
# Run as a normal user with sudo rights, like the rest of this repo - the
# packages, dataset and licence all belong to that user's home directory.
#
# Exit codes:
#   0  installed (and activated, or already activated)
#   1  install failed
#   2  packages installed but the licence is NOT activated

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@"
}

QUICKSTART_URL="https://docs.nodarsensor.net/sdk/nodar-quickstart.sh"
MASTER_CONFIG_URL="https://dz2ajpir85e0i.cloudfront.net/files/docs/config/master_config.ini"
# Backstop only, on the piped path. Activation is normally seconds - a good key
# writes license.enc, a bad one exits by itself - but it contacts a licence
# server, so a stalled network call could otherwise hang an unattended install.
# The interactive path is deliberately unbounded: you may be fetching the key.
ACTIVATION_TIMEOUT=120

UUID=""
ACTIVATION_KEY=""
# The user the SDK belongs to, derived the same way hammerhead/install.sh picks
# the account its service runs as - the licence must land where that user reads it.
RUN_USER="${SUDO_USER:-$USER}"

USAGE="Usage: $0 -uuid <uuid|download-url> [-activation-key <key>]"

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -uuid)
      UUID="$2"
      shift 2
      ;;
    -activation-key)
      ACTIVATION_KEY="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo "$USAGE"
      exit 1
      ;;
  esac
done

# Running under sudo would drop the packages, licence and config into /root
# while the hammerhead service reads them from your home. Refuse rather than
# install into the wrong place. (Genuine root-only systems have no SUDO_USER.)
if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ]; then
  echo "Error: run this without sudo, as $SUDO_USER - the SDK, its licence and its"
  echo "       config belong to your user. The scripts call sudo where they need it."
  exit 1
fi

USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "Error: Could not resolve a home directory for user '$RUN_USER'."
  exit 1
fi

NODAR_DIR="$USER_HOME/.config/nodar"
UUID_CACHE="$NODAR_DIR/uuid.txt"
LICENSE_FILE="$NODAR_DIR/license.enc"
CONFIG_DIR="$NODAR_DIR/config"

# The quickstart caches the UUID after a successful run, so re-installs need no flag.
if [ -z "$UUID" ] && [ -f "$UUID_CACHE" ]; then
  UUID="$(tr -d '[:space:]' < "$UUID_CACHE")"
  log "Using cached UUID from $UUID_CACHE"
fi

if [ -z "$UUID" ]; then
  echo "Error: No UUID given and none cached at $UUID_CACHE."
  echo "Pass -uuid <uuid or download-url> (NODAR sends both by email)."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Installing the NODAR SDK for user '$RUN_USER' (home: $USER_HOME)..."

# Dependencies required by nodar-quickstart.sh
MISSING=()
command -v wget >/dev/null 2>&1 || MISSING+=("wget")
command -v jq >/dev/null 2>&1 || MISSING+=("jq")
command -v unzip >/dev/null 2>&1 || MISSING+=("unzip")
command -v curl >/dev/null 2>&1 || MISSING+=("curl")
command -v lsb_release >/dev/null 2>&1 || MISSING+=("lsb-release")

if [ "${#MISSING[@]}" -gt 0 ]; then
  log "Installing missing dependencies: ${MISSING[*]}"
  sudo apt-get install -y "${MISSING[@]}" || {
    sudo apt-get update
    sudo apt-get install -y "${MISSING[@]}"
  }
fi

# The quickstart needs nvcc to pick which build to download and hard-errors
# without it; on Jetson /usr/local/cuda/bin is often not on PATH. CUDA_BIN stays
# empty when nvcc was already there, so we only touch .bashrc if we added it.
CUDA_BIN=""
if ! command -v nvcc >/dev/null 2>&1; then
  if [ ! -x /usr/local/cuda/bin/nvcc ]; then
    echo "Error: nvcc not found on PATH or at /usr/local/cuda/bin."
    echo "Put the CUDA toolkit you want to build against on PATH, then re-run."
    exit 1
  fi
  CUDA_BIN="/usr/local/cuda/bin"
  export PATH="$CUDA_BIN:$PATH"
fi
# The version here is what the quickstart matches builds against.
log "CUDA $(nvcc --version 2>/dev/null | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p') ($(command -v nvcc))"

# Persist for interactive shells only - the hammerhead service neither reads
# ~/.bashrc nor needs nvcc. Appended once, never rewritten.
if [ -n "$CUDA_BIN" ]; then
  BASHRC="$USER_HOME/.bashrc"
  CUDA_LINE="export PATH=$CUDA_BIN:\$PATH"
  if [ -f "$BASHRC" ] && grep -qxF "$CUDA_LINE" "$BASHRC"; then
    log "$BASHRC already puts $CUDA_BIN on PATH"
  else
    printf '%s\n' "$CUDA_LINE" >> "$BASHRC"
    log "Appended '$CUDA_LINE' to $BASHRC"
  fi
fi

# Fetch NODAR's quickstart script
QUICKSTART="$TMP_DIR/nodar-quickstart.sh"
log "Downloading nodar-quickstart.sh from $QUICKSTART_URL..."
if ! curl -fsSL "$QUICKSTART_URL" -o "$QUICKSTART"; then
  echo "Error: Could not download $QUICKSTART_URL"
  echo "Check this device's internet access, then re-run."
  exit 1
fi

# --install, never --run (--run launches the viewer and starts playback). `yes`
# answers the quickstart's internal `sudo apt-get install` prompt: we cannot add
# -y inside someone else's script and APT_CONFIG does not survive sudo's
# env_reset. Safe - with --install the quickstart reads nothing from stdin.
log "Running nodar-quickstart.sh --install (downloads the .deb packages and a sample dataset)..."
yes | bash "$QUICKSTART" "$UUID" --install

if ! command -v hammerhead >/dev/null 2>&1; then
  echo "Error: hammerhead is still not on PATH after the install."
  exit 1
fi

# master_config.ini is mostly generic defaults, so a template helps. The other
# two are calibration: the published samples carry another system's numbers, so
# seeding them would make Hammerhead emit wrong depth instead of failing loudly.
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_DIR/master_config.ini" ]; then
  log "Keeping existing $CONFIG_DIR/master_config.ini"
elif curl -fsSL "$MASTER_CONFIG_URL" -o "$TMP_DIR/master_config.ini"; then
  cp "$TMP_DIR/master_config.ini" "$CONFIG_DIR/master_config.ini"
  log "Seeded template $CONFIG_DIR/master_config.ini (edit your camera serials and filters)"
else
  log "Warning: could not download the master_config.ini template from $MASTER_CONFIG_URL"
fi

for f in extrinsics intrinsics; do
  [ -f "$CONFIG_DIR/$f.ini" ] || \
    log "Note: $CONFIG_DIR/$f.ini missing - your calibration, no template installed on purpose (docs.nodarsensor.net/config/$f.html)"
done

# Licence activation
# Hammerhead has no activation flag or environment variable: it prompts on stdin
# and writes license.enc, so activation means genuinely starting it. No -c/-s
# needed: the licence step runs before any config load or camera search, so it
# never gets far enough to care. Wait for the licence, then stop it.
run_activation() {
  local key="$1" pid

  if [ -n "$key" ]; then
    log "Activating the licence (key supplied)..."
    printf '%s\n' "$key" | timeout "$ACTIVATION_TIMEOUT" hammerhead > "$TMP_DIR/activate.log" 2>&1 &
  else
    log "Starting Hammerhead so you can type your activation key (from your NODAR email)."
    hammerhead < /dev/tty > /dev/tty 2>&1 &
  fi
  pid=$!

  # Wait for the licence to appear, or for hammerhead to exit (a rejected key
  # exits by itself; the piped path is also capped by timeout above).
  while :; do
    [ -s "$LICENSE_FILE" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 2
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true

  if [ -s "$LICENSE_FILE" ]; then
    log "Licence activated: $LICENSE_FILE"
    return 0
  fi

  log "Warning: activation did not produce $LICENSE_FILE"
  if [ -f "$TMP_DIR/activate.log" ]; then
    log "Last lines of the activation attempt:"
    tail -n 15 "$TMP_DIR/activate.log" || true
  fi
  return 1
}

# A terminal we can actually open. /dev/tty's node exists even when the process
# has no controlling terminal, so [ -e /dev/tty ] would wrongly pass under
# systemd or cron and we would launch Hammerhead only for the redirect to fail.
have_tty() { { : >/dev/tty; } 2>/dev/null; }

ACTIVATED=false
if [ -s "$LICENSE_FILE" ]; then
  log "Licence already present ($LICENSE_FILE); skipping activation."
  ACTIVATED=true
elif [ -n "$ACTIVATION_KEY" ] && run_activation "$ACTIVATION_KEY"; then
  ACTIVATED=true
elif have_tty && run_activation ""; then
  # Reached when no key was given, or when the one supplied was rejected (the
  # key is definitely read from stdin - that is verified). Either way, let the
  # user type one at Hammerhead's own prompt.
  ACTIVATED=true
fi

log "=========================================="
if [ "$ACTIVATED" = true ]; then
  log "NODAR SDK installed and activated."
  log "=========================================="
  exit 0
fi

log "NODAR SDK installed, but the licence is NOT activated."
log "Activate it by running 'hammerhead' once and entering the key from your NODAR email."
log "=========================================="
exit 2
