#!/usr/bin/env python3
"""
Room supervisor cho game container (i386): mỗi phòng = 1 tiến trình xash.

REST API nội bộ (web container gọi qua mạng Docker):

  GET    /rooms                → danh sách phòng + số người/bots
  POST   /rooms                → tạo phòng {name,map,maxplayers,password,bots}
                                  (trả ownerToken — chỉ trả 1 lần)
  POST   /rooms/<id>/preset    → áp preset từ presets.json (chủ phòng)
  GET    /rooms/<id>           → chi tiết (isOwner=true khi header khớp)
  PATCH  /rooms/<id>           → đổi map/password/bots/tên, {restart:true} để restart ván
  DELETE /rooms/<id>           → đóng phòng

Trạng thái lưu /data/rooms.json; container restart sẽ tự spawn lại phòng.
Phòng trống người thật quá EMPTY_TTL giây tự đóng.

Chạy:  python3 supervisor.py  (env: XASH, GAME_DIR, ROOMS_FILE, LISTEN_PORT,
       RCON_PASSWORD, EMPTY_TTL, UDP_BASE)
"""
import json
import os
import random
import re
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

XASH = os.environ.get("XASH", "/xashds/xash")
GAME_DIR = os.environ.get("GAME_DIR", "/xashds")
ROOMS_FILE = os.environ.get("ROOMS_FILE", "/data/rooms.json")
RCON_PASSWORD = os.environ.get("RCON_PASSWORD", "doi-mat-khau-nay")
PRESETS_FILE = os.environ.get("PRESETS_FILE", "/opt/config/presets.json")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "7000"))
UDP_BASE = int(os.environ.get("UDP_BASE", "27015"))
EMPTY_TTL = int(os.environ.get("EMPTY_TTL", str(30 * 60)))
MAX_BOTS = 8
# Mỗi phòng = 1 process game server riêng: cap để hàng xóm ngoài Internet không
# spawn hàng chục server qua POST /rooms (mỗi phòng giữ slot tới EMPTY_TTL).
MAX_ROOMS = int(os.environ.get("MAX_ROOMS", "8"))

LOCK = threading.Lock()
ROOMS = {}  # id → dict


# ---------------------------------------------------------------- helpers
def a2s_info(host, port, timeout=1.0):
    """A2S_INFO tối giản: trả dict hoặc None."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        sock.sendto(b"\xff\xff\xff\xffTSource Engine Query\x00", (host, port))
        data, _ = sock.recvfrom(2048)
        sock.close()
    except OSError:
        return None
    if len(data) < 6 or data[4] != 0x49:
        return None
    off = 6
    def cstr(start):
        end = data.find(b"\x00", start)
        return data[start:end].decode("utf-8", "replace"), end + 1
    name, off = cstr(off)
    mapname, off = cstr(off)
    _, off = cstr(off)          # folder
    _, off = cstr(off)          # game
    off += 2                    # appid
    players, max_players = data[off], data[off + 1]
    # bots là byte thứ ba của khối này; server cũ không có trường đó.
    bots = data[off + 2] if len(data) > off + 2 else 0
    return {
        "online": True,
        "name": name,
        "map": mapname,
        "players": players,
        "maxPlayers": max_players,
        "bots": bots,
    }


def rcon(port, password, command, timeout=2.0):
    """RCON Xash3D FWGS: gói 'rcon <password> <command>', không challenge."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        sock.sendto(b"\xff\xff\xff\xff" + f"rcon {password} {command}\n".encode(), ("127.0.0.1", port))
        chunks = []
        while True:
            try:
                data, _ = sock.recvfrom(4096)
            except OSError:
                break
            chunks.append(data[4:].decode("utf-8", "replace").lstrip("l "))
        sock.close()
    except OSError as exc:
        raise RuntimeError(f"rcon lỗi: {exc}") from exc
    return "".join(chunks).strip()


def load_presets():
    try:
        with open(PRESETS_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[supervisor] không đọc được presets: {exc}", flush=True)
        return {}


def preset_for_map(map_name):
    """Preset khai báo `maps` = tiền tố tên map (vd pool parkour kz_/surf_...)."""
    name = str(map_name).lower()
    for pid, preset in load_presets().items():
        if any(name.startswith(prefix) for prefix in (preset.get("maps") or [])):
            return pid
    return ""


def apply_mode(room):
    """Áp cvar của mode chọn lúc tạo phòng, hoặc suy ra từ tên map.
    `yb_quota` gửi sau cùng để ô "Bot" ở dashboard luôn thắng preset."""
    presets = load_presets()
    name = room.get("preset") or preset_for_map(room["map"])
    if not rcon(room["port"], RCON_PASSWORD, "status"):
        print(
            f"[supervisor] room {room['id']}: RCON không phản hồi — sai rcon_password? "
            "(đừng đặt rcon_password trong server.cfg, nó đè +rcon_password)",
            flush=True,
        )
    for command in (presets.get(name) or {}).get("commands") or []:
        rcon(room["port"], RCON_PASSWORD, command)
    rcon(room["port"], RCON_PASSWORD, f"yb_quota {room['bots']}")
    if name:
        print(f"[supervisor] room {room['id']}: mode {name}", flush=True)


def reapply_mode(room, delay=4.0):
    """changelevel exec lại server.cfg → cvar về mặc định; áp lại mode sau khi map load."""
    time.sleep(delay)
    try:
        apply_mode(room)
    except RuntimeError as exc:
        print(f"[supervisor] room {room['id']}: re-apply mode lỗi: {exc}", flush=True)


def free_port(rooms):
    used = {r["port"] for r in rooms.values()}
    for offset in range(20):
        port = UDP_BASE + offset * 10
        if port not in used:
            return port
    raise RuntimeError("hết slot port cho phòng mới")


def persist():
    os.makedirs(os.path.dirname(ROOMS_FILE), exist_ok=True)
    specs = {
        rid: {k: r[k] for k in ("name", "map", "maxplayers", "password", "bots", "preset", "port", "owner_token")}
        for rid, r in ROOMS.items()
    }
    tmp = ROOMS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(specs, handle, indent=2)
    os.replace(tmp, ROOMS_FILE)


# ---------------------------------------------------------------- spawn
def spawn_room(rid, spec):
    port = spec.get("port") or free_port(rooms_map())
    args = [
        XASH, "-dedicated", "-game", "cstrike", "-port", str(port),
        "+hostname", f"{spec.get('name') or 'Phòng ' + rid} · web-cs",
        "+maxplayers", str(spec.get("maxplayers", 16)),
        "+map", spec.get("map", "de_dust2"),
        "+sv_lan", "1", "+exec", "server.cfg",
        "+rcon_password", RCON_PASSWORD,
    ]
    if spec.get("password"):
        args += ["+sv_password", spec["password"]]
    logf = open(os.path.join(GAME_DIR, f"room-{rid}.log"), "ab")
    proc = subprocess.Popen(args, cwd=GAME_DIR, stdout=logf, stderr=logf)
    ROOMS[rid] = {
        "id": rid,
        "name": spec.get("name") or f"Phòng {rid}",
        "map": spec.get("map", "de_dust2"),
        "maxplayers": int(spec.get("maxplayers", 16)),
        "password": spec.get("password", ""),
        "bots": int(spec.get("bots", 0)),
        "preset": spec.get("preset", ""),
        "port": port,
        "owner_token": spec.get("owner_token"),
        "proc": proc,
        "logf": logf,
        "created": time.time(),
        "empty_since": time.time(),
        "status": {"players": 0, "bots": 0, "humans": 0},
    }
    threading.Thread(target=apply_config, args=(rid,), daemon=True).start()


def apply_config(rid):
    """Chờ server lên rồi áp bots + password qua rcon."""
    room = ROOMS.get(rid)
    if not room:
        return
    for _ in range(12):
        time.sleep(1)
        if a2s_info("127.0.0.1", room["port"]):
            break
    try:
        if room["password"]:
            rcon(room["port"], RCON_PASSWORD, f"sv_password {room['password']}")
        apply_mode(room)
    except RuntimeError as exc:
        print(f"[supervisor] room {rid}: rcon lỗi: {exc}", flush=True)


def rooms_map():
    return ROOMS


def room_view(room, token=None):
    # `port` cho web server: nhánh Docker không giữ bản sao danh sách phòng, nên
    # WS upgrade phải hỏi supervisor đúng port của phòng.
    return {
        "id": room["id"],
        "name": room["name"],
        "map": room["map"],
        "maxplayers": room["maxplayers"],
        "hasPassword": bool(room["password"]),
        "bots": room["bots"],
        "preset": room.get("preset", ""),
        "port": room["port"],
        "players": room["status"]["players"],
        "humans": room["status"]["humans"],
        "isOwner": is_owner(room, token),
    }


def is_owner(room, token):
    owner = room.get("owner_token")
    return bool(token and owner) and secrets.compare_digest(token, owner)


# ---------------------------------------------------------------- loops
def status_loop():
    while True:
        for room in list(ROOMS.values()):
            info = a2s_info("127.0.0.1", room["port"])
            if not info:
                continue
            room["status"] = {
                "players": info["players"],
                "bots": info["bots"],
                "humans": info["players"] - info["bots"],
            }
            room["empty_since"] = time.time() if room["status"]["humans"] > 0 else room.get("empty_since")
            room["map"] = info["map"] or room["map"]
        time.sleep(5)


def autoclose_loop():
    while True:
        now = time.time()
        for rid, room in list(ROOMS.items()):
            empty_for = now - (room.get("empty_since") or now)
            if room["status"]["humans"] == 0 and empty_for > EMPTY_TTL:
                print(f"[supervisor] room {rid}: trống {int(empty_for/60)} phút — tự đóng", flush=True)
                kill_room(rid)
        time.sleep(60)


def kill_room(rid):
    room = ROOMS.pop(rid, None)
    if not room:
        return False
    room["proc"].terminate()
    try:
        room["logf"].close()
    except (OSError, ValueError):
        pass
    persist()
    return True


def restore():
    if not os.path.exists(ROOMS_FILE):
        return
    with open(ROOMS_FILE, encoding="utf-8") as handle:
        specs = json.load(handle)
    for rid, spec in specs.items():
        print(f"[supervisor] khôi phục phòng {rid} ({spec.get('map')})", flush=True)
        spawn_room(rid, {**spec, "id": rid})
        persist()


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/rooms":
            rooms = list(ROOMS.values())
            token = self.headers.get("X-Room-Token")
            self._json(200, {"rooms": [room_view(r, token) for r in rooms]})
        elif re.match(r"^/rooms/[\w-]+$", path):
            rid = path.split("/")[2]
            room = ROOMS.get(rid)
            if not room:
                return self._json(404, {"error": "phòng không tồn tại"})
            self._json(200, room_view(room, self.headers.get("X-Room-Token")))
        else:
            self._json(404, {"error": "not-found"})

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "json lỗi"})

        if path == "/rooms":
            if len(ROOMS) >= MAX_ROOMS:
                return self._json(
                    409,
                    {"error": f"đã có đủ {MAX_ROOMS} phòng — vào phòng đang có, hoặc chờ phòng trống tự đóng"},
                )
            rid = "r" + secrets.token_hex(3)
            preset = str(body.get("preset") or "")
            spec = {
                "name": str(body.get("name") or "")[:32] or f"Phòng {rid}",
                "map": str(body.get("map") or "de_dust2"),
                "maxplayers": max(2, min(int(body.get("maxplayers") or 16), 16)),
                "password": str(body.get("password") or "")[:24],
                "bots": max(0, min(int(body.get("bots") or 0), MAX_BOTS)),
                "preset": preset if preset in load_presets() else "",
                "owner_token": secrets.token_hex(16),
            }
            spawn_room(rid, spec)
            persist()
            self._json(200, room_view(ROOMS[rid], spec["owner_token"]) | {"ownerToken": spec["owner_token"]})
            return

        preset = re.match(r"^/rooms/([\w-]+)/preset$", path)
        if preset:
            room = ROOMS.get(preset.group(1))
            if not room:
                return self._json(404, {"error": "phòng không tồn tại"})
            if not is_owner(room, self.headers.get("X-Room-Token")):
                return self._json(401, {"error": "chỉ chủ phòng đổi preset được"})
            name = str(body.get("name") or "")
            commands = (load_presets().get(name) or {}).get("commands") or []
            if not commands:
                return self._json(404, {"error": "preset không tồn tại"})
            try:
                for command in commands:
                    rcon(room["port"], RCON_PASSWORD, command)
            except RuntimeError as exc:
                return self._json(502, {"error": str(exc)})
            print(f"[supervisor] room {room['id']}: preset {name} ({len(commands)} lệnh)", flush=True)
            return self._json(200, {"ok": True, "applied": len(commands)})

        self._json(404, {"error": "not-found"})

    def do_PATCH(self):
        path = urlparse(self.path).path
        match = re.match(r"^/rooms/([\w-]+)$", path)
        if not match:
            return self._json(404, {"error": "not-found"})
        rid = match.group(1)
        room = ROOMS.get(rid)
        if not room:
            return self._json(404, {"error": "phòng không tồn tại"})
        token = self.headers.get("X-Room-Token")
        if not is_owner(room, token):
            return self._json(401, {"error": "chỉ chủ phòng sửa được phòng"})

        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        try:
            if body.get("restart"):
                rcon(room["port"], RCON_PASSWORD, "sv_restart 1")
            if "map" in body and re.match(r"^[\w.-]+$", str(body["map"])):
                rcon(room["port"], RCON_PASSWORD, f"changelevel {body['map']}")
                room["map"] = body["map"]
                threading.Thread(target=reapply_mode, args=(room,), daemon=True).start()
            if "password" in body:
                room["password"] = str(body["password"])[:24]
                rcon(room["port"], RCON_PASSWORD, f"sv_password {room['password']}")
            if "bots" in body:
                room["bots"] = max(0, min(int(body["bots"]), MAX_BOTS))
                rcon(room["port"], RCON_PASSWORD, f"yb_quota {room['bots']}")
            if "name" in body:
                room["name"] = str(body["name"])[:32]
                rcon(room["port"], RCON_PASSWORD, f"hostname {room['name']} · web-cs")
        except RuntimeError as exc:
            return self._json(502, {"error": str(exc)})
        persist()
        self._json(200, room_view(room))

    def do_DELETE(self):
        path = urlparse(self.path).path
        match = re.match(r"^/rooms/([\w-]+)$", path)
        if not match:
            return self._json(404, {"error": "not-found"})
        rid = match.group(1)
        room = ROOMS.get(rid)
        if not room:
            return self._json(404, {"error": "phòng không tồn tại"})
        if not is_owner(room, self.headers.get("X-Room-Token")):
            return self._json(401, {"error": "chỉ chủ phòng đóng được phòng"})
        kill_room(rid)
        print(f"[supervisor] room {rid}: đóng theo yêu cầu", flush=True)
        self._json(200, {"ok": True})


if __name__ == "__main__":
    restore()
    threading.Thread(target=status_loop, daemon=True).start()
    threading.Thread(target=autoclose_loop, daemon=True).start()
    print(f"[supervisor] listening on :{LISTEN_PORT} (xash={XASH}, dir={GAME_DIR})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
