#!/usr/bin/env node
/**
 * Build the browser bundle (`game.zip`) from a Half-Life Dedicated Server
 * install, without Docker. Same trimming rules as `docker/assets.sh`.
 *
 * Bundle layout (pk3-based — the engine scans *.pk3 inside each gamedir):
 *
 *   valve/valve.pk3      mọi file của valve/, path RELATIVE tới valve/
 *   cstrike/cstrike.pk3  mọi file của cstrike/, path RELATIVE tới cstrike/
 *   cstrike/liblist.gam  manifest thật (engine cần file thật để nhận gamedir)
 *   cstrike/delta.lst    bảng delta (file thật, nhỏ)
 *
 *   node scripts/make-client-zip.mjs <thư-mục-HLDS> <đầu-ra.zip>
 */
import { createWriteStream } from 'node:fs'
import { readdir, readFile, stat } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'
import { Zip, ZipDeflate, ZipPassThrough } from '../client/node_modules/fflate/esm/browser.js'

const [, , sourceDir, outFile] = process.argv

if (!sourceDir || !outFile) {
  console.error('Dùng: node scripts/make-client-zip.mjs <thư-mục-HLDS> <đầu-ra.zip>')
  process.exit(1)
}

// Directories that never reach a CS 1.6 client, or that belong to Half-Life
// single-player content CS never loads. Keep valve/halflife.wad — CS maps use it.
const SKIP_DIRS = [
  'valve/maps',
  'valve/media',
  'valve/overviews',
  'valve/dlls',
  'cstrike/dlls',
]

const SKIP_EXT = new Set(['.so', '.dll', '.dylib', '.exe', '.dem', '.pdb'])
const SKIP_FILES = new Set(['cstrike/server.cfg', 'cstrike/motd.txt'])

// liblist.gam identifies the game directory to the engine; without it Xash
// reports "Couldn't find game directory 'cstrike'". Always ship ours so both
// client and server agree on the game definition.
const OVERRIDES = {
  'cstrike/liblist.gam': join(process.cwd(), 'config', 'liblist.gam'),
}

const skipDir = (relPath) => SKIP_DIRS.some((dir) => relPath === dir || relPath.startsWith(`${dir}/`))

async function walk(dir, root, found = []) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    // Path cho skip-list: relative tới HLDS root (vd 'valve/maps/de_...').
    const relForSkip = relative(sourceDir, full).split(sep).join('/')
    // Path trong pk3: relative tới gamedir (vd 'gfx.wad', 'maps/de_...').
    const rel = relative(root, full).split(sep).join('/')

    if (entry.isDirectory()) {
      if (skipDir(relForSkip) || entry.name === 'logs') continue
      await walk(full, root, found)
      continue
    }

    if (SKIP_FILES.has(relForSkip)) continue
    if (SKIP_EXT.has(rel.slice(rel.lastIndexOf('.')).toLowerCase())) continue
    found.push({ full, rel })
  }
  return found
}

const out = createWriteStream(outFile)

// Outer container is STORE-only: the two inner pk3 files are already deflated.
const outer = new Zip((error, chunk, final) => {
  if (error) throw error
  out.write(Buffer.from(chunk))
  if (final) out.end()
})

const started = Date.now()
let count = 0
let bytes = 0

/** Thêm 1 gamedir vào outer zip dưới dạng <gamedir>/<tên>.pk3 (path relative). */
function packGamedir(top) {
  return new Promise((resolve, reject) => {
    const root = join(sourceDir, top)
    const passthrough = new ZipPassThrough(`${top}/${top}.pk3`)
    outer.add(passthrough)
    const inner = new Zip((error2, chunk, final2) => {
      if (error2) throw error2
      passthrough.push(chunk, final2)
    })

    stat(root)
      .then((info) => {
        if (!info.isDirectory()) throw new Error(`${root} không phải thư mục`)
        return walk(root, root)
      })
      .then(async (files) => {
        // Path trong pk3 phải RELATIVE tới gamedir (vd 'gfx.wad', 'sound/...'),
        // không có prefix 'valve/'/'cstrike/'.
        for (const file of files) {
          const data = new Uint8Array(await readFile(file.full))
          const entry = new ZipDeflate(file.rel, { level: 1 })
          inner.add(entry)
          entry.push(data, true)
          count += 1
          bytes += data.byteLength
          if (count % 1000 === 0) process.stdout.write(`\r  ${count} file, ${(bytes / 1e6).toFixed(0)} MB…`)
        }
        inner.end()
        resolve()
      })
      .catch(reject)
  })
}

async function addRealFile(entryName, sourcePath) {
  const data = new Uint8Array(await readFile(sourcePath))
  const entry = new ZipDeflate(entryName, { level: 1 })
  outer.add(entry)
  entry.push(data, true)
  count += 1
}

;(async () => {
  await packGamedir('valve')
  await packGamedir('cstrike')

  await addRealFile('cstrike/liblist.gam', join(process.cwd(), 'config', 'liblist.gam'))

  const hldsDelta = join(sourceDir, 'cstrike', 'delta.lst')
  if (
    await stat(hldsDelta)
      .then((s) => s.isFile())
      .catch(() => false)
  ) {
    await addRealFile('cstrike/delta.lst', hldsDelta)
  }

  outer.end()
  await new Promise((resolve, reject) => {
    out.on('close', resolve)
    out.on('error', reject)
  })

  console.log(
    `\n✓ ${outFile}: ${count} file, ${(bytes / 1e6).toFixed(1)} MB nguồn, ` +
      `${Math.round((Date.now() - started) / 1000)} s`,
  )
})().catch((error) => {
  console.error('✗', error.message)
  process.exit(1)
})
