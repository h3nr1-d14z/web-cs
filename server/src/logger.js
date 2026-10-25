import { appendFileSync } from 'node:fs'

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 }

const configured = (process.env.LOG_LEVEL ?? 'info').toLowerCase()
const threshold = LEVELS[configured] ?? LEVELS.info

// Ghi file đồng bộ (append) để chẩn đoán không bị mất khi process bị kill cứng.
const DEBUG_LOG = process.env.WEB_DEBUG_LOG
if (DEBUG_LOG) {
  try {
    appendFileSync(DEBUG_LOG, `--- start ${new Date().toISOString()} ---\n`)
  } catch {
    /* ignore */
  }
}

function emit(level, message) {
  if (LEVELS[level] > threshold) return
  const stamp = new Date().toISOString().slice(11, 19)
  const stream = level === 'error' || level === 'warn' ? process.stderr : process.stdout
  stream.write(`${stamp} ${level.toUpperCase().padEnd(5)} ${message}\n`)
  if (DEBUG_LOG) {
    try {
      appendFileSync(DEBUG_LOG, `${stamp} ${level.toUpperCase().padEnd(5)} ${message}\n`)
    } catch {
      /* ignore */
    }
  }
}

export const log = {
  error: (message) => emit('error', message),
  warn: (message) => emit('warn', message),
  info: (message) => emit('info', message),
  debug: (message) => emit('debug', message),
}

