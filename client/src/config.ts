/**
 * Static build/runtime configuration.
 *
 * The browser engine never speaks UDP: it hands every outgoing datagram to
 * `WsTransport`, and the Node server forwards it to the real GoldSrc server.
 * That is why the address the engine connects to is a placeholder.
 */
export const GAME_ADDR = '127.0.0.1:27015'
export const GAME_PORT = 27015

export const WEBASSETS_URL = '/game.zip'

/**
 * One WebSocket per player. The optional access code is forwarded to the
 * server, which refuses the upgrade when it does not match `ACCESS_CODE`.
 */
/** Id phòng hiện tại (?room=...) — bridge và mọi API phòng đều dựa vào nó. */
export function currentRoomId(): string {
  return new URLSearchParams(location.search).get('room') ?? ''
}

export function buildWsUrl(accessCode?: string): string {
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
  const url = new URL(`${scheme}://${location.host}/ws`)
  const room = currentRoomId()
  if (room) url.searchParams.set('room', room)
  if (accessCode) url.searchParams.set('code', accessCode)
  return url.toString()
}
