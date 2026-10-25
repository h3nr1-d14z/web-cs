import dgram from 'node:dgram'

const HEADER = Buffer.from([0xff, 0xff, 0xff, 0xff])

/**
 * RCON của Xash3D FWGS: KHÔNG có bước challenge kiểu GoldSrc.
 *
 *   gói:  `rcon <password> <command>`   →   các gói "l <text>" làm reply
 *
 * Yêu cầu server có: `rcon_enable 1` + `rcon_password`.
 * Mỗi lệnh tự dựng một socket — số lệnh admin rất ít nên không đáng tối ưu.
 *
 * ⚠️ Dùng Buffer.concat cho header: `Buffer + string` sẽ encode 0xFFFFFFFF
 * sang UTF-8 ("ÿÿÿÿ") và server bỏ qua gói không rõ dấu connectionless.
 */
export function rconCommand(host, port, password, command, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket('udp4')
    const chunks = []
    let gotReply = false
    let settled = false

    const finish = (error, text) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try {
        socket.close()
      } catch {
        /* already closed */
      }
      if (error) reject(new Error(error))
      else resolve(text ?? '')
    }

    const timer = setTimeout(() => {
      if (!gotReply) finish('rcon timeout — kiểm tra rcon_enable/rcon_password trên server')
      else finish(null, chunks.join('').trim())
    }, timeoutMs)

    socket.on('error', (error) => finish(error.message))

    socket.on('message', (message) => {
      gotReply = true
      const text = message.toString('latin1').replace(/^\xff{4}/, '')
      chunks.push(text.replace(/^l /, ''))
      timer.refresh() // gom đủ chuỗi dài (status, listmaps…)
    })

    const request = Buffer.concat([
      HEADER,
      Buffer.from(`rcon ${password} ${command}\n`, 'latin1'),
    ])
    socket.send(request, port, host, (error) => {
      if (error) finish(error.message)
    })
  })
}
