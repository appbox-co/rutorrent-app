#!/bin/sh
# rTorrent session survives a switch from ruTorrent 5 to this image.
#
# ruTorrent 5 keeps the session in a real /torrents/config/rtorrent/.session
# with session -> .session. 3.10-10 and 3.10-11 ran
#   mv .session/* session/ && rm -rf .session
# on every start, which moved each file onto itself and then deleted the real
# directory, so every torrent was lost and rTorrent could not start
# ("Could not lock session directory"). scripts/session-layout.sh replaces it.
#
# The check:
#   1. runs scripts/session-layout.sh on each layout an instance can arrive
#      with and checks the result and that no session file is lost;
#   2. starts the image the way Appbox does (/scripts/start.sh, test login,
#      stubbed install callback), adds a torrent, stops, turns the session
#      into the ruTorrent 5 layout, starts again as a new container would
#      (no /etc/app_configured) and checks that rTorrent still lists the
#      torrent and the session files are still there;
#   3. stops, deletes .session to leave the dangling session link that
#      3.10-10/-11 left behind, starts again and checks that rTorrent starts.
set -eu

check_dir=$(mktemp -d /tmp/session-layout.XXXXXX)
rt=/torrents/config/rtorrent
base=http://127.0.0.1
user=regression
password=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
failures=0
xmlrpc_call='<?xml version="1.0"?><methodCall><methodName>system.client_version</methodName><params/></methodCall>'

fail() {
    echo "FAIL: $*" >&2
    for log in "$check_dir/start.log" /tmp/supervisord.log; do
        [ -f "$log" ] || continue
        echo "--- $log" >&2
        tail -n 30 "$log" >&2
    done
    exit 1
}

miss() {
    echo "  FAIL $*"
    failures=$((failures + 1))
}

ok() {
    echo "  ok   $*"
}

# describe <dir>: "session=<kind> .session=<kind> files=<n>" for a config dir.
describe() {
    out=
    for entry in session .session; do
        path="$1/$entry"
        if [ -L "$path" ]; then
            kind="link:$(readlink "$path")"
            [ -e "$path" ] || kind="$kind(dangling)"
        elif [ -d "$path" ]; then
            kind=dir
        else
            kind=none
        fi
        out="$out$entry=$kind "
    done
    files=$(find -L "$1/session" -maxdepth 1 -type f 2>/dev/null | wc -l)
    echo "${out}files=$files"
}

# layout <name> <expected description> <setup commands>
layout() {
    name=$1 expected=$2 setup=$3
    dir="$check_dir/layouts/$name"
    mkdir -p "$dir"
    (cd "$dir" && eval "$setup")
    bash /scripts/session-layout.sh "$dir" >"$check_dir/layout-$name.log" 2>&1 \
        || { miss "$name: session-layout.sh exited non-zero: $(cat "$check_dir/layout-$name.log")"; return 0; }
    got=$(describe "$dir")
    if [ "$got" = "$expected" ]; then
        ok "$name: $got"
    else
        miss "$name: got '$got', expected '$expected'"
    fi
}

echo "== Layouts"
[ -x /scripts/session-layout.sh ] || fail "/scripts/session-layout.sh is missing"
layout ruTorrent5 'session=link:.session .session=dir files=3' \
    'mkdir .session && touch .session/A.torrent .session/A.torrent.rtorrent .session/A.torrent.libtorrent_resume && ln -s .session session'
layout ruTorrent5-absolute "session=link:$check_dir/layouts/ruTorrent5-absolute/.session .session=dir files=1" \
    "mkdir .session && touch .session/A.torrent && ln -s $check_dir/layouts/ruTorrent5-absolute/.session session"
layout upgraded-from-3.10 'session=dir .session=link:session files=2' \
    'mkdir session && touch session/A.torrent session/A.torrent.rtorrent && ln -s session .session'
layout old-image 'session=dir .session=none files=2' \
    'mkdir .session && touch .session/A.torrent .session/A.torrent.rtorrent'
layout old-image-dangling-link 'session=dir .session=none files=1' \
    'mkdir .session && touch .session/A.torrent && ln -s .session-gone session'
layout both-real-dirs 'session=dir .session=dir files=2' \
    'mkdir session .session && touch session/A.torrent .session/A.torrent .session/B.torrent'
if [ -f "$check_dir/layouts/both-real-dirs/.session/A.torrent" ] \
    && [ ! -e "$check_dir/layouts/both-real-dirs/.session/B.torrent" ]; then
    ok "both-real-dirs: the duplicate stayed in .session, nothing was overwritten"
else
    miss "both-real-dirs: files were overwritten or lost"
fi
layout wiped-by-3.10-11 'session=dir .session=none files=0' 'ln -s .session session'
layout plain 'session=dir .session=none files=1' 'mkdir session && touch session/A.torrent'
layout new 'session=none .session=none files=0' 'true'

mkdir -p "$check_dir/bin"
cat > "$check_dir/bin/curl" <<'EOF'
#!/bin/sh
# Answers start.sh's install callback, which cannot reach the API offline.
echo 'HTTP/1.1 200 OK'
EOF
chmod 0755 "$check_dir/bin/curl"

start_image() {
    env PATH="$check_dir/bin:$PATH" RUTORRENT_USER="$user" RUTORRENT_PASSWORD="$password" \
        LISTENING_PORT=51413 DHT_PORT=51414 EXTERNAL_DOMAIN=http://127.0.0.1 INSTANCE_ID=0 \
        /scripts/start.sh >>"$check_dir/start.log" 2>&1 &
    attempt=0
    until [ "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "$user:$password" \
        -H 'Content-Type: text/xml' --data-binary "$xmlrpc_call" "$base/RPC2")" = 200 ]; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 150 ] || fail "rTorrent did not answer XML-RPC within 150s ($1)"
        sleep 1
    done
}

rtorrent_running() {
    for proc in /proc/[0-9]*; do
        if tr '\0' ' ' <"$proc/cmdline" 2>/dev/null | grep -q 'rtorrent-extended'; then
            return 0
        fi
    done
    return 1
}

stop_image() {
    supervisord_pid=$(cat /tmp/supervisord.pid)
    kill "$supervisord_pid"
    attempt=0
    while kill -0 "$supervisord_pid" 2>/dev/null || rtorrent_running; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 60 ] || fail "supervisord or rTorrent did not stop within 60s"
        sleep 1
    done
}

torrent_listed() {
    /usr/bin/curl -s --max-time 30 -u "$user:$password" -d mode=list \
        "$base/plugins/httprpc/action.php" | grep -qF "$1"
}

echo "== First start, add a torrent"
start_image "first start"
name=session-layout-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n').txt
hash=$(php7.2 -r '
    $info = "d6:lengthi5e4:name" . strlen($argv[2]) . ":" . $argv[2]
        . "12:piece lengthi16384e6:pieces20:" . str_repeat("A", 20) . "e";
    file_put_contents($argv[1], "d8:announce22:http://tracker.invalid4:info" . $info . "e");
    echo strtoupper(sha1($info));
' "$check_dir/check.torrent" "$name")
status=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 30 -u "$user:$password" \
    -F "torrent_file=@$check_dir/check.torrent" -F torrents_start_stopped=1 \
    "$base/php/addtorrent.php") || status=000
[ "$status" = 302 ] || fail "adding the torrent returned HTTP $status"
attempt=0
until torrent_listed "$name" && [ -f "$rt/session/$hash.torrent" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 60 ] || fail "the torrent was not listed and saved to the session within 60s"
    sleep 1
done
ok "torrent $hash listed and saved in session/"
stop_image

echo "== Switch from ruTorrent 5: session -> .session, new container"
mv "$rt/session" "$rt/.session"
ln -s .session "$rt/session"
rm -f /etc/app_configured
echo "  before: $(describe "$rt")"
start_image "ruTorrent 5 layout"
if torrent_listed "$name"; then
    ok "rTorrent still lists the torrent"
else
    miss "rTorrent lost the torrent after the switch"
fi
got=$(describe "$rt")
case "$got" in
    'session=link:.session .session=dir '*) ok "layout kept: $got" ;;
    *) miss "layout changed: $got" ;;
esac
if [ -f "$rt/.session/$hash.torrent" ]; then
    ok ".session/$hash.torrent is still there"
else
    miss ".session/$hash.torrent is gone"
fi
if grep -q 'Could not lock session directory' /torrents/config/log/rtorrent/rtorrent.log 2>/dev/null; then
    miss "rtorrent.log reports that it could not lock the session directory"
else
    ok "no session lock error in rtorrent.log"
fi
stop_image

echo "== Dangling session link left by 3.10-10/-11"
rm -rf "$rt/.session"
rm -f /etc/app_configured
echo "  before: $(describe "$rt")"
start_image "dangling session link"
got=$(describe "$rt")
case "$got" in
    'session=dir '*) ok "rTorrent started with a new session directory: $got" ;;
    *) miss "session is not a directory: $got" ;;
esac
stop_image

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures session layout expectation(s) not met" >&2
    exit 1
fi
echo "The rTorrent session survives every layout"
