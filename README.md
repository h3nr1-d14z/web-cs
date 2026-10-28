# web-cs — Counter-Strike 1.6 chạy trong trình duyệt, cho LAN party nội bộ

Một stack Docker gồm 3 phần: server game GoldSrc thật, bridge WebSocket↔UDP, và web client
wasm. Coworker chỉ cần mở `http://<ip>:27016`, nhập tên, bấm **Vào game** — không cài gì,
không cần Steam, không cần plugin.

Kèm theo: **dashboard tạo phòng** (nhiều phòng song song, mỗi phòng 1 server riêng, chủ
phòng quản room của mình), **bots (YaPB)** thêm/bớt thủ công, **tab Server ngay trong game**
để đổi map / preset chế độ chơi (casual, gần thi đấu, parkour kz-surf) cho cả phòng, và
**bind chuột + scroll** trong phần Phím.

> **Về CS 1.1:** không thể chạy *đúng* CS 1.1 trong browser. Client 1.1 là `client.dll`
> Win32 đóng; WASM không thực thi được x86 binary, và bản mã nguồn mở duy nhất của dòng
> Counter-Strike là CS 1.6 (`FWGS/cs16-client`). Repo này vì vậy chạy **gameplay + asset
> CS 1.6 gốc của Valve**, engine là bản viết lại tương thích (Xash3D FWGS) — không phải
> binary engine của Valve. Chi tiết khác biệt ở [mục 8](#8-khác-biệt-so-với-cs-16-nguyên-bản).

## 1. Kiến trúc

```
      NetBird (WireGuard mesh)
      ┌──────────────────────────────────────────────────────────────┐
      │                                                              │
 browser (mỗi người)                                                 │
   │  HTTPS/HTTP  :27016  (TCP)                                       │
   │  WebSocket /ws       (TCP, binary frames = gói UDP)              │
   ▼                                                                  │
 ┌─────────┐   UDP :27015   ┌──────────────┐   UDP :27015   ┌─────────────┐
 │  web    │ ─────────────► │  game        │ ◄──── A2S ──── │  (nội bộ)   │
 │ Node.js │                │ Xash3D       │                │  Docker net │
 │ + ws    │                │ + ReGameDLL  │                │             │
 └─────────┘                └──────────────┘                └─────────────┘
      │                            ▲
      └── serves /game.zip ────────┘  (valve/ + cstrike/ từ volume `assets`)
```

Điểm mấu chốt: **browser không nói UDP được**, nên client wasm không mở socket mà đưa
từng datagram cho `WsTransport`; server Node nhận frame và chuyển thành UDP tới game
server. Mỗi WebSocket có **một** UDP socket riêng, nên GoldSrc vẫn thấy mỗi người chơi là
một client với `ip:port` riêng (nếu dùng chung socket, người này sẽ kick người kia).

Chỉ **TCP 27016** ra ngoài. UDP 27015 nằm trong Docker network → NetBird không cần mở UDP,
không cần STUN/TURN/WebRTC, không bị NAT traversal.

## 2. Yêu cầu

| Thành phần | Ghi chú |
|---|---|
| Máy host | Linux x86_64 (VM cũng được), Docker Engine + `docker compose` v2 |
| CPU/RAM | 2 vCPU / 2 GB là dư cho 16 người |
| Disk | ~3 GB (image + volume asset, zip client ~250 MB) |
| Mạng | Ra internet **một lần** để tải SteamCMD + game files |
| Client | Chrome / Edge / Firefox bản mới. Không cần HTTPS. |

Job `assets` chạy image `i386/debian` cho server — trên host amd64 container 32-bit chạy
native nhờ lớp tương thích ia32 của kernel, không phải emulation (ReGameDLL chỉ có bản
linux32).

## 3. Chạy lần đầu

```bash
git clone <repo> web-cs && cd web-cs
cp .env.example .env      # sửa MAP / MAXPLAYERS / ACCESS_CODE nếu muốn
./run.sh
```

`run.sh` sẽ: build 3 image → chạy job `assets` (SteamCMD tải HLDS app 90, ~2 GB, một lần)
→ `docker compose up -d` → in ra link.

Lần đầu mở link, mỗi người tải ~250 MB file game (đã lược bỏ map/media/overviews của
Half-Life mà CS 1.6 không dùng; toàn bộ `sound/` được giữ vì server vẫn precache vài file
ambient). Zip được client giữ trong **Cache Storage** (`webcs-game-v1`) và kiểm tra bằng
`HEAD` + ETag, nên lần vào sau chỉ tốn một request vài trăm byte; assets đổi thì ETag đổi và
client tự tải lại.

Nếu muốn làm từng bước:

```bash
docker compose build
docker compose --profile setup run --rm assets     # tạo volume: valve/, cstrike/, game.zip
docker compose up -d
```

## 4. Đưa cho coworker dùng qua NetBird

1. Máy host cài NetBird, join cùng network với mọi người (`netbird up`).
2. Lấy IP NetBird: `ip -4 addr show wt0`.
3. Mở firewall cho TCP 27016 trên interface `wt0`:
   ```bash
   sudo ufw allow in on wt0 to any port 27016 proto tcp
   ```
4. Gửi link `http://<ip-netbird>:27016`. Nếu bật MagicDNS trong NetBird thì dùng luôn
   tên peer: `http://may-chu-cs:27016` (nhớ mở firewall theo port, không theo IP).

Muốn **chỉ** nghe trên NetBird (không lộ ra LAN/Internet):

```yaml
# docker-compose.yml
ports:
  - "100.64.0.5:27016:8080"    # IP NetBird của host
```

Không cần mở UDP. Nếu công ty chặn TCP giữa các peer, NetBird sẽ relay — vẫn chơi được,
chỉ tăng ping (xem `netbird status`).

## 5. Dashboard & phòng chơi

Mở `http://<ip>:27016` là **dashboard**:

- **Tạo phòng**: tên, **chế độ chơi** (Casual / Gần thi đấu / Parkour), map, số người tối đa,
  mật khẩu phòng (tuỳ chọn), số bot (**mặc định 0** — chủ phòng thêm/bớt bot trong game bằng
  nút **+ / −** ở tab Server).
- **Pool map theo chế độ**: preset khai báo tiền tố map trong `config/presets.json`
  (`maps: ["kz_", "surf_", …]` cho parkour) nên chọn Parkour là ô map chỉ còn map phù hợp;
  pool rỗng thì hiện mọi map kèm gợi ý cài map. Cvar của chế độ áp ngay sau khi server boot-
  xong, và áp lại sau mỗi lần `changelevel`. Ô **Bot** luôn thắng `yb_quota` của preset.
- **Hai cây game**: phòng parkour chạy một basedir riêng không có YaPB; phòng còn lại chạy
  cây YaPB. `ls /xashkz` trong container game thấy cây parkour (symlink về `/xashds`, không
  nhân bản asset). Nên **bot chỉ có ở phòng không-parkour** — nút ± Bot ở phòng parkour
  không có tác dụng.
  Cây parkour hiện **chạy `cs.so` trần** (không checkpoint/timer): `amxmodx_mm_i386.so`
  — cả 1.9.0.5303 lẫn 1.10.0.5487 — nhảy vào `0x00000000` từ
  `C_ClientUserInfoChanged_Post` khi client gửi userinfo, server SIGSEGV và client về
  menu (gdb backtrace; metamod một mình thì join được). Bật lại bằng `KZ_AMXX=1` trong
  `.env` khi tìm được bản AMXX tương thích engine — khi đó `config/amxx-lang/*.txt` mới
  có tác dụng: chữ chat/HUD của ProKreedz, key trích từ `.sma`, sửa xong áp cho phòng tạo sau.
- Người tạo phòng là **chủ phòng** (token lưu trên máy đó): chỉ chủ phòng đổi map/preset/
  bots/đóng phòng. Người khác chỉ xem và bấm **Vào**.
- **Vòng đời**: phòng trống người thật quá 30 phút tự đóng; chủ phòng cũng đóng được bất cứ
  lúc nào (tab Server → *Đóng phòng*).
- Trong game, menu **ESC → tab Server** là bảng điều khiển của phòng: preset chế độ chơi
  (Casual / Gần thi đấu / **Parkour** kz-surf), chọn map, restart ván, thêm/bớt bot.
- Phòng sống xuyên qua lần restart web server (lưu trong volume, tự spawn lại).

Muốn thêm map (kz/surf/custom): copy `.bsp` vào volume như mục 6 — map mới xuất hiện ngay
trong pool của dashboard lẫn tab Server.

## 6. Cấu hình

`.env`:

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `MAP` | `de_dust2` | Map đầu tiên (phải có trong `cstrike/maps`) |
| `MAXPLAYERS` | `16` | Số slot |
| `WEB_PORT` | `27016` | Cổng trên host |
| `ACCESS_CODE` | rỗng | Nếu đặt: phải nhập mã ở ô **Mã vào** mới vào được game (link play `?code=...` tự mang mã). Tạo phòng và xem danh sách thì không cần mã. Mặc định rỗng = vào thẳng; khi đó nút **Cài map từ URL** (trong game, menu ESC → tab **Server**, chỉ chủ phòng) bị chặn vì endpoint để server tự tải URL (SSRF) — muốn dùng thì đặt mã tạm, hoặc thả file `.bsp` vào `cstrike/maps` |

Luật chơi: `config/server.cfg` (giá trị CS 1.6 gốc: `mp_startmoney 800`, `mp_roundtime 3`,
`mp_freezetime 3`…). Sửa xong `docker compose restart game`.

**Đổi rcon_password** trong `config/server.cfg` trước khi deploy — file này được copy vào
container mỗi lần start.

## 7. Thêm map

```bash
# 1. copy .bsp vào volume asset
docker run --rm -v web-cs_assets:/data -v "$PWD/maps":/src alpine \
  cp /src/de_aztec.bsp /data/cstrike/maps/

# 2. nén lại game.zip để client tải được map mới
docker compose --profile setup run --rm -e FORCE_ZIP=1 assets

# 3. khởi động lại server với map mới
MAP=de_aztec docker compose up -d game
```

Map custom dùng texture ngoài WAD gốc cần kèm cả `.wad`/`gfx/env/*` vào `cstrike/`, rồi
`FORCE_ZIP=1` lại.

## 8. Vận hành

```bash
docker compose ps
docker compose logs -f web        # bridge, WS, lỗi asset
docker compose logs -f game       # log engine GoldSrc
docker stats                      # RAM/CPU
```

- **Đổi map:** sửa `MAP` trong `.env` rồi `docker compose up -d game` (game restart ~5 s;
  mọi người reconnect tự động).
- **Cập nhật engine/ReGameDLL:** `docker compose build --no-cache game && docker compose up -d`.
- **Xoá sạch asset (tải lại từ đầu):** `docker compose down -v`.
- **Xem ai đang chơi:** panel trong lobby, hoặc `curl http://127.0.0.1:27016/api/status`.

## 9. Khác biệt so với CS 1.6 nguyên bản

Đây là danh sách trung thực, không tô hồng:

| Hạng mục | Trạng thái |
|---|---|
| Gameplay, vũ khí, kinh tế, movement, netcode | **Giống hệt** — `cs16-client` là bản reverse-engineer của chính client 1.6, chạy protocol 48 |
| Map, model, âm thanh, sprite | **File gốc của Valve** (HLDS app 90) |
| Engine | **Xash3D FWGS** (viết lại tương thích), không phải engine Valve. Vài hiệu ứng/hiển thị có thể lệch rất nhỏ |
| Menu trong game (VGUI) | Không dùng được trên bản wasm → thay bằng overlay web (ESC). Mua súng/HUD vẫn là HUD gốc |
| Voice chat trong game | **Tắt** (engine wasm đòi micro, mà trang chạy HTTP nên browser chặn). Dùng Discord/Meet song song |
| Steam / VAC / server browser | Không có. Vào server tự động, không cần login |
| Bots | **YaPB** (public-domain, standalone plugin) điền chỗ trống — tab *Server* hoặc preset đổi số lượng |
| `cl_minmodels`, `hud_fastswitch`, `sensitivity`, `rate`… | Có, set qua lobby hoặc console |

Nếu ai cần "đúng 100% binary Valve", chỉ có hai đường: cài CS 1.6 native rồi connect qua
NetBird, hoặc game-streaming từ máy có GPU (mỗi người một session). Cả hai đều bỏ ưu điểm
"mở link là chơi" của repo này.

## 10. Sự cố thường gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| Lobby báo “không phản hồi” | Container `game` chưa lên hoặc chưa có asset. `docker compose logs game` |
| `/game.zip` trả 503 | Chưa chạy `docker compose --profile setup run --rm assets` |
| `assets` báo *“Steamcmd needs to be online”* dù máy có internet | DNS của host bị VPN (NetBird…) ghi đè và trả `127.0.0.1` cho tên công cộng. Compose đã đặt `dns: 1.1.1.1/8.8.8.8` cho cả 3 service; nếu mạng chặn DNS công cộng thì sửa giá trị đó |
| Tải xong nhưng màn hình đen | Kiểm tra WebGL: mở `chrome://gpu`, thử `--use-angle=default`; cập nhật driver/Chrome |
| Vào được nhưng đứng ở “đang kết nối” | Mở **Nhật ký** (góc dưới lobby, hoặc `?debug=1`). Thường do WS bị proxy chặn hoặc `ACCESS_CODE` sai |
| Ping cao bất thường | NetBird đang relay thay vì P2P: `netbird status -d`, mở UDP hoặc dùng peer gần |
| Mất kết nối giữa chừng | Client tự reconnect (1,2 s). Nếu lặp lại, xem log `web` |
| Âm thanh không có | Browser chặn autoplay: click vào canvas một lần |
| Chuột không khóa | Click vào màn hình; một số extension (vimium…) chiếm phím |

## 11. Phát triển / chỉnh client

```bash
# Cần Node 20+
node scripts/vendor-engine.mjs        # tải + verify 2 DLL wasm (đã có sẵn trong repo)
cd client && npm install
npm run build                          # tsc --noEmit && vite build
npx vite                               # dev server :5173, proxy /api,/ws sang server

# kiểm tra bridge không cần game server
node ../scripts/smoke-test.mjs
node ../scripts/smoke-remote.mjs      # nhánh Docker: supervisor + proxy + tunnel (cần python3)
```

Cấu trúc:

```
client/src/transport.ts   # WebSocket transport (sendto/incoming của engine)
client/src/engine.ts      # boot Xash3D, map DLL, mount asset, +connect
client/src/assets.ts      # tải + giải nén game.zip vào MEMFS
server/src/bridge.js      # mỗi WS ↔ một UDP socket
server/src/a2s.js         # A2S_INFO cho panel trạng thái
docker/assets.sh          # SteamCMD → trim → game.zip
```

Phụ thuộc đáng lưu ý: engine (`xash3d-fwgs@1.2.2`) và client DLL (`cs16-client` build) đều
đã bị **unpublish** khỏi npm/GitHub trong 2026, nên chúng được vendor trong
`client/vendor/` (sha256 pin trong `client/vendor/xash3d-fwgs/SHA256SUMS` và
`scripts/vendor-engine.mjs`). Đừng xoá thư mục đó.

## 12. Test native trên Windows (không cần Docker)

Đây là cách mình đã kiểm chứng toàn bộ stack trên chính máy dev. Dùng khi cần thử nhanh
trước khi deploy VM, hoặc để debug asset/map.

```powershell
# 0. Node 20+ và Chrome. Các bước dưới dùng .cache/ (đã gitignore).

# 1. SteamCMD + HLDS (app 90) — nguồn asset + sẵn mp.dll của Valve
curl.exe -sSL -o .cache\steamcmd.zip https://media.steampowered.com/client/installer/steamcmd.zip
Expand-Archive .cache\steamcmd.zip .cache\steamcmd -Force
.\.cache\steamcmd\steamcmd.exe +force_install_dir "$PWD\.cache\hlds" +login anonymous +app_update 90 validate +quit

# 2. Xash3D Windows (i386 để load được mp.dll 32-bit)
curl.exe -sSL -o .cache\xash.7z https://github.com/FWGS/xash3d-fwgs/releases/download/continuous/xash3d-fwgs-win32-i386.7z
curl.exe -sSL -o .cache\7zr.exe https://github.com/ip7z/7zip/releases/download/25.01/7zr.exe
.\.cache\7zr.exe x .cache\xash.7z -o.cache\xash-win -y

# 3. Dựng thư mục server
robocopy .cache\hlds\valve .cache\server\valve /E
robocopy .cache\hlds\cstrike .cache\server\cstrike /E
Copy-Item .cache\xash-win\*.exe,.cache\xash-win\*.dll .cache\server\ -Force
Copy-Item config\liblist.gam,config\server.cfg,config\motd.txt .cache\server\cstrike\ -Force

# 4. Zip cho browser
node scripts\make-client-zip.mjs .cache\hlds .cache\client-game.zip
cd client ; npm ci ; npm run build ; cd ..

# 5. Chạy
Start-Process .\.cache\server\xash3d.exe -ArgumentList '-dedicated','-game','cstrike','-port','27015','+map','de_dust2','+maxplayers','16','+sv_lan','1' -WorkingDirectory .cache\server
$env:PORT='27016'; $env:GAME_HOST='127.0.0.1'; $env:GAME_PORT='27015'
$env:PUBLIC_DIR="$PWD\client\dist"; $env:GAME_ZIP="$PWD\.cache\client-game.zip"
node server\src\index.js
```

Mở `http://127.0.0.1:27016`. Nếu cần xem log engine: `?debug=1`, hoặc `__webcs.log.lines`
trong DevTools.

## 13. Trạng thái kiểm thử

Đã chạy end-to-end trên Windows (Chrome thật + Xash3D dedicated Windows + asset HLDS app 90
+ ReGameDLL `mp.dll`) — cập nhật lần 2:

| Hạng mục | Kết quả |
|---|---|
| `tsc --noEmit` + `vite build` | ✅ pass |
| Static/ETag/gzip/SPA + tunnel WS↔UDP | ✅ `scripts/smoke-test.mjs` |
| Nhánh Docker (supervisor + proxy + WS bridge, `GAME_MGR`), **không cần Docker** | ✅ `scripts/smoke-remote.mjs` |
| Engine wasm + client/menu DLL trong Chrome | ✅ boot, mount **255 MB dạng pk3 trong ~60 ms** (không còn giải nén 464 MB vào MEMFS) |
| Tải `game.zip` từ server | ✅ có progress, cache theo ETag |
| Handshake GoldSrc protocol 48 qua tunnel | ✅ `server 127.0.0.1:27015` |
| Vào map + render | ✅ de_dust2 / cs_assault, canvas 1280×720, menu chọn team, HUD `1 / 16` |
| **Bots YaPB** (standalone, chain ReGameDLL) | ✅ 9 bots join + điều khiển qua rcon `yb_quota` |
| **RCON** (format Xash3D: không challenge, cần `rcon_enable 1`) | ✅ hostname/bot_quota/changelevel |
| **Preset + map picker + whitelist admin** | ✅ áp preset casual (9 lệnh), changelevel qua API, chặn lệnh ngoài whitelist |
| Tab Server / Hướng dẫn trong overlay ESC | ✅ render đúng, 25 map + 3 preset |
| Docker compose (Linux/i386) | ⛔ chưa chạy trên máy này (không có Docker) — cần test khi deploy VM |

Bốn lỗi đã gặp và đã sửa, nếu bạn đụng lại thì biết đường:

1. `Couldn't find game directory 'cstrike'` → thiếu `cstrike/liblist.gam` trong `game.zip`
   (script zip giờ luôn chèn `config/liblist.gam`).
2. `Xash3D FWGS version check failed` → client DLL build cho engine mới hơn. DLL đúng cặp
   với engine 1.2.2 là build 478 KB từ `x8BitRain/webXash@gh-pages` (đã vendor + pin sha256).
   Đừng thay bằng bản 639 KB từ `xash-cs-demo`.
3. `could not load dynamic lib: dlls/cs_emscripten_wasm32.wasm` (alert lúc bấm vào game) →
   engine `dlopen` server module lúc init; phải preload từ đầu (đã đưa vào
   `dynamicLibraries` + map sang `cs_emscripten_wasm32.wasm` đã vendor). Emscripten không
   fetch được dynamic library lúc runtime.
4. `.pk3` phải nằm **trong từng gamedir** (`valve/valve.pk3`, `cstrike/cstrike.pk3`, path
   relative tới gamedir) + `cstrike/liblist.gam` là **file thật** — đặt pk3 ở basedir thì
   engine không nhận game dir (`Couldn't find game directory`).

## 14. Bản quyền

- Engine Xash3D FWGS: GPL-3.0. `cs16-client`: GPL-2.0+ (kèm ngoại lệ link với Half-Life).
  Wrapper TypeScript: MIT.
- Nội dung game (`valve/`, `cstrike/`) là **bản quyền của Valve**. Repo này không chứa và
  không phân phối chúng; job `assets` tải qua kênh HLDS của Valve về máy bạn. Chỉ dùng nội
  bộ, đừng public ra Internet — vừa là vấn đề bản quyền, vừa là rủi ro bị quét.
