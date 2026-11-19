#!/usr/bin/env bash
# Put rTorrent's session directory where this image expects it, without
# losing any session files.
#
# Usage: session-layout.sh [<rtorrent config dir>]   (default /torrents/config/rtorrent)
#
# rTorrent 0.9.6 here uses <dir>/session. Three other layouts reach this image:
#   - Old Appbox images kept the session in a real <dir>/.session. Its files
#     are moved into session/ without overwriting, and .session is removed once
#     it is empty.
#   - ruTorrent 5 installs keep the session in a real .session with
#     session -> .session. rTorrent reads it through the link, so it is left in
#     place. 3.10-10 and 3.10-11 moved .session's files onto themselves and
#     then deleted .session, which lost every torrent.
#   - Instances upgraded from 3.10 to ruTorrent 5 keep a real session/ with
#     .session -> session. That link is left for ruTorrent 5 to reuse.
# A session link whose target no longer exists (left by 3.10-10 or 3.10-11)
# is replaced with an empty directory so that rTorrent can start.
set -u

rt_dir=${1:-/torrents/config/rtorrent}
rt_session="$rt_dir/session"
rt_dot_session="$rt_dir/.session"

if [ -L "$rt_dot_session" ]; then
    echo "Session: .session is a link to $(readlink "$rt_dot_session"), nothing to move."
elif [ -d "$rt_dot_session" ]; then
    if [ -e "$rt_session" ] && [ "$(readlink -f "$rt_session")" = "$(readlink -f "$rt_dot_session")" ]; then
        echo "Session: session -> .session (ruTorrent 5 layout), using it in place."
    else
        echo "Session directory found, moving to new location..."
        if [ -L "$rt_session" ] && [ ! -e "$rt_session" ]; then
            rm -f "$rt_session"
        fi
        mkdir -p "$rt_session"
        find "$rt_dot_session" -mindepth 1 -maxdepth 1 -exec mv -n -t "$rt_session" {} +
        if ! rmdir "$rt_dot_session" 2>/dev/null; then
            echo "Session: kept $rt_dot_session, it still holds files that also exist in session/."
        fi
    fi
fi

if [ -L "$rt_session" ] && [ ! -e "$rt_session" ]; then
    echo "Session: session pointed at a missing directory, recreating it."
    rm -f "$rt_session"
    mkdir -p "$rt_session"
fi

exit 0
