import { Net, Xash3D } from '../vendor/xash3d-fwgs/dist/index.js'
import xashWasmUrl from '../vendor/xash3d-fwgs/dist/xash.wasm?url'
import filesystemWasmUrl from '../vendor/xash3d-fwgs/dist/filesystem_stdio.wasm?url'
import refWasmUrl from '../vendor/xash3d-fwgs/dist/libref_webgl2.wasm?url'
import extrasPk3Url from '../vendor/xash3d-fwgs/dist/valve/extras.pk3?url'
import clientDllUrl from '../vendor/client_emscripten_wasm32.wasm?url'
import menuDllUrl from '../vendor/menu_emscripten_wasm32.wasm?url'
import serverDllUrl from '../vendor/cs_emscripten_wasm32.wasm?url'

import { GAME_ADDR, GAME_PORT, buildWsUrl } from './config'
import { mountGameBundle } from './assets'
import { WsTransport } from './transport'
import { log } from './log'

/**
 * Exact filenames the engine asks Emscripten's loader for. `dlls/*` is the
 * server-side game library; we preload it too because the engine tries to open
 * it whenever something requests a local game (its own menu, ESC, a stray
 * `map` command) and Emscripten cannot load a dynamic library synchronously at
 * that point — the result is a fatal "could not load dynamic lib" alert.
 */
const ENGINE_FILES: Record<string, string> = {
  'xash.wasm': xashWasmUrl,
  'filesystem_stdio.wasm': filesystemWasmUrl,
  'libref_webgl2.wasm': refWasmUrl,
  'libref_soft.wasm': refWasmUrl,
  'cl_dlls/client_emscripten_wasm32.wasm': clientDllUrl,
  'cl_dlls/menu_emscripten_wasm32.wasm': menuDllUrl,
  'dlls/hl_emscripten_wasm32.wasm': serverDllUrl,
  'dlls/cs_emscripten_wasm32.wasm': serverDllUrl,
  'dlls/mp_emscripten_wasm32.wasm': serverDllUrl,
  'dlls/opfor_emscripten_wasm32.wasm': serverDllUrl,
  'dlls/bshift_emscripten_wasm32.wasm': serverDllUrl,
  // The engine also tries this absolute name when it re-initialises the
  // filesystem (e.g. after leaving a server); preload it so it stays silent.
  '/rodir/filesystem_stdio.wasm': filesystemWasmUrl,
  'libvgui_support.wasm': menuDllUrl,
}

function resolveEngineFile(path: string): string {
  const clean = path.replace(/^\.\//, '')
  const exact = ENGINE_FILES[clean]
  if (exact) return exact

  // The engine sometimes prefixes the game directory (`cstrike/cl_dlls/...`).
  const base = clean.split('/').pop() ?? clean
  if (base.includes('client_emscripten')) return clientDllUrl
  if (base.includes('menu_emscripten')) return menuDllUrl
  if (base.startsWith('dlls/') || /^dlls\/.+_emscripten_wasm32\.wasm$/.test(base)) return serverDllUrl
  if (base.startsWith('libref_')) return refWasmUrl
  return path
}

export interface StartOptions {
  canvas: HTMLCanvasElement
  nickname: string
  sensitivity: number
  zip: Uint8Array
  customZip?: Uint8Array
  accessCode?: string
}

export interface Session {
  xash: Xash3D
  transport: WsTransport
  connect: () => void
}

/**
 * The wasm build opens an audio capture device at startup. On a plain-HTTP
 * origin (our internal deployment) `navigator.mediaDevices` does not even
 * exist, and the engine would abort while probing it — so veto the request
 * before the engine gets a chance to ask.
 */
export function blockMicrophone(): void {
  const deny = (): Promise<never> =>
    Promise.reject(Object.assign(new Error('microphone disabled'), { name: 'NotAllowedError' }))

  try {
    if (navigator.mediaDevices) {
      Object.defineProperty(navigator.mediaDevices, 'getUserMedia', {
        configurable: true,
        writable: true,
        value: deny,
      })
    } else {
      Object.defineProperty(navigator, 'mediaDevices', {
        configurable: true,
        value: { getUserMedia: deny, enumerateDevices: async () => [] },
      })
    }
    Object.defineProperty(navigator, 'getUserMedia', { configurable: true, value: deny })
  } catch (error) {
    log.push('audio', `Không thể vô hiệu hoá micro: ${String(error)}`)
  }
}

function safeName(name: string): string {
  const cleaned = name.replace(/[";\\\r\n]/g, '').trim().slice(0, 16)
  return cleaned || 'player'
}

function describeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`
  return `giá trị không phải Error: ${String(error)}`
}

const fmt = (bytes: Uint8Array): string => `${(bytes.byteLength / 1e6).toFixed(1)} MB`

const DEBUG = new URLSearchParams(location.search).has('debug')

export async function startEngine(options: StartOptions): Promise<Session> {
  const nickname = safeName(options.nickname)

  const transport = new WsTransport(buildWsUrl(options.accessCode))
  const net = new Net(transport)
  transport.onPacket = (bytes) => {
    net.incoming.enqueue({
      data: new Int8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength),
      ip: [127, 0, 0, 1],
      port: GAME_PORT,
    })
  }
  transport.connect()

  const args = [
    '-game',
    'cstrike',
    '-windowed',
    '+_vgui_menus',
    '0',
    '+hud_fastswitch',
    '1',
    '+cl_updaterate',
    '60',
    '+cl_cmdrate',
    '60',
    '+rate',
    '25000',
    '+name',
    nickname,
  ]

  const xash = new Xash3D({
    canvas: options.canvas,
    renderer: 'gles3compat',
    arguments: args,
    filesMap: { ...ENGINE_FILES },
    libraries: {
      xash: xashWasmUrl,
      filesystem: filesystemWasmUrl,
      client: clientDllUrl,
      menu: menuDllUrl,
      server: serverDllUrl,
      render: { gles3compat: refWasmUrl },
    },
    dynamicLibraries: [
      'dlls/cs_emscripten_wasm32.wasm',
      'dlls/mp_emscripten_wasm32.wasm',
      '/rodir/filesystem_stdio.wasm',
    ],
    module: {
      locateFile: (path: string) => resolveEngineFile(path),
      print: (line: string) => {
        log.push('engine', line)
        if (DEBUG) console.log('[xash]', line)
      },
      printErr: (line: string) => {
        log.push('engine!', line)
        if (DEBUG) console.warn('[xash!]', line)
      },
    },
  })
  xash.net = net

  await xash.init()
  const em = xash.em
  if (!em) throw new Error('Engine không khởi tạo được module wasm')

  const fs = em.FS as unknown as {
    mkdirTree: (path: string) => void
    writeFile: (path: string, data: Uint8Array) => void
    chdir: (path: string) => void
  }

  const unpacked = new URLSearchParams(location.search).has('unpacked')
  mountGameBundle(fs, options.zip, '/rodir', { unpacked })

  // Map custom do chủ phòng cài thêm (custom.pk3 trong gamedir cstrike).
  if (options.customZip?.byteLength) {
    fs.writeFile('/rodir/cstrike/custom.pk3', options.customZip)
    log.push('assets', `Đã nạp ${fmt(options.customZip)} map custom`)
  }

  // extras.pk3 carries the engine fonts/HUD bits the wasm build cannot embed.
  const extras = new Uint8Array(await (await fetch(extrasPk3Url)).arrayBuffer())
  fs.writeFile('/rodir/extras.pk3', extras)

  try {
    xash.main()
  } catch (error) {
    log.push('engine!', `main() lỗi: ${describeError(error)}`)
    throw error
  }

  const applySettings = (): void => {
    xash.Cmd_ExecuteString(`name "${nickname}"`)
    xash.Cmd_ExecuteString(`sensitivity ${options.sensitivity.toFixed(2)}`)
    xash.Cmd_ExecuteString('cl_updaterate 60')
    xash.Cmd_ExecuteString('cl_cmdrate 60')
    xash.Cmd_ExecuteString('rate 25000')
  }

  const connect = (): void => {
    log.push('net', `connect ${GAME_ADDR}`)
    xash.Cmd_ExecuteString(`connect ${GAME_ADDR}`)
  }

  window.setTimeout(() => {
    applySettings()
    connect()
  }, 600)

  return { xash, transport, connect }
}
