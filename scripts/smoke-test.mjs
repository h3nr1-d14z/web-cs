#!/usr/bin/env node
/**
 * End-to-end plumbing check that does not need the real game server.
 *
 * Starts a UDP echo server, runs the web server against it, then verifies:
 *   1. /healthz and the static client are served
 *   2. /game.zip answers (503 when assets are missing is a valid answer)
 *   3. a binary WebSocket frame reaches UDP and the reply comes back on the
 *      same socket — i.e. the tunnel works in both directions
 *
 * Uses Node's built-in WebSocket client, so it needs no dependencies.
 *
 *   node scripts/smoke-test.mjs
 */
import { spawn } from 'node:child_process'
import dgram from 'node:dgram'
import { once } from 'node:events'
import { setTimeout as sleep } from 'node:timers/promises'

const PORT = Number(process.env.SMOKE_PORT ?? 18080)
const UDP_PORT = Number(process.env.SMOKE_UDP_PORT ?? 37015)

const echo = dgram.createSocket('udp4')
echo.on('message', (message, remote) => echo.send(message, remote.port, remote.address))
await once(echo.bind(UDP_PORT), 'listening')
console.log(`✓ UDP echo trên :${UDP_PORT}`)

const server = spawn(process.execPath, ['server/src/index.js'], {
  env: {
    ...process.env,
    PORT: String(PORT),
    GAME_HOST: '127.0.0.1',
    GAME_PORT: String(UDP_PORT),
    PUBLIC_DIR: process.env.SMOKE_PUBLIC_DIR ?? 'client/dist',
    GAME_ZIP: process.env.SMOKE_GAME_ZIP ?? '.cache/does-not-exist.zip',
    LOG_LEVEL: process.env.LOG_LEVEL ?? 'warn',
  },
  stdio: 'inherit',
})

let failed = false
const cleanup = () => {
  server.kill()
  try {
    echo.close()
  } catch {
    /* already closed */
  }
}
process.on('exit', cleanup)

for (let attempt = 0; attempt < 60; attempt += 1) {
  try {
    const response = await fetch(`http://127.0.0.1:${PORT}/healthz`)
    if (response.ok) break
  } catch {
    /* not up yet */
  }
  await sleep(150)
}

const check = async (label, fn) => {
  try {
    await fn()
  } catch (error) {
    failed = true
    console.error(`✗ ${label}: ${error.message}`)
  }
}

await check('/healthz', async () => {
  const response = await fetch(`http://127.0.0.1:${PORT}/healthz`)
  console.log(`✓ /healthz ${response.status} ${await response.text()}`)
})

await check('/', async () => {
  const response = await fetch(`http://127.0.0.1:${PORT}/`)
  const html = await response.text()
  if (!html.includes('LAN Party')) throw new Error('index.html không phải dashboard')
  console.log(`✓ / ${response.status} (${html.length} bytes)`)
})

await check('/api/status', async () => {
  const response = await fetch(`http://127.0.0.1:${PORT}/api/status`)
  console.log(`✓ /api/status ${response.status} ${await response.text()}`)
})

await check('/game.zip', async () => {
  const response = await fetch(`http://127.0.0.1:${PORT}/game.zip`)
  console.log(`✓ /game.zip ${response.status} (503 = chưa có assets)`)
})

// Tunnel cần một phòng thật (bridge route theo ?room=). Tạo room record
// KHÔNG spawn server, trỏ port tới echo UDP nội bộ của chính test này.
await check('tunnel WS ↔ UDP', async () => {
  const dgram = await import('node:dgram')
  const echo = dgram.createSocket('udp4')
  echo.on('message', (message, remote) => echo.send(message, remote.port, remote.address))
  await new Promise((resolve) => echo.bind(0, resolve))
  const udpPort = echo.address().port

  const created = await (
    await fetch(`http://127.0.0.1:${PORT}/api/rooms`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'smoke', map: 'de_dust2', port: udpPort, proc: false }),
    })
  ).json()

  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?room=${created.id}`)
  ws.binaryType = 'arraybuffer'
  await new Promise((resolve, reject) => {
    ws.onopen = resolve
    ws.onerror = () => reject(new Error('không mở được WebSocket'))
  })

  const payload = new TextEncoder().encode('gold-src-packet')
  ws.send(payload)

  const reply = await Promise.race([
    new Promise((resolve) => {
      ws.onmessage = (event) => resolve(new Uint8Array(event.data))
    }),
    sleep(2000).then(() => null),
  ])

  ws.close()
  await fetch(`http://127.0.0.1:${PORT}/api/rooms/${created.id}`, { method: 'DELETE' })
  try {
    echo.close()
  } catch {
    /* already closed */
  }

  if (!reply) throw new Error('không nhận được phản hồi qua tunnel')
  const text = new TextDecoder().decode(reply)
  if (text !== 'gold-src-packet') throw new Error(`payload sai: ${text}`)
  console.log('✓ tunnel WS ↔ UDP trả lại đúng payload')
})

if (failed) {
  console.error('\nCó kiểm tra thất bại.')
  process.exit(1)
}

console.log('\nTất cả kiểm tra plumbing đều đạt.')
process.exit(0)
