#!/usr/bin/env bash
# Khởi động cả stack. Chạy trên máy Linux đóng vai trò host.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v docker >/dev/null 2>&1; then
  echo "✗ Chưa có Docker. Cài Docker Engine + compose plugin trước." >&2
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
  echo "→ Đã tạo .env từ .env.example (sửa nếu cần)."
fi

echo "→ Build images…"
docker compose --profile setup build

echo "→ Chuẩn bị game files (lần đầu sẽ tải ~2 GB qua SteamCMD)…"
docker compose --profile setup run --rm assets

echo "→ Khởi động server…"
docker compose up -d

# Đợi server trả lời A2S rồi in link.
PORT=$(grep -E '^WEB_PORT=' .env | cut -d= -f2)
PORT=${PORT:-27016}

for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# NetBird dùng interface wt0; fallback sang IP LAN thường.
IP=$(ip -4 -o addr show wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
IP=${IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}

echo
echo "  ✅ Xong."
echo
echo "  Link cho coworker:  http://${IP}:${PORT}"
echo
echo "  Logs:      docker compose logs -f web game"
echo "  Dừng:      docker compose down"
echo "  Cập nhật:  docker compose build && docker compose up -d"
