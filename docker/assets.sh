#!/bin/sh
# Asset job (idempotent).
#
#   docker compose run --rm assets              # lần đầu: SteamCMD + trim + zip
#   docker compose run --rm -e FORCE_ZIP=1 assets   # zip lại (sau khi thêm map)
#
# Output in the shared volume:
#   valve/, cstrike/   → game server đọc
#   game.zip           → browser tải (valve/ + cstrike/ ở root)
#   VERSION            → hash nội dung
set -eu

OUT=${OUT_DIR:-/out}
STAGE=${STAGE_DIR:-$OUT/.hlds}
STEAMCMD=${STEAMCMD:-/home/steam/steamcmd/steamcmd.sh}
APP_ID=${HLDS_APP_ID:-90}
FORCE_ZIP=${FORCE_ZIP:-0}

echo "→ asset job: $(date -u +%FT%TZ)"
mkdir -p "$OUT"

have_tree() {
  [ -f "$OUT/cstrike/liblist.gam" ] && [ -d "$OUT/valve" ]
}

if [ "$FORCE_ZIP" != "1" ] && [ -f "$OUT/game.zip" ] && unzip -t "$OUT/game.zip" >/dev/null 2>&1; then
  echo "✓ game.zip đã có và hợp lệ — bỏ qua (dùng FORCE_ZIP=1 để nén lại)"
  exit 0
fi

if ! have_tree; then
  echo "→ tải HLDS (app $APP_ID) qua SteamCMD… (~2 GB, một lần)"
  # App 90 tải *engine* HLDS; thiếu `app_set_config ... mod cstrike` thì nó trả
  # "Success" mà chỉ có valve/ + hlds_linux, không có cstrike/. SteamCMD cũng hay
  # báo thành công khi còn thiếu file, nên kiểm tra file mới là điều kiện dừng.
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if "$STEAMCMD" \
        +force_install_dir "$STAGE" \
        +login anonymous \
        +app_set_config "$APP_ID" mod cstrike \
        +app_update "$APP_ID" validate \
        +quit && [ -f "$STAGE/cstrike/liblist.gam" ]; then
      break
    fi
    echo "  lần $attempt thất bại, thử lại sau 60s…"
    attempt=$((attempt + 1))
    # 5s là quá ngắn: khi Steam vừa trả lỗi throttle, retry ngay chỉ kéo dài cửa sổ.
    sleep 60
  done

  if [ ! -f "$STAGE/cstrike/liblist.gam" ]; then
    echo "✗ SteamCMD không lấy được game files." >&2
    echo "  Kiểm tra internet của host rồi chạy lại: docker compose run --rm assets" >&2
    exit 1
  fi

  echo "→ copy vào volume + dọn phần browser không dùng"
  rm -rf "$OUT/valve" "$OUT/cstrike"
  cp -a "$STAGE/valve" "$OUT/valve"
  cp -a "$STAGE/cstrike" "$OUT/cstrike"

  # Binary/không cần cho browser (game server tự có module riêng).
  find "$OUT" -type f \( -name '*.so' -o -name '*.dll' -o -name '*.dylib' \
       -o -name '*.exe' -o -name '*.dem' \) -delete
  find "$OUT" -type d -name logs -prune -exec rm -rf {} +
  rm -rf "$OUT/valve/dlls" "$OUT/cstrike/dlls"

  # SteamCMD cắt mất mấy file text mà client DLL vẫn hỏi tới.
  mkdir -p "$OUT/cstrike/resource" "$OUT/valve/resource"
  [ -f "$OUT/cstrike/resource/cstrike_english.txt" ] || \
    cp -f /opt/config/resource/cstrike_english.txt "$OUT/cstrike/resource/"
  [ -f "$OUT/valve/resource/halflife_english.txt" ] || \
    cp -f /opt/config/resource/halflife_english.txt "$OUT/valve/resource/"

  rm -rf "$STAGE"
else
  echo "→ đã có valve/ + cstrike/ trong volume, chỉ nén lại"
fi

if [ -f /opt/config/motd.txt ]; then
  cp -f /opt/config/motd.txt "$OUT/cstrike/motd.txt"
fi
# liblist.gam tells the engine this directory is Counter-Strike; the client
# cannot boot without it, so it must be inside game.zip as well.
cp -f /opt/config/liblist.gam "$OUT/cstrike/liblist.gam"

echo "→ nén cho browser (pk3 layout: pk3 nằm trong từng gamedir + manifest thật)"
cd "$OUT"
rm -f game.zip
(cd valve && zip -1 -rq ../valve.pk3 . -x 'maps/*' -x 'media/*' -x 'overviews/*' -x 'dlls/*' -x 'logs/*')
(cd cstrike && zip -1 -rq ../cstrike.pk3 . -x 'dlls/*' -x 'logs/*' -x 'server.cfg' -x 'motd.txt')
# Outer zip là STORE (-0): bên trong đã deflate rồi.
zip -0 -q game.zip valve/valve.pk3 cstrike/cstrike.pk3 cstrike/liblist.gam
[ -f cstrike/delta.lst ] && zip -0 -q game.zip cstrike/delta.lst

HASH=$(sha256sum game.zip | cut -c1-16)
printf '%s\n' "$HASH" >VERSION
echo "✓ xong: $(du -h game.zip | cut -f1), sha $HASH"
