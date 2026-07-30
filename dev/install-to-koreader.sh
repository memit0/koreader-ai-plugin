#!/bin/sh
# Symlinks this checkout into a local KOReader install as askgpt.koplugin, so
# the desktop emulator picks up edits with no copying.
#
#   ./dev/install-to-koreader.sh ~/koreader
#
# KOReader only discovers directories whose name ends in .koplugin, which is why
# this cannot simply point at the checkout.
set -e

target="${1:-}"
if [ -z "$target" ]; then
    echo "usage: $0 <path to koreader install>" >&2
    exit 1
fi

plugins="$target/plugins"
if [ ! -d "$plugins" ]; then
    echo "no plugins directory at $plugins — is that a KOReader install?" >&2
    exit 1
fi

source_dir="$(cd "$(dirname "$0")/.." && pwd)"
link="$plugins/askgpt.koplugin"

if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "$link exists and is not a symlink; move it aside first" >&2
    exit 1
fi

ln -sfn "$source_dir" "$link"
echo "linked $link -> $source_dir"
echo
echo "Put your key in $source_dir/.env, then start KOReader."
echo "Plugin load failures are logged to $target/crash.log."
