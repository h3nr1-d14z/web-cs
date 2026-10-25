#!/usr/bin/env node
/**
 * Vendors the Counter-Strike client side modules used by the browser engine.
 *
 * Source: the `gh-pages` branch of x8BitRain/webXash, which commits the wasm
 * build output of https://github.com/FWGS/cs16-client that ships with a running
 * public deployment. That deployment pins the exact same engine build we vendor
 * (`xash-CAtKZwSO.wasm`, npm xash3d-fwgs@1.2.2), so the client/server interface
 * versions match — the newer cs16-client build (from npm `xash-cs-demo`) refuses
 * to start on this engine ("Xash3D FWGS version check failed", it requires
 * host_ver >= 4190).
 *
 * The npm package `cs16-client` that used to carry this build was unpublished,
 * and the upstream GitHub repo only publishes native builds, so a deployed
 * artifact is the only checksum-pinnable source left. Every byte is verified
 * against the hashes below before anything is written, so a swapped response
 * fails the build instead of shipping.
 *
 *   node scripts/vendor-engine.mjs
 */
import { createHash } from 'node:crypto'
import { mkdir, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const BASE =
  'https://raw.githubusercontent.com/x8BitRain/webXash/gh-pages/cs16-client/dist/cstrike/cl_dlls'

const FILES = {
  'client_emscripten_wasm32.wasm': {
    url: `${BASE}/client_emscripten_wasm32.wasm`,
    sha256: '3a8b26a14ce562ab3bcfbf2a8f57c2822ae04c2a134caedbb03355003ea5ecf7',
  },
  'menu_emscripten_wasm32.wasm': {
    url: `${BASE}/menu_emscripten_wasm32.wasm`,
    sha256: 'd5802742d32b9295efa7479114798c832248c758ee4474af0dafaa2773d7d086',
  },
  'cs_emscripten_wasm32.wasm': {
    // Server-side game library. Only used if something asks the engine to host
    // a local game (e.g. the engine's own menu); preloading it keeps that path
    // from aborting with "could not load dynamic lib".
    url: 'https://raw.githubusercontent.com/x8BitRain/webXash/gh-pages/cs16-client/dist/cstrike/dlls/cs_emscripten_wasm32.wasm',
    sha256: '9c838823ddec4f65986a0f8e715d7b22f01e2e9dc9de59fe03752bcdebdc0b97',
  },
}

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const outDir = join(root, 'client', 'vendor')

const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex')

async function fetchPinned(name, { url, sha256: expected }) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`${url} -> HTTP ${response.status}`)
  const bytes = Buffer.from(await response.arrayBuffer())
  const actual = sha256(bytes)
  if (actual !== expected) {
    throw new Error(`${name}: checksum mismatch\n  expected ${expected}\n  actual   ${actual}`)
  }
  await writeFile(join(outDir, name), bytes)
  console.log(`✓ ${name} (${(bytes.length / 1024).toFixed(0)} KB) ${actual.slice(0, 12)}…`)
}

await mkdir(outDir, { recursive: true })
for (const [name, spec] of Object.entries(FILES)) {
  await fetchPinned(name, spec)
}
console.log('\nVendored CS 1.6 client modules into client/vendor.')
