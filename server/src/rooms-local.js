import { spawn } from 'node:child_process'
import { readFile, writeFile } from 'node:fs/promises'
import crypto from 'node:crypto'
import path from 'node:path'

import { queryServerInfo } from './a2s.js'
import { rconCommand } from './rcon.js'
import { log } from './logger.js'

/**
 * Quản lý phòng chơi: mỗi phòng = 1 tiến trình game server riêng (port riêng).
 *
 * - Tạo phòng  → spawn server, trả ownerToken (ai giữ token là "chủ phòng")
 * - Bots       → mặc định 0; chủ phòng sửa `bots` → gửi `yb_quota` qua rcon
 * - Tự đóng    → phòng trống người thật quá EMPTY_TTL_MS sẽ bị dọn
 * - Lưu trạng thái vào ROOMS_FILE để sống xuyên qua lần restart web server
 *
 * Backend này chạy khi web server tự spawn game server (dev/native Windows).
 * Khi chạy trong Docker (game container là i386, không chạy được node) dùng
 * supervisor python cùng REST API — chỉ cần đặt GAME_MGR=http://game:7000.
 */

const EMPTY_TTL_MS = Number(process.env.EMPTY_TTL_MS ?? 30 * 60 * 1000)
const UDP_BASE = Number(process.env.ROOM_UDP_BASE ?? 27015)
const RCON_PASSWORD = (process.env.RCON_PASSWORD ?? 'doi-mat-khau-nay').trim()
const BOOT_WAIT_MS = 10_000

const PRESETS_FILE = path.resolve(process.env.PRESETS_FILE ?? '/app/config/presets.json')

async function loadPresets() {
  try {
    return JSON.parse(await readFile(PRESETS_FILE, 'utf8'))
  } catch {
    return {}
  }
}

/** Preset sở hữu map này (preset khai báo `maps` = tiền tố tên map). */
function presetForMap(presets, map) {
  const name = String(map).toLowerCase()
  for (const [id, preset] of Object.entries(presets)) {
    if ((preset.maps ?? []).some((prefix) => name.startsWith(prefix))) return id
  }
  return ''
}

/** Áp cvar của mode: mode chủ phòng chọn lúc tạo, hoặc suy ra từ tên map.
 *  `yb_quota` gửi sau cùng để ô "Bot" ở dashboard luôn thắng preset. */
async function applyMode(room) {
  const presets = await loadPresets()
  const name = room.preset || presetForMap(presets, room.map)
  for (const command of presets[name]?.commands ?? []) {
    await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, command)
  }
  await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, `yb_quota ${room.bots}`)
  if (name) log.info(`room ${room.id}: mode "${name}" (${presets[name].commands.length} lệnh)`)
}

const rooms = new Map()
const dirty = () => persist().catch((error) => log.warn(`persist rooms: ${error.message}`))

function newId() {
  return `r${crypto.randomBytes(3).toString('hex')}`
}

function ownerToken() {
  return crypto.randomBytes(16).toString('hex')
}

async function persist() {
  if (!process.env.ROOMS_FILE) return
  const specs = [...rooms.values()].map((room) => ({
    id: room.id,
    name: room.name,
    map: room.map,
    maxplayers: room.maxplayers,
    password: room.password,
    bots: room.bots,
    preset: room.preset,
    port: room.port,
    ownerToken: room.ownerToken,
  }))
  await writeFile(process.env.ROOMS_FILE, JSON.stringify(specs, null, 2))
}

async function restore() {
  if (!process.env.ROOMS_FILE) return
  let specs = []
  try {
    specs = JSON.parse(await readFile(process.env.ROOMS_FILE, 'utf8'))
  } catch {
    return
  }
  for (const spec of specs) {
    if (rooms.has(spec.id)) continue
    log.info(`khôi phục phòng ${spec.id} (${spec.map})`)
    // spawnRoom() đọc đúng spec đã lưu; bots áp lại khi server sẵn sàng.
    await spawnRoom({ ...spec }).catch((error) => log.warn(`khôi phục ${spec.id}: ${error.message}`))
  }
}

function freePort() {
  const used = new Set([...rooms.values()].map((room) => room.port))
  for (let offset = 0; offset < 20; offset += 1) {
    const port = UDP_BASE + offset * 10
    if (!used.has(port)) return port
  }
  throw new Error('hết slot port cho phòng mới')
}

/** Spawn 1 server. `spec` đầy đủ ⇒ idempotent (dùng cho cả restore). */
async function spawnRoom(spec) {
  const id = spec.id ?? newId()
  const port = spec.port ?? freePort()
  const xashBin = process.env.XASH_BIN
  const gameDir = process.env.GAME_DIR
  if (!xashBin || !gameDir) {
    throw new Error('Thiếu XASH_BIN / GAME_DIR — không tự spawn được game server')
  }

  const args = [
    '-dedicated',
    '-log',
    '-game',
    'cstrike',
    '-port',
    String(port),
    '+hostname',
    `${spec.name || `Phòng ${id}`} · web-cs`,
    '+maxplayers',
    String(spec.maxplayers ?? 16),
    '+map',
    String(spec.map ?? 'de_dust2'),
    '+sv_lan',
    '1',
    '+exec',
    'server.cfg',
    '+rcon_password',
    RCON_PASSWORD,
    '+logaddress_add',
    '127.0.0.1 29000',
  ]
  if (spec.password) args.push('+sv_password', String(spec.password))

  log.info(`room ${id}: spawn ${path.basename(xashBin)} (port ${port}, map ${spec.map})`)
  const proc = spawn(xashBin, args, {
    cwd: gameDir,
    stdio: 'ignore',
    detached: false,
    windowsHide: true,
  })
  proc.on('exit', (code) => {
    log.warn(`room ${id}: server thoát (code ${code})`)
    if (rooms.get(id)?.proc === proc) {
      rooms.delete(id)
      dirty()
    }
  })

  const room = {
    id,
    name: spec.name || `Phòng ${id}`,
    map: spec.map ?? 'de_dust2',
    maxplayers: spec.maxplayers ?? 16,
    password: spec.password ?? '',
    bots: spec.bots ?? 0,
    preset: spec.preset ?? '',
    port,
    ownerToken: spec.ownerToken ?? ownerToken(),
    proc,
    createdAt: Date.now(),
    emptySince: Date.now(),
    status: { players: 0, bots: 0, humans: 0 },
  }
  rooms.set(id, room)
  dirty()

  // Chờ server lên rồi áp bots + password (rcon chỉ ăn khi server sẵn sàng).
  waitReady(room)
  return room
}

async function waitReady(room) {
  for (let waited = 0; waited < BOOT_WAIT_MS; waited += 1000) {
    await new Promise((resolve) => setTimeout(resolve, 1000))
    const info = await queryServerInfo('127.0.0.1', room.port, 800).catch(() => null)
    if (info?.online) break
  }
  try {
    if (room.password) {
      await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, `sv_password ${room.password}`)
    }
    await applyMode(room)
    log.info(`room ${room.id}: sẵn sàng (bots=${room.bots})`)
  } catch (error) {
    log.warn(`room ${room.id}: áp cấu hình qua rcon lỗi: ${error.message}`)
  }
}

function roomView(room, { includeToken = false } = {}) {
  return {
    id: room.id,
    name: room.name,
    map: room.map,
    maxplayers: room.maxplayers,
    hasPassword: Boolean(room.password),
    bots: room.bots,
    preset: room.preset,
    port: room.port,
    players: room.status.players,
    humans: room.status.humans,
    createdAt: room.createdAt,
    ...(includeToken ? { ownerToken: room.ownerToken } : {}),
  }
}

/** Tạo phòng; trả room kèm ownerToken (chỉ trả 1 lần lúc tạo).
 *  spec.proc = false → chỉ tạo record (dùng cho test tunnel, không spawn server). */
export async function createRoom(spec = {}) {
  const base = {
    name: String(spec.name ?? '').slice(0, 32) || undefined,
    map: String(spec.map ?? 'de_dust2'),
    maxplayers: Math.min(Math.max(Number(spec.maxplayers) || 16, 2), 16),
    password: String(spec.password ?? '').slice(0, 24),
    bots: Math.min(Math.max(Number(spec.bots) || 0, 0), 8),
    preset: String(spec.preset ?? ''),
  }

  if (spec.proc === false) {
    const id = newId()
    const port = spec.port ?? freePort()
    const room = {
      id,
      ...base,
      port,
      ownerToken: ownerToken(),
      proc: null,
      createdAt: Date.now(),
      emptySince: Date.now(),
      status: { players: 0, bots: 0, humans: 0 },
    }
    rooms.set(id, room)
    dirty()
    return roomView(room, { includeToken: true })
  }

  const room = await spawnRoom({ ...base, id: spec.id, port: spec.port, ownerToken: spec.ownerToken })
  dirty()
  log.info(`room ${room.id}: đã tạo (chủ phòng nhận token)`)
  return roomView(room, { includeToken: true })
}

export function listRooms() {
  return [...rooms.values()].map((room) => roomView(room))
}

export function getRoom(id) {
  return rooms.get(id) ?? null
}

/** Kiểm tra quyền: token khớp chủ phòng, hoặc là admin (ACCESS_CODE đã check trước đó). */
export function isOwner(room, token) {
  return Boolean(token) && token === room.ownerToken
}

/** PATCH: đổi map / password / bots / tên / số người. Owner-only ở tầng route. */
export async function patchRoom(id, patch) {
  const room = rooms.get(id)
  if (!room) throw new Error('phòng không tồn tại')

  if (patch.map && /^[\w.-]+$/.test(patch.map) && patch.map !== room.map) {
    await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, `changelevel ${patch.map}`)
    room.map = patch.map
    // changelevel exec lại server.cfg → cvars về mặc định; re-apply sau khi map load.
    setTimeout(() => {
      // changelevel exec lại server.cfg → cvar về mặc định; áp lại mode sau khi map load.
      void applyMode(room).catch((error) => log.warn(`room ${room.id}: re-apply mode: ${error.message}`))
    }, 4000)
  }
  if (patch.password !== undefined) {
    room.password = String(patch.password).slice(0, 24)
    await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, `sv_password ${room.password}`)
  }
  if (patch.bots !== undefined) {
    room.bots = Math.min(Math.max(Number(patch.bots) || 0, 0), 8)
    await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, `yb_quota ${room.bots}`)
  }
  if (patch.name) {
    room.name = String(patch.name).slice(0, 32)
    await rconCommand('127.0.0.1', room.port, RCON_PASSWORD, `hostname ${room.name} · web-cs`)
  }
  dirty()
  return roomView(room)
}

export async function deleteRoom(id) {
  const room = rooms.get(id)
  if (!room) return false
  room.proc?.kill()
  rooms.delete(id)
  dirty()
  log.info(`room ${id}: đã đóng`)
  return true
}

/** Poll A2S từng phòng: players/humans cho dashboard + theo dõi "trống". */
function startStatusLoop() {
  const tick = async () => {
    for (const room of rooms.values()) {
      const info = await queryServerInfo('127.0.0.1', room.port, 800).catch(() => null)
      if (!info?.online) continue
      room.status = {
        players: info.players ?? 0,
        bots: info.bots ?? 0,
        humans: (info.players ?? 0) - (info.bots ?? 0),
      }
      room.emptySince = room.status.humans > 0 ? null : (room.emptySince ?? Date.now())
    }
  }
  void tick()
  setInterval(() => void tick(), 5000)
}

function startAutoClose() {
  setInterval(() => {
    const now = Date.now()
    for (const room of rooms.values()) {
      if (!room.emptySince || now - room.emptySince < EMPTY_TTL_MS) continue
      const minutes = Math.round((now - room.emptySince) / 60000)
      log.info(`room ${room.id}: trống ${minutes} phút — tự đóng`)
      void deleteRoom(room.id)
    }
  }, 60_000)
}

export function startRoomManager() {
  void restore()
  startStatusLoop()
  startAutoClose()
}

/** Backend HTTP cho Docker (supervisor python) — web chỉ proxy qua đây. */
export const remoteMode = Boolean(process.env.GAME_MGR)
