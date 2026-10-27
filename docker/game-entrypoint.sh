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

# Hai cây game dùng chung một bộ asset:
#   $ROOT     → bots: engine nạp thẳng yapb.so qua liblist (không metamod).
#   $KZ_ROOT  → parkour: metamod → AMXX (ProKreedz: checkpoint/timer/zones).
# xash lấy basedir = thư mục làm việc và đọc cstrike/liblist.gam từ đó, nên chỉ
# cần cho phòng parkour chạy với CWD khác. Tên gamedir vẫn là "cstrike" (client
# wasm cố định mod dir đó). Cây KZ là symlink farm trỏ về $ROOT/cstrike nên
# map/model/sound/custom.pk3 dùng chung, không nhân bản hàng trăm MB asset.
if [ -d /opt/yapb/addons/yapb ]; then
  mkdir -p "$ROOT/cstrike/addons/yapb"
  cp -a /opt/yapb/addons/yapb/bin "$ROOT/cstrike/addons/yapb/"
  cp -a /opt/yapb/addons/yapb/conf "$ROOT/cstrike/addons/yapb/"
  cp -a /opt/yapb/addons/yapb/data "$ROOT/cstrike/addons/yapb/"
fi
sed -i 's#^gamedll_linux .*#gamedll_linux "addons/yapb/bin/yapb.so"#' "$ROOT/cstrike/liblist.gam"

KZ_ROOT=${XASH_KZ_ROOT:-/xashkz}
rm -rf "$KZ_ROOT"
mkdir -p "$KZ_ROOT/cstrike/addons/amxmodx/plugins" "$KZ_ROOT/cstrike/addons/metamod/dlls"
ln -sf "$ROOT/xash" "$KZ_ROOT/xash"
ln -sf "$ROOT/filesystem_stdio.so" "$KZ_ROOT/filesystem_stdio.so"
ln -sf "$ROOT/valve" "$KZ_ROOT/valve"
for entry in "$ROOT"/cstrike/*; do
  base=$(basename "$entry")
  case "$base" in liblist.gam|addons) continue ;; esac
  ln -sf "$entry" "$KZ_ROOT/cstrike/$base"
done
# custom.pk3 do web ghi sau khi boot (rename nguyên tử): symlink theo tên nên
# phải tạo vô điều kiện, kể cả lúc file chưa tồn tại.
ln -sf "$ROOT/cstrike/custom.pk3" "$KZ_ROOT/cstrike/custom.pk3"
cp -f "$ROOT/cstrike/liblist.gam" "$KZ_ROOT/cstrike/liblist.gam"
sed -i 's#^gamedll_linux .*#gamedll_linux "addons/metamod/dlls/metamod.so"#' "$KZ_ROOT/cstrike/liblist.gam"
cp -a /opt/amxx/addons/amxmodx/configs /opt/amxx/addons/amxmodx/data \
     /opt/amxx/addons/amxmodx/dlls /opt/amxx/addons/amxmodx/modules "$KZ_ROOT/cstrike/addons/amxmodx/"
cp -f /opt/config/amxx-plugins/*.amxx "$KZ_ROOT/cstrike/addons/amxmodx/plugins/"
# AMXX chỉ nạp plugin được liệt kê ở đây — copy file .amxx vào plugins/ là chưa đủ.
for plugin in /opt/config/amxx-plugins/*.amxx; do
  basename "$plugin"
done > "$KZ_ROOT/cstrike/addons/amxmodx/configs/plugins.ini"
cp -f /opt/metamod/addons/metamod/dlls/metamod.so "$KZ_ROOT/cstrike/addons/metamod/dlls/metamod.so"
printf 'linux addons/amxmodx/dlls/amxmodx_mm_i386.so\n' > "$KZ_ROOT/cstrike/addons/metamod/plugins.ini"
printf '[config]\ngamedll_linux dlls/cs.so\n' > "$KZ_ROOT/cstrike/addons/metamod/config.ini"
# ProKreedz lưu kỷ lục qua SQLite; module có sẵn nhưng mặc định bị comment.
printf 'sqlite\n' >> "$KZ_ROOT/cstrike/addons/amxmodx/configs/modules.ini"
echo "→ bots: $ROOT (YaPB) · parkour: $KZ_ROOT (metamod + AMXX + ProKreedz)"

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
