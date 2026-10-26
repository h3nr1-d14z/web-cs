#!/usr/bin/env node
/**
 * End-to-end check of the room branch that runs in Docker (GAME_MGR mode),
 * without Docker and without any game binaries:
 *
 *   node scripts/smoke-remote.mjs
 *
 * Spawns the real `game/supervisor.py` next to a stub "game server" — one UDP
 * socket that answers A2S_INFO and records rcon commands — then the web server
 * pointed at the supervisor with GAME_MGR. Covers what `smoke-test.mjs` (local
 * mode) cannot reach: WS upgrade resolving the room port, isOwner through the
 * proxy, presets/restart reaching rcon, and the A2S players/max/bots parse.
 */
import { spawn } from 'node:child_process'
import dgram from 'node:dgram'
import net from 'node:net'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { once } from 'node:events'
import { setTimeout as sleep } from 'node:timers/promises'

const RCON_PASSWORD = 'smoke-rcon'
const ACCESS_CODE = 'smoke-code'

const freeTcpPort = async () => {
  const server = net.createServer()
  await once(server.listen(0, '127.0.0.1'), 'listening')
  const { port } = server.address()
  server.close()
  await once(server, 'close')
  return port
}

const freeUdpSocket = async () => {
  const socket = dgram.createSocket('udp4')
  await once(socket.bind(0, '127.0.0.1'), 'listening')
  return socket
}

/* ------------------------------------------------------------------ */
/* stub game server: A2S_INFO + rcon sink                              */
/* ------------------------------------------------------------------ */

const game = await freeUdpSocket()
const gamePort = game.address().port
const rconCommands = []
const state = { players: 2, bots: 1 }

const cstr = (text) => Buffer.from(`${text}\0`, 'latin1')

function a2sInfo() {
  return Buffer.concat([
    Buffer.from([0xff, 0xff, 0xff, 0xff, 0x49, 0x30]),
    cstr('smoke-remote'), // hostname
    cstr('de_dust2'), // map
    cstr('cstrike'), // folder
    cstr('Counter-Strike'), // game
    Buffer.from([0x5a, 0x00]), // appid, ignored by the parser
    Buffer.from([state.players, 16, state.bots]), // players, maxplayers, bots
  ])
}

game.on('message', (message, remote) => {
  const text = message.toString('latin1')
  if (text.includes('Source Engine Query')) {
    game.send(a2sInfo(), remote.port, remote.address)
    return
  }
  if (text.startsWith('\xff\xff\xff\xffrcon ')) {
    // "rcon <password> <command>\n"
    const rest = text.slice(4 + 'rcon '.length)
    rconCommands.push(rest.slice(rest.indexOf(' ') + 1).trim())
    return
  }
  // Bridge tunnel payload: echo it back so the WS path is observable.
  game.send(message, remote.port, remote.address)
})

/* ------------------------------------------------------------------ */
/* processes                                                           */
/* ------------------------------------------------------------------ */

const tmp = await mkdtemp(join(tmpdir(), 'webcs-smoke-'))
const presetsFile = join(tmp, 'presets.json')
await writeFile(presetsFile, JSON.stringify({ smoke: { label: 'smoke', commands: ['sv_restart 1'] } }))

const supervisorPort = await freeTcpPort()
const webPort = await freeTcpPort()

const supervisor = spawn('python3', ['game/supervisor.py'], {
  env: {
    ...process.env,
    XASH: '/bin/true',
    GAME_DIR: tmp,
    ROOMS_FILE: join(tmp, 'rooms.json'),
    PRESETS_FILE: presetsFile,
    LISTEN_PORT: String(supervisorPort),
    UDP_BASE: String(gamePort),
    RCON_PASSWORD,
    EMPTY_TTL: '60',
  },
  stdio: ['ignore', 'inherit', 'inherit'],
})

const web = spawn(process.execPath, ['server/src/index.js'], {
  env: {
    ...process.env,
    PORT: String(webPort),
    GAME_HOST: '127.0.0.1',
    GAME_MGR: `http://127.0.0.1:${supervisorPort}`,
    PUBLIC_DIR: process.env.SMOKE_PUBLIC_DIR ?? 'client/dist',
    GAME_ZIP: join(tmp, 'missing.zip'),
    ASSETS_DIR: tmp,
    RCON_PASSWORD,
    ACCESS_CODE,
    LOG_LEVEL: process.env.LOG_LEVEL ?? 'warn',
  },
  stdio: 'inherit',
})

let failed = false
const cleanup = async () => {
  supervisor.kill()
  web.kill()
  try {
    game.close()
  } catch {
    /* already closed */
  }
  await rm(tmp, { recursive: true, force: true })
}
process.on('exit', () => {
  supervisor.kill()
  web.kill()
})

const check = async (label, fn) => {
  try {
    await fn()
  } catch (error) {
    failed = true
    console.error(`✗ ${label}: ${error.message}`)
  }
}

const waitHttp = async (port, path = '/healthz') => {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}${path}`)
      if (response.ok) return
    } catch {
      /* not up yet */
    }
    await sleep(150)
  }
  throw new Error(`:${port}${path} không lên`)
}

const api = async (path, { method = 'GET', body, token } = {}) => {
  const response = await fetch(`http://127.0.0.1:${webPort}${path}`, {
    method,
    headers: {
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      'x-access-code': ACCESS_CODE,
      ...(token ? { 'x-room-token': token } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  let json = {}
  try {
    json = JSON.parse(text)
  } catch {
    /* plain text body */
  }
  return { status: response.status, json, text }
}

try {
  await waitHttp(supervisorPort, '/rooms')
  await waitHttp(webPort)

  let roomId = ''
  let ownerToken = ''

  await check('tạo phòng qua proxy', async () => {
    const created = await api('/api/rooms', {
      method: 'POST',
      body: { name: 'smoke-remote', map: 'de_dust2', maxplayers: 16, bots: 0 },
    })
    if (created.status !== 200) throw new Error(`HTTP ${created.status} ${created.text}`)
    if (!created.json.id || !created.json.ownerToken) throw new Error(`thiếu id/ownerToken: ${created.text}`)
    roomId = created.json.id
    ownerToken = created.json.ownerToken
    console.log(`✓ room ${roomId} (ownerToken nhận 1 lần)`)
  })

  await check('isOwner + A2S players/bots qua proxy', async () => {
    let view = null
    for (let attempt = 0; attempt < 40; attempt += 1) {
      view = await api(`/api/rooms/${roomId}`, { token: ownerToken })
      if (view.json.players === 2) break
      await sleep(500)
    }
    if (view?.status !== 200) throw new Error(`HTTP ${view?.status} ${view?.text}`)
    if (view.json.isOwner !== true) throw new Error(`isOwner=${view.json.isOwner} (chủ phòng không nhận ra)`)
    // Stub: 2 players, trong đó 1 bot ⇒ 1 người thật. Parse sai offset sẽ ra -14.
    if (view.json.players !== 2) throw new Error(`players=${view.json.players}, chờ 2`)
    if (view.json.humans !== 1) throw new Error(`humans=${view.json.humans}, chờ 1 (2 players - 1 bot)`)
    console.log('✓ isOwner=true, humans=1 (A2S bots đọc đúng byte)')
  })

  await check('mã admin cũng là chủ phòng, ẩn danh thì không', async () => {
    const viaAdmin = await api(`/api/rooms/${roomId}`) // mã admin, không token phòng
    if (viaAdmin.json.isOwner !== true) throw new Error(`isOwner=${viaAdmin.json.isOwner} khi có mã admin`)
    const anon = await fetch(`http://127.0.0.1:${webPort}/api/rooms/${roomId}`)
    const anonBody = await anon.json()
    if (anonBody.isOwner === true) throw new Error('không token, không mã mà vẫn isOwner')
    console.log('✓ admin code → isOwner; ẩn danh → không')
  })

  await check('preset chủ phòng → rcon', async () => {
    const before = rconCommands.length
    const applied = await api(`/api/rooms/${roomId}/preset`, {
      method: 'POST',
      body: { name: 'smoke' },
      token: ownerToken,
    })
    if (applied.status !== 200) throw new Error(`HTTP ${applied.status} ${applied.text}`)
    if (applied.json.applied !== 1) throw new Error(`applied=${applied.json.applied}, chờ 1`)
    const sent = rconCommands.slice(before)
    if (!sent.includes('sv_restart 1')) throw new Error(`rcon không nhận preset: ${JSON.stringify(sent)}`)
    console.log('✓ preset đi tới rcon')
  })

  await check('preset không có token bị chặn', async () => {
    const denied = await api(`/api/rooms/${roomId}/preset`, { method: 'POST', body: { name: 'smoke' } })
    if (denied.status !== 401) throw new Error(`HTTP ${denied.status}, chờ 401`)
    console.log('✓ preset không token → 401')
  })

  await check('restart → rcon', async () => {
    const before = rconCommands.length
    const restarted = await api(`/api/rooms/${roomId}`, {
      method: 'PATCH',
      body: { restart: true },
      token: ownerToken,
    })
    if (restarted.status !== 200) throw new Error(`HTTP ${restarted.status} ${restarted.text}`)
    const sent = rconCommands.slice(before)
    if (!sent.includes('sv_restart 1')) throw new Error(`restart không tới rcon: ${JSON.stringify(sent)}`)
    console.log('✓ restart đi tới rcon')
  })

  await check('tunnel WS ↔ UDP (port lấy từ supervisor)', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${webPort}/ws?room=${roomId}&code=${ACCESS_CODE}`)
    ws.binaryType = 'arraybuffer'
    await new Promise((resolve, reject) => {
      ws.onopen = resolve
      ws.onerror = () => reject(new Error('không mở được WebSocket'))
    })

    const payload = new TextEncoder().encode('docker-branch-packet')
    ws.send(payload)
    const reply = await Promise.race([
      new Promise((resolve) => {
        ws.onmessage = (event) => resolve(new Uint8Array(event.data))
      }),
      sleep(2000).then(() => null),
    ])
    ws.close()
    if (!reply) throw new Error('không nhận được phản hồi qua tunnel')
    const text = new TextDecoder().decode(reply)
    if (text !== 'docker-branch-packet') throw new Error(`payload sai: ${text}`)
    console.log('✓ tunnel WS ↔ UDP trả lại đúng payload')
  })

  await check('đóng phòng', async () => {
    const removed = await api(`/api/rooms/${roomId}`, { method: 'DELETE', token: ownerToken })
    if (removed.status !== 200 || removed.json.ok !== true) {
      throw new Error(`HTTP ${removed.status} ${removed.text}`)
    }
    const gone = await api(`/api/rooms/${roomId}`, { token: ownerToken })
    if (gone.status !== 404) throw new Error(`phòng vẫn còn: HTTP ${gone.status}`)
    console.log('✓ phòng đã đóng')
  })
} finally {
  await cleanup()
}

if (failed) {
  console.error('\nCó kiểm tra thất bại.')
  process.exit(1)
}

console.log('\nTất cả kiểm tra nhánh Docker đều đạt.')
process.exit(0)
