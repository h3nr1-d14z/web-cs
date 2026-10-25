import type { Packet } from '../vendor/xash3d-fwgs/dist/index.js'
import { log } from './log'

export type TransportState = 'connecting' | 'open' | 'closed'

const MAX_BACKLOG_PACKETS = 64
const MAX_BACKLOG_BYTES = 256 * 1024

/**
 * Browser side of the UDP tunnel.
 *
 * `Net` (from xash3d-fwgs) calls `sendto()` for every datagram the engine wants
 * to emit, and reads replies from `incoming`. We keep one WebSocket per player;
 * the server maps it 1:1 onto a UDP socket talking to the game server, so each
 * player keeps a distinct source port and GoldSrc's per-client connection
 * bookkeeping stays intact.
 */
export class WsTransport {
  state: TransportState = 'connecting'
  onState?: (state: TransportState) => void
  onPacket?: (bytes: Uint8Array) => void

  private ws?: WebSocket
  private backlog: Int8Array[] = []
  private backlogBytes = 0
  private closedByUser = false

  constructor(private readonly url: string) {}

  connect(): void {
    if (this.ws) return
    this.closedByUser = false
    this.setState('connecting')

    const ws = new WebSocket(this.url)
    ws.binaryType = 'arraybuffer'
    this.ws = ws

    ws.onopen = () => {
      log.push('net', 'WebSocket đã mở')
      this.setState('open')
      const backlog = this.backlog
      this.backlog = []
      this.backlogBytes = 0
      for (const packet of backlog) ws.send(packet)
    }

    ws.onmessage = (event: MessageEvent<ArrayBuffer>) => {
      this.onPacket?.(new Uint8Array(event.data))
    }

    ws.onerror = () => {
      // The close handler carries the actionable information; errors here are
      // mostly "server not reachable" noise.
      log.push('net', 'WebSocket gặp lỗi')
    }

    ws.onclose = (event) => {
      this.ws = undefined
      this.setState('closed')
      log.push('net', `WebSocket đóng (code ${event.code}${event.reason ? `: ${event.reason}` : ''})`)
    }
  }

  /** Drop the socket and dial again; the engine keeps using this same object. */
  reconnect(): void {
    this.ws?.close()
    this.ws = undefined
    this.connect()
  }

  /** Called by xash3d-fwgs' `Net` for every outbound datagram. */
  sendto = (packet: Packet): void => {
    const view = packet.data
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(view)
      return
    }
    this.enqueue(view)
  }

  close(): void {
    this.closedByUser = true
    this.ws?.close()
    this.ws = undefined
  }

  get userClosed(): boolean {
    return this.closedByUser
  }

  private enqueue(view: Int8Array): void {
    if (this.backlog.length >= MAX_BACKLOG_PACKETS || this.backlogBytes >= MAX_BACKLOG_BYTES) {
      this.backlog.shift()
    }
    // `view` points into the wasm heap and will be overwritten; copy it.
    const copy = view.slice()
    this.backlog.push(copy)
    this.backlogBytes += copy.byteLength
  }

  private setState(state: TransportState): void {
    if (this.state === state) return
    this.state = state
    this.onState?.(state)
  }
}
