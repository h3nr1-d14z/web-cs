import { createHash } from 'node:crypto'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { unzipSync, zipSync } from 'fflate'
import { log } from './logger.js'

/**
 * Map custom cho client: gói `custom.pk3` đặt trong gamedir cstrike/ (FWGS
 * scan pk3 trong gamedir), client tải nó RIÊNG khỏi game.zip — thêm map mới
 * chỉ cần thay custom.pk3 (vài trăm KB–vài chục MB), không đụng bundle 255 MB.
 *
 *   /data/cstrike/custom.pk3   → server đọc trực tiếp (game thấy bsp ngay)
 *   /data/cstrike/maps/*.bsp   → để server `changelevel` + A2S list
 *   GET /api/custom            → { version } (hash) để client biết khi nào tải lại
 *   GET /custom.pk3            → client tải (ETag, 304 khi không đổi)
 */

const RAR_MAGIC = Buffer.from('Rar!\x1a\x07')

export function isRar(buffer) {
  return buffer.subarray(0, 7).equals(RAR_MAGIC)
}

export function isZip(buffer) {
  return buffer[0] === 0x50 && buffer[1] === 0x4b
}

export function isGoldSrcBsp(buffer) {
  // GoldSrc bsp: 4 byte đầu là int32 version == 30 (little-endian: 1e 00 00 00).
  if (buffer.byteLength < 8) return false
  return buffer[0] === 0x1e && buffer[1] === 0 && buffer[2] === 0 && buffer[3] === 0
}

function run(tool, args) {
  return new Promise((resolve, reject) => {
    execFile(tool, args, { timeout: 60_000, windowsHide: true }, (error, _stdout, stderr) => {
      if (error) {
        const message = (stderr || error.message || '').slice(0, 300)
        reject(new Error(`${tool} thất bại: ${message}`))
        return
      }
      resolve()
    })
  })
}

/**
 * Giải nén archive (zip bằng fflate, rar bằng 7z/unrar nếu máy có).
 * Trả về map tên-file(gamedir-relative) → bytes, giữ TOÀN BỘ tài nguyên
 * (bsp, mdl, wad, res, sound, sprites, overviews…) để map custom chơi đủ.
 */
export async function extractArchive(buffer, archiveName) {
  if (isZip(buffer)) {
    const entries = unzipSync(buffer)
    const picked = {}
    for (const [name, data] of Object.entries(entries)) {
      if (name.endsWith('/') || name.endsWith('\\')) continue
      picked[name.replace(/\\/g, '/')] = data
    }
    return picked
  }

  if (isRar(buffer)) {
    const tools = [
      process.env.RAR_TOOL,
      '7z',
      '7zz',
      'unrar',
      'C:\\Program Files\\7-Zip\\7z.exe',
      'C:\\Program Files (x86)\\7-Zip\\7z.exe',
    ].filter(Boolean)

    const tmpDir = path.join(path.dirname(archiveName), `extract-${Date.now()}`)
    await mkdir(tmpDir, { recursive: true })
    const archivePath = tmpDir + '.rar'
    await writeFile(archivePath, buffer)

    let lastError = 'không tìm thấy 7z/unrar trên máy'
    for (const tool of tools) {
      try {
        const args = tool.endsWith('unrar')
          ? ['x', '-o+', archivePath, tmpDir + path.sep]
          : ['x', `-o${tmpDir}`, archivePath, '-y']
        await run(tool, args)
        const picked = {}
        for (const full of await readdirRecursive(tmpDir)) {
          const rel = path.relative(tmpDir, full).split(path.sep).join('/')
          picked[rel] = await readFile(full)
        }
        return picked
      } catch (error) {
        lastError = error.message
      }
    }
    throw new Error(
      `File là .rar — cần 7-Zip hoặc UnRAR để giải nén (lỗi cuối: ${lastError}). ` +
        'Cài 7-Zip rồi đặt RAR_TOOL=đường_dẫn_7z nếu cần.',
    )
  }

  throw new Error(`Định dạng không hỗ trợ (chỉ .bsp, .zip, .rar)`)
}

async function readdirRecursive(dir, base = dir, found = []) {
  const { readdir } = await import('node:fs/promises')
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) await readdirRecursive(full, base, found)
    else found.push(full)
  }
  return found
}

/** Gói các file thành custom.pk3 (path giữ nguyên relative tới gamedir). */
export function packCustomPk3(files) {
  const packed = zipSync(files, { level: 1 })
  const version = createHash('sha256').update(packed).digest('hex').slice(0, 12)
  return { packed, version }
}

export async function loadCustomFiles(pk3Path) {
  try {
    const data = await readFile(pk3Path)
    return unzipSync(data)
  } catch {
    return {}
  }
}

export async function saveCustomPk3(pk3Path, packed) {
  await mkdir(path.dirname(pk3Path), { recursive: true })
  await writeFile(pk3Path, packed)
}
