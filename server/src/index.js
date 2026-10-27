import http from 'node:http'
import { createReadStream } from 'node:fs'
import { stat, readdir, readFile, mkdir, writeFile, rename } from 'node:fs/promises'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { createGzip } from 'node:zlib'
import { WebSocketServer } from 'ws'

import { attachBridge } from './bridge.js'
import { log } from './logger.js'
import {
  createRoom,
  listRooms,
  getRoom,
  isOwner,
  patchRoom,
  deleteRoom,
  startRoomManager,
  remoteMode,
} from './rooms-local.js'
import { rconCommand } from './rcon.js'
import {
  isGoldSrcBsp,
  isRar,
  isZip,
  extractArchive,
  loadCustomFiles,
  packCustomPk3,
} from './custom-maps.js'

const PORT = Number(process.env.PORT ?? 8080)
const PUBLIC_DIR = path.resolve(process.env.PUBLIC_DIR ?? '/app/public')
const GAME_ZIP = path.resolve(process.env.GAME_ZIP ?? '/data/game.zip')
const GAME_HOST = process.env.GAME_HOST ?? '127.0.0.1'
const ACCESS_CODE = (process.env.ACCESS_CODE ?? '').trim()
const RCON_PASSWORD = (process.env.RCON_PASSWORD ?? 'doi-mat-khau-nay').trim()
const ASSETS_DIR = path.resolve(process.env.ASSETS_DIR ?? '/data')
const CUSTOM_PK3 = path.join(ASSETS_DIR, 'cstrike', 'custom.pk3')
const CUSTOM_VERSION_FILE = path.join(ASSETS_DIR, 'custom.version')
const MAX_MAP_FILE_BYTES = 100 * 1024 * 1024
const PRESETS_FILE = path.resolve(process.env.PRESETS_FILE ?? '/app/config/presets.json')
const GAME_MGR = (process.env.GAME_MGR ?? '').replace(/\/$/, '')
const MAX_CONNECTIONS = Number(process.env.MAX_CONNECTIONS ?? 64)

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pk3': 'application/octet-stream',
  '.zip': 'application/zip',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
}

const COMPRESSIBLE = new Set(['.html', '.js', '.css', '.json', '.svg', '.txt'])

let connections = 0

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

function sendJson(response, statusCode, body) {
  const payload = JSON.stringify(body)
  response.writeHead(statusCode, {
    'content-type': MIME['.json'],
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  })
  response.end(payload)
}

async function fileEtag(filePath) {
  const info = await stat(filePath)
  if (!info.isFile()) return null
  const tag = createHash('sha1')
    .update(`${info.size}:${info.mtimeMs}`)
    .digest('base64url')
    .slice(0, 16)
  return { info, etag: `"${tag}"` }
}

function streamFile(request, response, filePath, { cacheControl, contentType, etag, size, gzip }) {
  const headers = { 'content-type': contentType, 'cache-control': cacheControl }
  if (etag) headers.etag = etag
  if (gzip) {
    headers['content-encoding'] = 'gzip'
    headers.vary = 'accept-encoding'
  } else {
    headers['content-length'] = String(size)
  }

  response.writeHead(200, headers)
  if (request.method === 'HEAD') {
    response.end()
    return
  }

  const stream = createReadStream(filePath)
  if (gzip) stream.pipe(createGzip()).pipe(response)
  else stream.pipe(response)
  stream.on('error', () => response.destroy())
}

function readBody(request, limit = 16 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    request.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error('body quá lớn'))
        request.destroy()
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')))
    request.on('error', reject)
  })
}

/* ------------------------------------------------------------------ */
/* rooms: local manager hoặc proxy sang supervisor (Docker)            */
/* ------------------------------------------------------------------ */

const ROOMS_PATH_RE = /^\/api\/rooms(\/[\w-]+(\/preset)?)?$/

async function proxyRooms(request, response, url) {
  const upstreamUrl = new URL(GAME_MGR + url.pathname.replace(/^\/api\/rooms/, '/rooms') + url.search)
  const headers = { 'x-room-token': request.headers['x-room-token'] ?? '' }
  let body
  if (request.method !== 'GET') body = await readBody(request)
  if (body?.map !== undefined && !(await mapInstalled(body.map))) {
    return sendJson(response, 400, { error: `map "${body.map}" chưa có trên server` })
  }

  const upstream = await fetch(upstreamUrl, {
    method: request.method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  }).catch((error) => {
    throw new Error(`supervisor không trả lời: ${error.message}`)
  })

  let payload = await upstream.text()
  // Supervisor tự tính isOwner theo token phòng; mã admin toàn cục chỉ web biết.
  if (request.method === 'GET' && upstream.ok && /^\/api\/rooms\/[\w-]+$/.test(url.pathname) && isRoomAdmin(request)) {
    try {
      payload = JSON.stringify({ ...JSON.parse(payload), isOwner: true })
    } catch {
      /* không phải JSON — trả nguyên văn */
    }
  }
  response.writeHead(upstream.status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  })
  response.end(payload)
}

function isRoomAdmin(request, room) {
  const token = request.headers['x-room-token']
  if (room && isOwner(room, token)) return true
  if (ACCESS_CODE && request.headers['x-access-code'] === ACCESS_CODE) return true
  return false
}

async function listMaps() {
  const mapsDir = path.join(ASSETS_DIR, 'cstrike', 'maps')
  const names = await readdir(mapsDir).catch(() => [])
  return names
    .filter((name) => name.endsWith('.bsp'))
    .map((name) => name.slice(0, -4))
    .sort()
}

/** Tên map phải có .bsp trên server, nếu không phòng boot vào map mặc định mà vẫn trả 200. */
async function mapInstalled(name) {
  return (await listMaps()).includes(String(name))
}

async function loadPresets() {
  try {
    return JSON.parse(await readFile(PRESETS_FILE, 'utf8'))
  } catch (error) {
    log.warn(`không đọc được presets: ${error.message}`)
    return {}
  }
}

async function applyPresetToRoom(room, presetName) {
  const presets = await loadPresets()
  const preset = presets[presetName]
  if (!preset) throw new Error('preset không tồn tại')
  for (const command of preset.commands) {
    await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, command)
  }
  log.info(`room ${room.id}: preset "${presetName}" (${preset.commands.length} lệnh)`)
  return preset.commands.length
}

/** Ở chế độ Docker, danh sách phòng nằm ở supervisor — không có bản sao cục bộ. */
async function remoteRooms() {
  try {
    const response = await fetch(`${GAME_MGR}/rooms`)
    if (!response.ok) return []
    const payload = await response.json()
    return payload?.rooms ?? []
  } catch {
    return []
  }
}

/** Routes /api/* (trừ /game.zip, /healthz). */
async function handleApi(request, response, url) {
  // Docker: phòng do supervisor quản.
  if (remoteMode && ROOMS_PATH_RE.test(url.pathname)) {
    return proxyRooms(request, response, url)
  }

  const method = request.method
  const roomMatch = url.pathname.match(/^\/api\/rooms\/([\w-]+)$/)
  const presetMatch = url.pathname.match(/^\/api\/rooms\/([\w-]+)\/preset$/)

  // Play page hỏi trước khi tải engine: mã sai vốn chỉ hiện ra dưới dạng
  // WebSocket chết lặng, và engine vẫn boot thành game cục bộ.
  if (url.pathname === '/api/entry') {
    if (ACCESS_CODE && request.headers['x-access-code'] !== ACCESS_CODE) {
      return sendJson(response, 401, { error: 'mã truy cập sai hoặc thiếu' })
    }
    return sendJson(response, 200, { ok: true })
  }

  // HUD trong game (?room=<id>): legacy shape cho client cũ/mới đều hiểu.
  if (url.pathname === '/api/status') {
    const requested = url.searchParams.get('room')
    const rooms = remoteMode ? await remoteRooms() : listRooms()
    const target = (requested && rooms.find((r) => r.id === requested)) || rooms[0]
    if (!target) return sendJson(response, 200, { online: false })
    return sendJson(response, 200, {
      online: true,
      name: target.name,
      map: target.map,
      players: target.players,
      maxPlayers: target.maxplayers,
      bots: target.bots,
    })
  }

  if (url.pathname === '/api/rooms' && method === 'GET') {
    return sendJson(response, 200, { rooms: listRooms() })
  }

  if (url.pathname === '/api/rooms' && method === 'POST') {
    const body = await readBody(request)
    if (body.map !== undefined && !(await mapInstalled(body.map))) {
      return sendJson(response, 400, { error: `map "${body.map}" chưa có trên server` })
    }
    try {
      const created = await createRoom({
        name: body.name,
        map: body.map,
        maxplayers: body.maxplayers,
        password: body.password,
        bots: body.bots ?? 0,
        preset: body.preset,
        proc: body.proc,
        port: body.port,
      })
      return sendJson(response, 200, created)
    } catch (error) {
      if (error.status === 409) return sendJson(response, 409, { error: error.message })
      throw error
    }
  }

  if (presetMatch && method === 'POST') {
    const target = getRoom(presetMatch[1])
    if (!target) return sendJson(response, 404, { error: 'phòng không tồn tại' })
    if (!isRoomAdmin(request, target)) return deny(response)
    const body = await readBody(request)
    const applied = await applyPresetToRoom(target, String(body?.name ?? ''))
    return sendJson(response, 200, { ok: true, applied })
  }

  if (roomMatch) {
    const target = getRoom(roomMatch[1])

    if (method === 'GET') {
      if (!target) return sendJson(response, 404, { error: 'phòng không tồn tại' })
      return sendJson(response, 200, {
        id: target.id,
        name: target.name,
        map: target.map,
        maxplayers: target.maxplayers,
        hasPassword: Boolean(target.password),
        bots: target.bots,
        players: target.status.players,
        humans: target.status.humans,
        isOwner: isRoomAdmin(request, target),
      })
    }

    if (method === 'PATCH') {
      if (!target) return sendJson(response, 404, { error: 'phòng không tồn tại' })
      if (!isRoomAdmin(request, target)) return deny(response)
      const body = await readBody(request)
      if (body.map !== undefined && !(await mapInstalled(body.map))) {
        return sendJson(response, 400, { error: `map "${body.map}" chưa có trên server` })
      }
      if (body.restart) await rconCommand('127.0.0.1', target.port, RCON_PASSWORD, 'sv_restart 1')
      const view = await patchRoom(target.id, body)
      return sendJson(response, 200, view)
    }

    if (method === 'DELETE') {
      if (!isRoomAdmin(request, target)) return deny(response)
      const removed = await deleteRoom(target.id)
      return sendJson(response, removed ? 200 : 404, { ok: removed })
    }
  }

  if (url.pathname === '/api/maps') {
    return sendJson(response, 200, { maps: await listMaps().catch(() => []) })
  }

  if (url.pathname === '/api/presets') {
    const presets = await loadPresets()
    return sendJson(
      response,
      200,
      Object.fromEntries(
        Object.entries(presets).map(([id, p]) => [id, { label: p.label, maps: p.maps ?? [] }]),
      ),
    )
  }

  if (url.pathname === '/api/custom') {
    const version = (await readFile(CUSTOM_VERSION_FILE, 'utf8').catch(() => '')).trim()
    return sendJson(response, 200, { version })
  }

  if (url.pathname === '/api/admin/maps/install' && method === 'POST') {
    if (!isGlobalAdmin(request)) return deny(response)
    const body = await readBody(request, 4096)
    const name = String(body?.name ?? '').toLowerCase()
    let mapUrl = String(body?.url ?? '')

    if (!/^[a-z][a-z0-9_]{2,31}$/.test(name)) {
      return sendJson(response, 400, { error: 'tên map phải là a-z, 0-9, _ (3-32 ký tự)' })
    }
    if (!/^https?:\/\//i.test(mapUrl)) {
      return sendJson(response, 400, { error: 'url phải là http(s)' })
    }

    // GameBanana mod page (vd gamebanana.com/mods/95619): tự bấm vào danh sách
    // file của mod, ưu tiên .zip/.bsp rồi mới .rar.
    const gbMod = mapUrl.match(/gamebanana\.com\/mods\/(\d+)/i)
    if (gbMod) {
      const filesRes = await fetch(`https://gamebanana.com/apiv11/Mod/${gbMod[1]}/Files`, {
        headers: { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) web-cs/1.0' },
      })
      if (!filesRes.ok) {
        return sendJson(response, 502, { error: `GameBanana Files API HTTP ${filesRes.status}` })
      }
      const files = await filesRes.json()
      const preferred = files.find((f) => /\.(zip|bsp)$/i.test(f._sFile)) ?? files[0]
      if (!preferred) {
        return sendJson(response, 404, { error: 'mod không có file nào' })
      }
      mapUrl = `https://gamebanana.com/dl/${preferred._idRow}`
      log.info(`GameBanana mod ${gbMod[1]} -> file ${preferred._idRow} (${preferred._sFile})`)
    }

    log.info(`install map "${name}" từ ${mapUrl}`)
    try {
      const res = await fetch(mapUrl, {
        redirect: 'follow',
        headers: { 'user-agent': 'web-cs/1.0' },
      })
      if (!res.ok) {
        return sendJson(response, 502, { error: `tải thất bại HTTP ${res.status}` })
      }
      const buffer = Buffer.from(await res.arrayBuffer())
      if (buffer.byteLength > MAX_MAP_FILE_BYTES) {
        return sendJson(response, 400, { error: `file quá lớn (${(buffer.byteLength / 1e6).toFixed(1)} MB > 100 MB)` })
      }

      let extracted = {}
      let bspFiles = {}
      if (isGoldSrcBsp(buffer)) {
        extracted[`${name}.bsp`] = buffer
      } else if (isZip(buffer) || isRar(buffer)) {
        extracted = await extractArchive(buffer)
        log.info(`extract: ${Object.keys(extracted).length} file từ archive`)
        for (const [base, data] of Object.entries(extracted)) {
          if (!base.endsWith('.bsp')) continue
          if (!isGoldSrcBsp(data)) {
            log.warn(`bỏ qua ${base}: không phải GoldSrc bsp v30`)
            continue
          }
          bspFiles[base.toLowerCase()] = data
        }
        if (!Object.keys(bspFiles).length) {
          return sendJson(response, 400, { error: 'archive không chứa GoldSrc .bsp (bỏ qua các bsp sai định dạng)' })
        }
      } else {
        return sendJson(response, 400, { error: 'chỉ hỗ trợ .bsp / .zip / .rar' })
      }

    // Ghi bsp cho game server + gói TOÀN BỘ tài nguyên vào custom.pk3 cho client
    // (models/sound/overviews đi kèm map custom — thiếu sẽ lỗi "Could not load").
    const mapsDir = path.join(ASSETS_DIR, 'cstrike', 'maps')
    await mkdir(mapsDir, { recursive: true })
    const installed = []
    const customFiles = await loadCustomFiles(CUSTOM_PK3)
    for (const [relPath, data] of Object.entries(extracted)) {
      if (relPath.endsWith('.bsp')) {
        await writeFile(path.join(mapsDir, path.basename(relPath)), data)
        installed.push(path.basename(relPath).replace(/\.bsp$/, ''))
      }
      customFiles[relPath] = data
    }
    log.info(`pack debug: bspFiles=${Object.keys(bspFiles).length} customFiles=${Object.keys(customFiles).length}`)
    const { packed, version } = packCustomPk3(customFiles)
    // Ghi qua file tạm rồi rename: client đang tải /custom.pk3 sẽ thấy bản cũ
    // trọn vẹn, không bao giờ nhận file cụt giữa lúc cài map.
    const tmpPk3 = `${CUSTOM_PK3}.tmp`
    await writeFile(tmpPk3, packed)
    await rename(tmpPk3, CUSTOM_PK3)
    await writeFile(path.join(ASSETS_DIR, 'custom.version'), version + '\n')
    log.info(`installed maps: ${installed.join(', ')} (custom.pk3 ${version})`)

    return sendJson(response, 200, { ok: true, installed, version })
    } catch (error) {
      return sendJson(response, 400, { error: error.message })
    }
  }

  sendJson(response, 404, { error: 'not-found' })
  log.warn(`api 404: ${method} ${url.pathname}`)
}

function isGlobalAdmin(request) {
  // Không đặt mã = không có admin toàn cục: cài map từ URL để server tự fetch
  // (SSRF) không thể mở cho bất kỳ ai trong mesh. Chủ phòng vẫn quản lý phòng
  // của mình bằng owner token (isRoomAdmin).
  return Boolean(ACCESS_CODE) && request.headers['x-access-code'] === ACCESS_CODE
}

async function serveCustomPk3(request, response) {
  const meta = await fileEtag(CUSTOM_PK3).catch(() => null)
  if (!meta) return sendJson(response, 404, { error: 'chưa có map custom nào' })
  if (request.headers['if-none-match'] === meta.etag) {
    response.writeHead(304, { etag: meta.etag, 'cache-control': 'public, max-age=86400' })
    response.end()
    return
  }
  streamFile(request, response, CUSTOM_PK3, {
    cacheControl: 'public, max-age=86400',
    contentType: MIME['.pk3'],
    etag: meta.etag,
    size: meta.info.size,
    gzip: false,
  })
}

function deny(response) {
  sendJson(response, 401, { error: 'không có quyền (cần token chủ phòng hoặc mã admin)' })
}

/* ------------------------------------------------------------------ */
/* static + game.zip                                                   */
/* ------------------------------------------------------------------ */

async function serveStatic(request, response, urlPath) {
  const decoded = decodeURIComponent(urlPath)
  const candidate = path.resolve(PUBLIC_DIR, `.${decoded}`)

  if (candidate !== PUBLIC_DIR && !candidate.startsWith(PUBLIC_DIR + path.sep)) {
    sendJson(response, 403, { error: 'forbidden' })
    return
  }

  let target = candidate
  const info = await stat(target).catch(() => null)

  if (!info?.isFile()) {
    if (path.extname(decoded)) {
      sendJson(response, 404, { error: 'not-found' })
      return
    }
    const page = decoded.startsWith('/play') ? 'play.html' : 'index.html'
    target = path.join(PUBLIC_DIR, page)
  }

  const meta = await fileEtag(target)
  if (!meta) {
    sendJson(response, 404, { error: 'not-found' })
    return
  }

  const ext = path.extname(target).toLowerCase()
  const hashedAsset = target.includes(`${path.sep}assets${path.sep}`)
  const cacheControl = hashedAsset ? 'public, max-age=31536000, immutable' : 'no-cache'
  const acceptsGzip = String(request.headers['accept-encoding'] ?? '').includes('gzip')

  if (request.headers['if-none-match'] === meta.etag) {
    response.writeHead(304, { etag: meta.etag, 'cache-control': cacheControl })
    response.end()
    return
  }

  streamFile(request, response, target, {
    cacheControl,
    contentType: MIME[ext] ?? 'application/octet-stream',
    etag: meta.etag,
    size: meta.info.size,
    gzip: acceptsGzip && COMPRESSIBLE.has(ext),
  })
}

async function serveGameZip(request, response) {
  const meta = await fileEtag(GAME_ZIP).catch(() => null)
  if (!meta) {
    return sendJson(response, 503, {
      error: 'game-assets-missing',
      hint: 'Chạy `docker compose --profile setup run --rm assets` để tạo /data/game.zip',
    })
  }

  if (request.headers['if-none-match'] === meta.etag) {
    response.writeHead(304, { etag: meta.etag, 'cache-control': 'no-cache' })
    response.end()
    return
  }

  streamFile(request, response, GAME_ZIP, {
    cacheControl: 'public, no-cache',
    contentType: MIME['.zip'],
    etag: meta.etag,
    size: meta.info.size,
    gzip: false,
  })
}

/* ------------------------------------------------------------------ */
/* http                                                                */
/* ------------------------------------------------------------------ */

const server = http.createServer((request, response) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`)
  const isApi = url.pathname.startsWith('/api/')

  if (!['GET', 'HEAD', 'POST', 'PATCH', 'DELETE'].includes(request.method)) {
    return sendJson(response, 405, { error: 'method-not-allowed' })
  }
  if (request.method === 'POST' && !isApi) {
    return sendJson(response, 405, { error: 'method-not-allowed' })
  }

  if (url.pathname === '/healthz') {
    return sendJson(response, 200, { ok: true, connections, rooms: listRooms().length })
  }

  if (isApi) {
    void handleApi(request, response, url).catch((error) => {
      log.error(`api ${url.pathname}: ${error.message}`)
      if (!response.headersSent) sendJson(response, 500, { error: 'internal-error' })
    })
    return
  }

  if (url.pathname === '/game.zip') {
    void serveGameZip(request, response).catch((error) => {
      log.error(`/game.zip: ${error.message}`)
      if (!response.headersSent) sendJson(response, 500, { error: 'internal-error' })
    })
    return
  }

  if (url.pathname === '/custom.pk3') {
    void serveCustomPk3(request, response).catch((error) => {
      log.error(`/custom.pk3: ${error.message}`)
      if (!response.headersSent) sendJson(response, 500, { error: 'internal-error' })
    })
    return
  }

  void serveStatic(request, response, url.pathname).catch((error) => {
    log.error(`static ${url.pathname}: ${error.message}`)
    if (!response.headersSent) sendJson(response, 500, { error: 'internal-error' })
  })
})

/* ------------------------------------------------------------------ */
/* websocket bridge                                                    */
/* ------------------------------------------------------------------ */

const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 })

/**
 * Port UDP của phòng cho WS upgrade.
 *
 * Nhánh native: rooms-local giữ map phòng ngay trong process. Nhánh Docker:
 * web chỉ proxy API nên không có bản sao danh sách — phải hỏi supervisor.
 */
async function resolveRoomPort(roomId) {
  if (!remoteMode) {
    const room = roomId ? getRoom(roomId) : listRooms()[0]
    return room?.port ?? null
  }
  const response = await fetch(GAME_MGR + (roomId ? `/rooms/${encodeURIComponent(roomId)}` : '/rooms'))
  if (!response.ok) return null
  const payload = await response.json()
  const room = roomId ? payload : payload?.rooms?.[0]
  return Number(room?.port) || null
}

server.on('upgrade', async (request, socket, head) => {
  try {
    const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`)

    if (url.pathname !== '/ws') {
      socket.destroy()
      return
    }

    if (ACCESS_CODE && url.searchParams.get('code') !== ACCESS_CODE) {
      log.warn('từ chối WS: sai mã truy cập')
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n')
      socket.destroy()
      return
    }

    if (connections >= MAX_CONNECTIONS) {
      log.warn('từ chối WS: đã đạt MAX_CONNECTIONS')
      socket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n')
      socket.destroy()
      return
    }

    const roomId = url.searchParams.get('room')
    const port = await resolveRoomPort(roomId).catch((error) => {
      log.warn(`WS upgrade: không lấy được port phòng "${roomId ?? '(trống)'}": ${error.message}`)
      return null
    })
    log.info(`WS upgrade: room=${roomId} port=${port}`)
    if (!port) {
      log.warn(`từ chối WS: phòng "${roomId ?? '(trống)'}" không tồn tại`)
      if (!socket.destroyed) {
        socket.write('HTTP/1.1 404 Not Found\r\n\r\n')
        socket.destroy()
      }
      return
    }
    if (socket.destroyed) return

    wss.handleUpgrade(request, socket, head, (ws) => {
      connections += 1
      const label = `${roomId ?? `port-${port}`}:${request.socket.remoteAddress}:${connections}`
      ws.on('close', () => {
        connections -= 1
      })
      attachBridge(ws, { host: GAME_HOST, port, label })
    })
  } catch (error) {
    log.warn(`WS upgrade lỗi: ${error.message}`)
    if (!socket.destroyed) socket.destroy()
  }
})

server.listen(PORT, '0.0.0.0', () => {
  log.info(`web-cs listening on :${PORT}`)
  log.info(`static: ${PUBLIC_DIR}`)
  log.info(`game zip: ${GAME_ZIP}`)
  if (remoteMode) {
    log.info(`room backend: supervisor ${GAME_MGR}`)
  } else {
    log.info('room backend: spawn trực tiếp (native)')
    startRoomManager()
  }
  if (ACCESS_CODE) log.info('access code: bật')
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    log.info(`nhận ${signal}, đang dừng`)
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 3000).unref()
  })
}
