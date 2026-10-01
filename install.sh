#!/bin/bash
# Installs wallpaper-picker for the current user:
#   - copies example config on first run (never overwrites yours)
#   - symlinks the systemd user units and .desktop launchers into place
#   - enables + starts the timer
#
# Safe to re-run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
APPS_DIR="$HOME/.local/share/applications"
WALLPAPER_CONFIG_DIR="$HOME/.config/wallpaper"

log() { echo "[install] $*"; }

for bin in feh curl jq python3; do
    command -v "$bin" >/dev/null 2>&1 || log "warning: '$bin' not found on PATH -- required at runtime"
done
python3 -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null \
    || log "warning: python-gobject (GTK3) not found -- required for --gui"

mkdir -p "$SYSTEMD_USER_DIR" "$APPS_DIR" "$WALLPAPER_CONFIG_DIR" "$HOME/Pictures/wallpapers/online"

log "Linking systemd user units..."
ln -sfn "$REPO_DIR/systemd/wallpaper.service" "$SYSTEMD_USER_DIR/wallpaper.service"
ln -sfn "$REPO_DIR/systemd/wallpaper.timer" "$SYSTEMD_USER_DIR/wallpaper.timer"

log "Linking .desktop launchers..."
ln -sfn "$REPO_DIR/desktop/change-wallpaper.desktop" "$APPS_DIR/change-wallpaper.desktop"
ln -sfn "$REPO_DIR/desktop/select-wallpaper.desktop" "$APPS_DIR/select-wallpaper.desktop"
ln -sfn "$REPO_DIR/desktop/wallpaper-gallery.desktop" "$APPS_DIR/wallpaper-gallery.desktop"

if [[ ! -f "$WALLPAPER_CONFIG_DIR/categories.conf" ]]; then
    log "Seeding categories.conf from example (edit this -- it's your search queries)"
    cp "$REPO_DIR/config/categories.conf.example" "$WALLPAPER_CONFIG_DIR/categories.conf"
fi
if [[ ! -f "$WALLPAPER_CONFIG_DIR/blacklist.txt" ]]; then
    cp "$REPO_DIR/config/blacklist.txt.example" "$WALLPAPER_CONFIG_DIR/blacklist.txt"
fi

log "Reloading systemd user units..."
systemctl --user daemon-reload
systemctl --user enable --now wallpaper.timer

cat <<EOF

Done.
  - Edit your categories: $WALLPAPER_CONFIG_DIR/categories.conf
  - Try it now:           $REPO_DIR/bin/wallpaper.sh --gui
  - Change interval:      $REPO_DIR/bin/wallpaper.sh --interval 1h
  - Turn auto-run off:    $REPO_DIR/bin/wallpaper.sh --timer-disable
  - Check timer status:   $REPO_DIR/bin/wallpaper.sh --timer-status

Add this to your shell rc for a quick alias:
  alias change-wallpaper="$REPO_DIR/bin/wallpaper.sh"
EOF
