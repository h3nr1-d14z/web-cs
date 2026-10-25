# Chạy stack CS 1.6 web ngay trên Windows, không cần Docker.
#
#   .\scripts\run-local.ps1                 # web :27016, dashboard tạo phòng
#
# Phòng chơi do web server tự spawn (xash3d.exe trong .cache\server); tạo phòng
# ở http://127.0.0.1:27016 rồi gửi link phòng cho đồng nghiệp.
#
# Yêu cầu: đã làm mục 12 trong README (.cache\server + .cache\client-game.zip + client\dist).
param(
  [int]$WebPort = 27016
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$node = Join-Path $root '.tools\node\node.exe'
if (-not (Test-Path $node)) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $cmd) { throw 'Không tìm thấy node.exe (cài Node 20+ hoặc để portable Node ở .tools\node).' }
  $node = $cmd.Source
}

$gameDir = Join-Path $root '.cache\server'
$zip = Join-Path $root '.cache\client-game.zip'
$dist = Join-Path $root 'client\dist'
$yapb = Join-Path $root '.cache\yapb-win\addons'

if (-not (Test-Path (Join-Path $gameDir 'xash3d.exe'))) {
  throw "Thiếu $gameDir — xem README mục 12 (bước 1-3)."
}
if (-not (Test-Path $zip)) {
  throw "Thiếu $zip — chạy: node scripts\make-client-zip.mjs .cache\hlds .cache\client-game.zip"
}
if (-not (Test-Path (Join-Path $dist 'play.html'))) {
  throw "Thiếu $dist\play.html — chạy: cd client; npm ci; npm run build"
}

# dừng node cũ (máy này chỉ chạy server của mình) + các server game cũ
Get-Process xash3d -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'web-cs|server\\src\\index\.js' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 800

# Cài YaPB bot (nếu đã tải .cache\yapb-win — xem README mục 12)
if (Test-Path $yapb) {
  New-Item -ItemType Directory -Force -Path (Join-Path $gameDir 'cstrike\addons') | Out-Null
  Copy-Item $yapb (Join-Path $gameDir 'cstrike\addons') -Recurse -Force
  $liblist = Join-Path $gameDir 'cstrike\liblist.gam'
  (Get-Content $liblist -Raw) -replace 'gamedll "dlls\\mp\.dll"', 'gamedll "addons\yapb\bin\yapb.dll"' |
    Set-Content $liblist -NoNewline
  Write-Host '→ YaPB bot: đã cài'
}

$env:PORT = "$WebPort"
$env:GAME_HOST = '127.0.0.1'
$env:PUBLIC_DIR = $dist
$env:GAME_ZIP = $zip
$env:ASSETS_DIR = $gameDir
$env:PRESETS_FILE = Join-Path $root 'config\presets.json'
$env:RCON_PASSWORD = 'doi-mat-khau-nay'
$env:XASH_BIN = Join-Path $gameDir 'xash3d.exe'
$env:GAME_DIR = $gameDir
$env:ROOMS_FILE = Join-Path $root '.cache\rooms.json'
$env:ROOM_UDP_BASE = '27015'
$env:EMPTY_TTL_MS = '1800000'
$env:LOG_LEVEL = 'info'

$web = Start-Process -FilePath $node -ArgumentList 'server\src\index.js' `
  -WorkingDirectory $root -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput (Join-Path $root '.cache\web.log') `
  -RedirectStandardError (Join-Path $root '.cache\web-err.log')

for ($i = 0; $i -lt 40; $i++) {
  try {
    $null = Invoke-WebRequest "http://127.0.0.1:$WebPort/healthz" -UseBasicParsing -TimeoutSec 1
    break
  } catch { Start-Sleep -Milliseconds 250 }
}

$lan = (Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' } |
  Sort-Object -Property { $_.InterfaceAlias -eq 'Netbird' } -Descending |
  Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "  ✅ Đang chạy.  web pid=$($web.Id)"
Write-Host ""
Write-Host "     Dashboard (tạo/quản lý phòng):"
Write-Host "       http://127.0.0.1:$WebPort"
if ($lan) { Write-Host "       http://${lan}:$WebPort   (NetBird/cùng mạng)" }
Write-Host ""
Write-Host "     Log web: .cache\web.log     Log từng phòng: .cache\server\room-<id>.log"
Write-Host "     Dừng:    Get-Process xash3d,node | Stop-Process -Force"
Write-Host ""
