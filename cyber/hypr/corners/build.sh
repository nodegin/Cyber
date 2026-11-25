#!/usr/bin/env bash
# Build cybercorners.so against the installed Hyprland headers.
#   ./build.sh          build if the headers changed (a Hyprland update) or it was never built
#   ./build.sh force    always build
#   ./build.sh reload   build if needed, then reload Hyprland so it is picked up
# It refuses to build while the running Hyprland is older than the headers (updated but not yet
# logged out and in): such a build could not be loaded until then anyway.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
want=$(sed -n 's/^#define GIT_COMMIT_HASH *"\(.*\)"/\1/p' /usr/include/hyprland/src/version.h)
running=$(hyprctl version -j 2>/dev/null | sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' | head -1)
if [ -n "$running" ] && [ "$running" != "$want" ]; then
    echo "cybercorners: Hyprland was updated; log out and in, then it builds itself" >&2
    exit 0
fi
version=$(hyprctl version -j 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)
if [ "${1:-}" != force ] && [ -f cybercorners.so ] && [ "$(cat cybercorners.stamp 2>/dev/null)" = "$want $version" ]; then
    [ "${1:-}" = reload ] || echo "cybercorners: up to date"
    exit 0
fi
flags=$(pkg-config --cflags pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon)
# shellcheck disable=SC2086
g++ -O2 -shared -fPIC -std=c++2b --no-gnu-unique corners.cpp dndfix.cpp dragws.cpp -o cybercorners.so.new $flags
mv -f cybercorners.so.new cybercorners.so
echo "$want $version" > cybercorners.stamp     # Hyprland's config compares the version with hl.version()
echo "cybercorners: built for Hyprland ${version:-?}"
[ "${1:-}" = reload ] && [ -n "$version" ] && hyprctl reload >/dev/null
exit 0
