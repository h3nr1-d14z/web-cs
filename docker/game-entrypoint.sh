#!/bin/sh
# Assemble the server tree from the read-only image parts and the writable
# assets volume, then hand over to the engine.
set -eu

ROOT=${XASH_ROOT:-/xashds}

if [ ! -f "$ROOT/cstrike/liblist.gam" ]; then
  echo "✗ $ROOT/cstrike/liblist.gam không tồn tại." >&2
  echo "  Volume assets chưa có game files. Chạy trước:" >&2
  echo "    docker compose run --rm assets" >&2
  exit 1
fi

cp -f /opt/xash/xash "$ROOT/xash"
cp -f /opt/xash/filesystem_stdio.so "$ROOT/filesystem_stdio.so"
chmod +x "$ROOT/xash"

mkdir -p "$ROOT/cstrike/dlls"
cp -f /opt/regamedll/bin/linux32/cstrike/dlls/cs.so "$ROOT/cstrike/dlls/cs.so"

# Our liblist.gam declares gamedll_linux explicitly instead of trusting whatever
# a given HLDS build shipped.
cp -f /opt/config/liblist.gam "$ROOT/cstrike/liblist.gam"

# YaPB bot (standalone): engine nạp yapb.so qua liblist, yapb tự chain tới
# ReGameDLL (dlls/cs.so). conf/data chỉ copy lần đầu để giữ chỉnh sửa của user.
if [ -d /opt/yapb/addons/yapb ] && [ ! -f "$ROOT/cstrike/addons/yapb/bin/yapb.so" ]; then
  mkdir -p "$ROOT/cstrike/addons/yapb"
  cp -a /opt/yapb/addons/yapb/bin "$ROOT/cstrike/addons/yapb/"
  cp -a /opt/yapb/addons/yapb/conf "$ROOT/cstrike/addons/yapb/"
  cp -a /opt/yapb/addons/yapb/data "$ROOT/cstrike/addons/yapb/"
fi
# liblist: gamedll_linux trỏ sang yapb (yapb tự nạp dlls/cs.so của ReGameDLL)
sed -i 's#^gamedll_linux .*#gamedll_linux "addons/yapb/bin/yapb.so"#' "$ROOT/cstrike/liblist.gam"

# delta.lst is the network delta table; the engine aborts without it and some
# HLDS builds ship it only in the newer game files.
if [ ! -f "$ROOT/cstrike/delta.lst" ]; then
  cp -f /opt/regamedll/bin/linux32/cstrike/delta.lst "$ROOT/cstrike/delta.lst"
fi

cp -f /opt/config/server.cfg "$ROOT/cstrike/server.cfg"
cp -f /opt/config/motd.txt "$ROOT/cstrike/motd.txt"

cd "$ROOT"

# Chế độ dashboard nhiều phòng: supervisor python tự spawn/kill xash theo room.
if [ "${ROOMS_API:-0}" = "1" ]; then
  echo "→ room supervisor: :${LISTEN_PORT:-7000} (UDP base ${UDP_BASE:-27015})"
  exec python3 /opt/supervisor.py
fi

echo "→ map=${MAP:-de_dust2} maxplayers=${MAXPLAYERS:-16} port=${PORT:-27015}"
exec ./xash \
  -dedicated \
  -game cstrike \
  -ip 0.0.0.0 \
  -port "${PORT:-27015}" \
  +maxplayers "${MAXPLAYERS:-16}" \
  +map "${MAP:-de_dust2}" \
  +sv_lan 1 \
  +exec server.cfg
