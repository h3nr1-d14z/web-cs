import dgram from 'node:dgram'
import { log } from './logger.js'

const IDLE_TIMEOUT_MS = 60_000
const PING_INTERVAL_MS = 20_000

/**
 * Bridges one browser WebSocket to one UDP socket aimed at the game server.
 *
 * A dedicated UDP socket per player matters: GoldSrc identifies clients by
 * `ip:port`, so if every browser shared one socket they would all look like the
 * same client and kick each other off. `udp.connect()` also filters out stray
 * traffic from anything that is not the game server.
 */
export function attachBridge(ws, { host, port, label }) {
  const udp = dgram.createSocket('udp4')
  let closed = false

  const close = (reason) => {
    if (closed) return
    closed = true
    log.debug(`bridge ${label}: đóng (${reason})`)
    try {
      udp.close()
    } catch {
      /* already closed */
    }
    if (ws.readyState === ws.OPEN) ws.close(1000, reason.slice(0, 100))
  }

  udp.on('error', (error) => {
    log.warn(`bridge ${label}: lỗi UDP: ${error.message}`)
    close('udp-error')
  })

  // udp.send() chưa gọi được trước khi connect xong, mà GoldSrc bắn signon rất
  // sớm — nên giữ hai hàng đợi riêng và flush đúng chiều khi connect.
  let linked = false
  const pendingFromClient = []
  const earlyFromServer = []
  udp.on('connect', () => {
    linked = true
    log.info(`bridge ${label}: UDP -> ${host}:${port} (source ${udp.address().port})`)
    for (const message of earlyFromServer.splice(0)) {
      if (ws.readyState === ws.OPEN) ws.send(message, { binary: true })
    }
    for (const packet of pendingFromClient.splice(0)) {
      try {
        udp.send(packet)
      } catch (error) {
        log.warn(`bridge ${label}: không gửi được gói: ${error.message}`)
      }
    }
  })

  udp.connect(port, host)

  udp.on('message', (message) => {
    if (!linked) {
      if (earlyFromServer.length > 128) earlyFromServer.shift()
      earlyFromServer.push(message)
      return
    }
    if (ws.readyState !== ws.OPEN) return
    ws.send(message, { binary: true })
  })

  ws.on('message', (data) => {
    if (typeof data === 'string') return
    if (closed) return
    if (!linked) {
      pendingFromClient.push(Buffer.from(data))
      if (pendingFromClient.length > 128) pendingFromClient.shift()
      return
    }
    try {
      udp.send(data)
    } catch (error) {
      log.warn(`bridge ${label}: không gửi được gói: ${error.message}`)
    }
  })

  ws.on('close', () => close('client-closed'))
  ws.on('error', (error) => {
    log.warn(`bridge ${label}: lỗi WebSocket: ${error.message}`)
    close('ws-error')
  })

  // Liveness: a laptop that sleeps leaves the socket half-open and the game
  // server holding a slot until sv_timeout. Ping so we can reap it sooner.
  let alive = true
  ws.on('pong', () => {
    alive = true
  })
  const timer = setInterval(() => {
    if (!alive || ws.readyState !== ws.OPEN) {
      close('idle')
      return
    }
    alive = false
    try {
      ws.ping()
    } catch {
      close('ping-failed')
    }
  }, PING_INTERVAL_MS)

  // Drop players who never actually talk to the server (background tabs).
  let lastTraffic = Date.now()
  ws.on('message', () => {
    lastTraffic = Date.now()
  })
  udp.on('message', () => {
    lastTraffic = Date.now()
  })
  const idleTimer = setInterval(() => {
    if (Date.now() - lastTraffic > IDLE_TIMEOUT_MS) close('idle')
  }, 15_000)

  ws.on('close', () => {
    clearInterval(timer)
    clearInterval(idleTimer)
  })
}
