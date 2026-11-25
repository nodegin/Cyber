#!/usr/bin/env bash
# Update end-4's dots (illogical-impulse) and the end4-pC shell, then re-apply local fixes.
# end-4's installer is interactive and asks for sudo itself.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$HERE/backup.sh"

cd "$HOME/.cache/dots-hyprland"
git stash --include-untracked || true
git pull
git submodule update --init --recursive
./setup install

git -C "$HOME/.local/src/end4-pC" pull --ff-only
"$HERE/setup.sh"
