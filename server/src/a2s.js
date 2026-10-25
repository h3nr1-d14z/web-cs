import dgram from 'node:dgram'

const A2S_INFO = Buffer.concat([
  Buffer.from([0xff, 0xff, 0xff, 0xff, 0x54]),
  Buffer.from('Source Engine Query\0', 'latin1'),
])

function readCString(buffer, offset) {
  const end = buffer.indexOf(0, offset)
  if (end === -1) return { value: '', next: buffer.length }
  return { value: buffer.toString('utf8', offset, end), next: end + 1 }
}

/**
 * Minimal A2S_INFO client — enough for the lobby "who is online" panel.
 * Xash3D answers the same query Valve servers do, including the modern
 * challenge round-trip.
 */
export function queryServerInfo(host, port, timeoutMs = 1500) {
  return new Promise((resolve) => {
    const socket = dgram.createSocket('udp4')
    let settled = false
    let attempts = 0

    const finish = (value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try {
        socket.close()
      } catch {
        /* already closed */
      }
      resolve(value)
    }

    const timer = setTimeout(() => finish({ online: false, reason: 'timeout' }), timeoutMs)

    socket.on('error', () => finish({ online: false, reason: 'socket-error' }))

    socket.on('message', (message) => {
      if (message.length < 5) return
      const kind = message[4]

      if (kind === 0x41 && attempts < 2) {
        // Challenge: repeat the query with the four bytes we were handed.
        attempts += 1
        const challenge = message.subarray(5, 9)
        socket.send(Buffer.concat([A2S_INFO, challenge]), port, host)
        return
      }

      if (kind !== 0x49) {
        finish({ online: false, reason: `unexpected 0x${kind.toString(16)}` })
        return
      }

      let offset = 5
      offset += 1 // protocol
      const name = readCString(message, offset)
      offset = name.next
      const map = readCString(message, offset)
      offset = map.next
      const folder = readCString(message, offset)
      offset = folder.next
      const game = readCString(message, offset)
      offset = game.next
      offset += 2 // app id (short)
      const players = message[offset] ?? 0
      const maxPlayers = message[offset + 1] ?? 0
      const bots = message[offset + 2] ?? 0

      finish({
        online: true,
        name: name.value,
        map: map.value,
        folder: folder.value,
        game: game.value,
        players,
        maxPlayers,
        bots,
      })
    })

    socket.send(A2S_INFO, port, host, (error) => {
      if (error) finish({ online: false, reason: error.message })
    })
  })
}
