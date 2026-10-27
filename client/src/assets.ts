import { unzipSync } from 'fflate'
import { log } from './log'

export interface DownloadProgress {
  received: number
  total: number
}

const GAME_CACHE = 'webcs-game-v1'

/**
 * Fetch the game bundle. The server serves it with an ETag, so a repeat visit
 * revalidates cheaply instead of moving 200 MB again.
 *
 * The HTTP cache alone is not enough: browsers refuse to store a single
 * response much larger than ~40 MB, so a 260 MB zip always misses and gets
 * re-downloaded. Cache Storage has no such cap — keep the bytes there and
 * compare the ETag with a cheap HEAD.
 */
export async function downloadGameZip(
  url: string,
  onProgress: (progress: DownloadProgress) => void,
): Promise<Uint8Array> {
  const cache = typeof caches === 'undefined' ? null : await caches.open(GAME_CACHE)
  const stored = (await cache?.match(url)) ?? null
  let etag = ''
  let reachable = false
  try {
    const head = await fetch(url, { method: 'HEAD', cache: 'no-store' })
    reachable = head.ok
    etag = head.headers.get('etag') ?? ''
  } catch {
    /* offline: dùng bản đã lưu */
  }
  if (stored && ((etag && stored.headers.get('x-etag') === etag) || !reachable)) {
    const bytes = new Uint8Array(await stored.arrayBuffer())
    onProgress({ received: bytes.byteLength, total: bytes.byteLength })
    return bytes
  }

  const response = await fetch(url, { cache: 'no-cache' })
  if (!response.ok) {
    throw new Error(`Không tải được ${url} (HTTP ${response.status})`)
  }

  const total = Number(response.headers.get('content-length') ?? 0)
  const keep = async (buffer: Uint8Array<ArrayBuffer>): Promise<Uint8Array> => {
    if (cache) {
      const tag = etag || response.headers.get('etag') || ''
      await cache
        .put(url, new Response(new Blob([buffer]), { headers: { 'x-etag': tag } }))
        .catch(() => {})
    }
    return buffer
  }

  if (!response.body) {
    const buffer = new Uint8Array(await response.arrayBuffer())
    onProgress({ received: buffer.byteLength, total: buffer.byteLength })
    return keep(buffer)
  }

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let received = 0

  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    chunks.push(value)
    received += value.byteLength
    onProgress({ received, total })
  }

  const buffer = new Uint8Array(received)
  let offset = 0
  for (const chunk of chunks) {
    buffer.set(chunk, offset)
    offset += chunk.byteLength
  }
  return keep(buffer)
}

export interface MountResult {
  files: number
  bytes: number
}

/**
 * Mount the bundle as a pk3 archive instead of unpacking it.
 *
 * FWGS's filesystem scans the base dir for `.pk3` and serves the entries
 * transparently, so handing the engine the zip verbatim (valve/ + cstrike/ at
 * the archive root) costs one buffer copy instead of ~460 MB of unpacked MEMFS
 * files — roughly halving client RAM and making "Đang khởi động" near-instant.
 * Set `?unpacked=1` in the URL to force the old unzip behaviour when debugging
 * archive-related boot failures.
 */
export function mountGameBundle(
  fs: {
    mkdirTree: (path: string) => void
    writeFile: (path: string, data: Uint8Array) => void
    chdir: (path: string) => void
  },
  zip: Uint8Array,
  baseDir = '/rodir',
  options: { unpacked?: boolean } = {},
): MountResult {
  const started = performance.now()

  if (options.unpacked) {
    const result = unpackToFs(fs, zip, baseDir)
    fs.chdir(baseDir)
    log.push(
      'assets',
      `Đã giải nén ${result.files} file (${(result.bytes / 1e6).toFixed(1)} MB) trong ${Math.round(performance.now() - started)} ms`,
    )
    return result
  }

  // pk3 layout: chỉ "đặt file" các gói pk3 + manifest thật, engine tự đọc qua
  // filesystem của FWGS (không giải nén 464 MB vào MEMFS nữa).
  fs.mkdirTree(baseDir)
  const entries = unzipSync(zip, {
    filter: (file) => /\.pk3$|liblist\.gam$|delta\.lst$/.test(file.name),
  })

  for (const [entryName, data] of Object.entries(entries)) {
    const path = entryName.replace(/\\/g, '/')
    if (!path || path.endsWith('/')) continue
    const target = `${baseDir}/${path}`
    fs.mkdirTree(target.slice(0, target.lastIndexOf('/')))
    fs.writeFile(target, data)
  }

  fs.chdir(baseDir)
  const pk3Bytes = Object.values(entries).reduce((sum, data) => sum + data.byteLength, 0)
  log.push(
    'assets',
    `Đã nạp ${Object.keys(entries).length} gói (${(pk3Bytes / 1e6).toFixed(1)} MB) trong ${Math.round(performance.now() - started)} ms`,
  )
  return { files: Object.keys(entries).length, bytes: pk3Bytes }
}

/** Legacy path: unpack every entry into MEMFS (kept for debugging). */
function unpackToFs(
  fs: {
    mkdirTree: (path: string) => void
    writeFile: (path: string, data: Uint8Array) => void
  },
  zip: Uint8Array,
  baseDir: string,
): MountResult {
  const entries = unzipSync(zip)
  const directories = new Set<string>()

  let files = 0
  let bytes = 0

  for (const [entryName, data] of Object.entries(entries)) {
    // Windows-built zips (Compress-Archive, many GUI tools) store `\` separators.
    const path = entryName.replace(/\\/g, '/')
    if (!path || path.endsWith('/')) continue
    const target = `${baseDir}/${path}`
    const dir = target.slice(0, target.lastIndexOf('/'))
    if (dir && !directories.has(dir)) {
      fs.mkdirTree(dir)
      directories.add(dir)
    }
    fs.writeFile(target, data)
    files += 1
    bytes += data.byteLength
  }
  return { files, bytes }
}
