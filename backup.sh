#!/usr/bin/env bash
# Snapshot of everything end-4's installer may overwrite, plus the package list,
# so any change can be compared or undone. No sudo needed.
set -euo pipefail
DEST="$HOME/.local/share/hypr-setup/backup-$(date +%F-%H%M%S)"
mkdir -p "$DEST"

# ~/.config without the browser profile (~220 MB, not touched by the installer)
tar -czf "$DEST/dot-config.tar.gz" -C "$HOME" --exclude='.config/zen' .config
# GTK settings the installer changes with gsettings (font, colour scheme, ...)
dconf dump /org/gnome/desktop/interface/ > "$DEST/gnome-interface.dconf"
# Installed packages, to see later exactly what the installer added: diff against `pacman -Qq`
pacman -Qq  > "$DEST/packages-all.txt"
pacman -Qqe > "$DEST/packages-explicit.txt"

ln -sfn "$DEST" "$HOME/.local/share/hypr-setup/latest"
echo "Backup written to $DEST"
echo "  restore a file:  tar -xzf $DEST/dot-config.tar.gz -C ~ .config/fontconfig"
echo "  restore GTK:     dconf load /org/gnome/desktop/interface/ < $DEST/gnome-interface.dconf"
