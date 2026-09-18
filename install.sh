#!/bin/bash
# lumaloop - subject-weighted auto exposure for USB webcams
# Copyright (C) 2026 ktv23
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Install (or remove) lumaloop for the current user. No root needed.
#
# The scripts are symlinked rather than copied, so `git pull` in this checkout
# updates what is installed. The .desktop file is generated, because a desktop
# entry cannot use ~ or $HOME in Exec.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
bindir="${XDG_BIN_HOME:-$HOME/.local/bin}"
appdir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
unitdir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
confdir="${XDG_CONFIG_HOME:-$HOME/.config}/lumaloop"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -fv "$bindir/lumaloop" "$bindir/lumaloop-app" \
           "$appdir/lumaloop.desktop" "$unitdir/lumaloop.service"
    echo
    echo "Left alone: $confdir (your settings)"
    echo "Run: systemctl --user daemon-reload"
    exit 0
fi

link() {
    mkdir -p "$(dirname "$2")"
    ln -sfn "$here/$1" "$2"
    printf '  %-12s -> %s\n' "$1" "$2"
}

echo "Installing:"
link lumaloop         "$bindir/lumaloop"
link lumaloop-app     "$bindir/lumaloop-app"
link lumaloop.service "$unitdir/lumaloop.service"

mkdir -p "$appdir"
# rm first: an earlier version of this script symlinked the desktop entry into
# the checkout, and redirecting onto a surviving symlink writes THROUGH it,
# putting a machine-specific Exec path back into the repo.
rm -f "$appdir/lumaloop.desktop"
sed "s|@BINDIR@|$bindir|" "$here/lumaloop.desktop.in" > "$appdir/lumaloop.desktop"
printf '  %-12s -> %s\n' "lumaloop.desktop" "$appdir/lumaloop.desktop"

mkdir -p "$confdir"
if [[ -e "$confdir/config.toml" ]]; then
    printf '  %-12s    kept (already exists)\n' "config.toml"
else
    cp "$here/config.example.toml" "$confdir/config.toml"
    printf '  %-12s -> %s\n' "config.toml" "$confdir/config.toml"
fi

# Report what is missing rather than failing: the pipeline needs ffmpeg and
# v4l-utils, the status window needs PySide6, and neither is this script's
# job to install.
echo
missing=()
command -v ffmpeg    >/dev/null || missing+=("ffmpeg")
command -v v4l2-ctl  >/dev/null || missing+=("v4l-utils (v4l2-ctl)")
python3 -c 'import PySide6' 2>/dev/null || missing+=("PySide6 (only for the status window)")
# Look for an actual loopback device, not just the module: it can be loaded
# with no devices. Deliberately pipe-free - `cmd | grep -q` makes grep exit
# early, cmd takes SIGPIPE, and under `set -o pipefail` the check reports a
# failure that never happened.
loopback=no
if command -v v4l2-ctl >/dev/null; then
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        info="$(v4l2-ctl -d "$dev" --info 2>/dev/null || true)"
        case "${info,,}" in
            *"v4l2 loopback"*) loopback=yes; break ;;
        esac
    done
elif [[ -r /proc/modules ]] && grep -q v4l2loopback /proc/modules; then
    loopback=yes
fi
[[ "$loopback" == yes ]] || missing+=("a v4l2loopback device (see README)")
if ((${#missing[@]})); then
    echo "Still needed:"
    printf '  - %s\n' "${missing[@]}"
    echo "  (see the README for per-distro package names)"
else
    echo "All dependencies present."
fi

cat <<'NEXT'

Next:
  lumaloop --list-devices            # find your camera
  $EDITOR ~/.config/lumaloop/config.toml
  systemctl --user daemon-reload
  systemctl --user enable --now lumaloop.service
NEXT
