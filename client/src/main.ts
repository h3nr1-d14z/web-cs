import { WEBASSETS_URL, currentRoomId } from './config'
import { blockMicrophone, startEngine, type Session } from './engine'
import { downloadGameZip, type DownloadProgress } from './assets'
import {
  applyPrefs,
  BINDS,
  BOOL_SETTINGS,
  defaultPrefs,
  displayKey,
  keyNameFromEvent,
  loadPrefs,
  maxKeysPerAction,
  mouseNameFromEvent,
  NUMBER_SETTINGS,
  savePrefs,
  wheelNameFromEvent,
} from './settings'
import { log } from './log'

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id)
  if (!el) throw new Error(`Thiếu phần tử #${id} trong play.html`)
  return el as T
}

const ui = {
  body: document.body,
  stage: $<HTMLElement>('stage'),
  canvas: $<HTMLCanvasElement>('canvas'),
  loading: $<HTMLElement>('loading'),
  loadingTitle: $<HTMLElement>('loading-title'),
  progressBar: $<HTMLElement>('progress-bar'),
  progressText: $<HTMLElement>('progress-text'),
  loadingLog: $<HTMLElement>('loading-log'),
  pause: $<HTMLElement>('pause'),
  btnResume: $<HTMLButtonElement>('btn-resume'),
  btnToggleFs: $<HTMLButtonElement>('btn-toggle-fs'),
  btnLeave: $<HTMLButtonElement>('btn-leave'),
  btnUnlock: $<HTMLButtonElement>('btn-unlock'),
  btnFs: $<HTMLButtonElement>('btn-fs'),
  hudMap: $<HTMLElement>('hud-map'),
  hudPlayers: $<HTMLElement>('hud-players'),
  hudNet: $<HTMLElement>('hud-net'),
  tabBtnGuide: $<HTMLButtonElement>('tab-btn-guide'),
  tabBtnSettings: $<HTMLButtonElement>('tab-btn-settings'),
  tabBtnBinds: $<HTMLButtonElement>('tab-btn-binds'),
  tabBtnServer: $<HTMLButtonElement>('tab-btn-server'),
  paneGuide: $<HTMLElement>('pane-guide'),
  paneSettings: $<HTMLElement>('pane-settings'),
  paneBinds: $<HTMLElement>('pane-binds'),
  paneServer: $<HTMLElement>('pane-server'),
  presetList: $<HTMLElement>('preset-list'),
  mapList: $<HTMLElement>('map-list'),
  btnRestart: $<HTMLButtonElement>('btn-restart'),
  botsCount: $<HTMLElement>('bots-count'),
  botPlus: $<HTMLButtonElement>('btn-bot-plus'),
  botMinus: $<HTMLButtonElement>('btn-bot-minus'),
  ownerControls: $<HTMLElement>('owner-controls'),
  ownerHint: $<HTMLElement>('owner-hint'),
  btnCloseRoom: $<HTMLButtonElement>('btn-close-room'),
  mapUrl: $<HTMLInputElement>('map-url'),
  mapName: $<HTMLInputElement>('map-name'),
  btnInstall: $<HTMLButtonElement>('btn-install'),
  bindGrid: $<HTMLElement>('bind-grid'),
  btnBindsReset: $<HTMLButtonElement>('btn-binds-reset'),
  btnConsole: $<HTMLButtonElement>('btn-console'),
  logPanel: $<HTMLElement>('logpanel'),
  logBuffer: $<HTMLElement>('logbuffer'),
  btnLog: $<HTMLButtonElement>('btn-log'),
  btnLogClose: $<HTMLButtonElement>('btn-log-close'),
}

const STORE_NICK = 'webcs.nick'
const STORE_CODE = 'webcs.code'
const STORE_FULLSCREEN = 'webcs.fullscreen'
const STORE_ONBOARDED = 'webcs.onboarded'

interface ServerStatus {
  online: boolean
  name?: string
  map?: string
  players?: number
  maxPlayers?: number
  bots?: number
}

let session: Session | null = null
let starting = false
let statusTimer: number | undefined
let capturing: { cmd: string; slot: number; button: HTMLButtonElement } | null = null
const prefs = loadPrefs()
const roomId = currentRoomId()
const ownerToken = localStorage.getItem(`webcs.owner.${roomId}`) ?? ''
let isRoomOwner = false

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => window.setTimeout(resolve, ms))

const exec = (command: string): void => {
  session?.xash.Cmd_ExecuteString(command)
}

/* ------------------------------------------------------------------ */
/* api                                                                 */
/* ------------------------------------------------------------------ */

async function api<T = Record<string, unknown>>(
  path: string,
  body?: unknown,
  method?: 'GET' | 'POST' | 'PATCH' | 'DELETE',
): Promise<T> {
  const code = localStorage.getItem(STORE_CODE)?.trim()
  const verb = method ?? (body === undefined ? 'GET' : 'POST')
  const response = await fetch(path, {
    method: verb,
    headers: {
      'content-type': 'application/json',
      ...(code ? { 'x-access-code': code } : {}),
      ...(roomId && ownerToken ? { 'x-room-token': ownerToken } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const json = (await response.json().catch(() => ({}))) as T & { error?: string }
  if (!response.ok) throw new Error(json.error ?? `HTTP ${response.status}`)
  return json
}

/* ------------------------------------------------------------------ */
/* loading ui                                                          */
/* ------------------------------------------------------------------ */

const fmtMB = (bytes: number): string => `${(bytes / 1e6).toFixed(1)} MB`

function setLoading(title: string, detail: string): void {
  ui.loading.hidden = false
  ui.loadingTitle.textContent = title
  ui.progressText.textContent = detail
}

function setProgress(pct: number | null): void {
  ui.progressBar.style.width = pct === null ? '30%' : `${Math.max(0, Math.min(100, pct))}%`
  ui.progressBar.style.opacity = pct === null ? '0.5' : '1'
}

function appendLoadingLog(line: string): void {
  const lines = ui.loadingLog.textContent ? ui.loadingLog.textContent.split('\n') : []
  lines.push(line)
  ui.loadingLog.textContent = lines.slice(-9).join('\n')
  ui.loadingLog.scrollTop = ui.loadingLog.scrollHeight
}

function showError(message: string): void {
  ui.loading.hidden = false
  ui.loadingTitle.textContent = 'Không vào được game'
  setProgress(0)
  ui.progressText.textContent = message
  appendLoadingLog(message)
  appendLoadingLog('Nhấn F5 để thử lại.')
  starting = false
}

/* ------------------------------------------------------------------ */
/* server status (HUD)                                                 */
/* ------------------------------------------------------------------ */

async function refreshStatus(): Promise<ServerStatus | null> {
  try {
    const url = `/api/status${roomId ? `?room=${encodeURIComponent(roomId)}` : ''}`
    const response = await fetch(url, { cache: 'no-store' })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const status = (await response.json()) as ServerStatus
    renderStatus(status)
    return status
  } catch {
    renderStatus({ online: false })
    return null
  }
}

function renderStatus(status: ServerStatus): void {
  if (!session) return
  if (!status.online) {
    ui.hudMap.textContent = '—'
    ui.hudPlayers.textContent = '—'
    return
  }
  ui.hudMap.textContent = status.map || '—'
  ui.hudPlayers.textContent = `${status.players ?? 0} / ${status.maxPlayers ?? 0}`
}

function startStatusPolling(): void {
  window.clearInterval(statusTimer)
  statusTimer = window.setInterval(() => void refreshStatus(), 8000)
}

/* ------------------------------------------------------------------ */
/* pointer lock / fullscreen                                           */
/* ------------------------------------------------------------------ */

function requestLock(): void {
  if (!session) return
  ui.canvas.focus()
  const result = ui.canvas.requestPointerLock() as unknown as Promise<void> | undefined
  if (result && typeof result.catch === 'function') result.catch(() => undefined)
}

function syncPointerState(): void {
  const locked = document.pointerLockElement === ui.canvas
  ui.body.classList.toggle('pointer-locked', locked)
  ui.pause.hidden = !session || locked
}

/**
 * Giữ phím nóng trình duyệt trong game: trong CS, Ctrl là ngồi nên Ctrl+W
 * (ngồi + tiến) rất dễ bấm, và hộp thoại "rời trang" của trình duyệt là modal —
 * nó treo JS của engine cho tới khi bấm. Chrome chỉ cho phép lock khi đang
 * fullscreen; không hỗ trợ thì bỏ qua (beforeunload vẫn là lưới an toàn).
 */
async function lockKeyboard(): Promise<void> {
  const keyboard = (navigator as Navigator & { keyboard?: { lock?: () => Promise<void> } }).keyboard
  try {
    await keyboard?.lock?.()
    log.push('ui', 'đã khoá phím trình duyệt (Ctrl+W ở lại trong game)')
  } catch {
    /* chưa fullscreen / trình duyệt không hỗ trợ */
  }
}

function unlockKeyboard(): void {
  ;(navigator as Navigator & { keyboard?: { unlock?: () => void } }).keyboard?.unlock?.()
}

async function toggleFullscreen(): Promise<void> {
  try {
    if (document.fullscreenElement) {
      await document.exitFullscreen()
      return
    }
    await enterFullscreen(session ? ui.canvas : document.documentElement)
  } catch (error) {
    log.push('ui', `Fullscreen thất bại: ${String(error)}`)
  }
}

async function enterFullscreen(target: HTMLElement): Promise<void> {
  const options: FullscreenOptions = { navigationUI: 'hide' }
  try {
    await target.requestFullscreen(options)
  } catch {
    // Chrome chặn requestFullscreen ~1.5s sau khi ESC thoát fullscreen.
    await sleep(1600)
    await target.requestFullscreen(options)
  }
}

/* ------------------------------------------------------------------ */
/* settings & binds                                                    */
/* ------------------------------------------------------------------ */

function showTab(tab: 'guide' | 'settings' | 'binds' | 'server'): void {
  const panes: Record<string, HTMLElement> = {
    guide: ui.paneGuide,
    settings: ui.paneSettings,
    binds: ui.paneBinds,
    server: ui.paneServer,
  }
  for (const [name, pane] of Object.entries(panes)) pane.hidden = name !== tab
  ui.tabBtnGuide.classList.toggle('tab--active', tab === 'guide')
  ui.tabBtnSettings.classList.toggle('tab--active', tab === 'settings')
  ui.tabBtnBinds.classList.toggle('tab--active', tab === 'binds')
  ui.tabBtnServer.classList.toggle('tab--active', tab === 'server')
  if (tab === 'binds') renderBinds()
  if (tab === 'server') void refreshServerPane()
}

function formatValue(value: number, format?: (v: number) => string): string {
  return format ? format(value) : String(Math.round(value * 100) / 100)
}

function buildSettingsPane(): void {
  const pane = ui.paneSettings
  pane.innerHTML = ''

  for (const setting of NUMBER_SETTINGS) {
    const row = document.createElement('div')
    row.className = 'setting-row'

    const label = document.createElement('label')
    label.textContent = setting.label

    const input = document.createElement('input')
    input.type = 'range'
    input.min = String(setting.min)
    input.max = String(setting.max)
    input.step = String(setting.step)
    input.value = String(prefs.numbers[setting.id])

    const chip = document.createElement('span')
    chip.className = 'value-chip'
    chip.textContent = formatValue(prefs.numbers[setting.id], setting.format)

    input.addEventListener('input', () => {
      const value = Number(input.value)
      prefs.numbers[setting.id] = value
      chip.textContent = formatValue(value, setting.format)
      savePrefs(prefs)
      exec(`${setting.cvar} ${value}`)
    })

    row.append(label, input, chip)
    pane.append(row)
  }

  for (const setting of BOOL_SETTINGS) {
    const row = document.createElement('div')
    row.className = 'setting-row'

    const label = document.createElement('label')
    label.textContent = setting.label

    const input = document.createElement('input')
    input.type = 'checkbox'
    input.checked = prefs.bools[setting.id]

    input.addEventListener('change', () => {
      prefs.bools[setting.id] = input.checked
      savePrefs(prefs)
      exec(`${setting.cvar} ${input.checked ? setting.on : setting.off}`)
    })

    row.append(label, input)
    pane.append(row)
  }
}

const GUIDE_ROWS: Array<[string, string]> = [
  ['Di chuyển', 'W A S D'],
  ['Nhảy / Ngồi / Đi bộ', 'Space / Ctrl / Shift'],
  ['Bắn / Bắn phụ', 'Chuột trái / Chuột phải'],
  ['Nạp đạn', 'R'],
  ['Mua súng', 'B (chọn trang bị bằng số)'],
  ['Đổi súng', '1 súng chính · 2 súng ngắn · 3 dao · 4 lựu đạn'],
  ['Dùng / gỡ bom, giữ con tin', 'E'],
  ['Vứt vũ khí', 'G'],
  ['Bảng điểm', 'Tab'],
  ['Đèn pin', 'F'],
  ['Menu này', 'ESC'],
]

function buildGuidePane(): void {
  const pane = ui.paneGuide
  pane.innerHTML = ''
  for (const [action, keys] of GUIDE_ROWS) {
    const row = document.createElement('div')
    row.className = 'setting-row'
    const left = document.createElement('span')
    left.textContent = action
    const right = document.createElement('span')
    right.className = 'value-chip'
    right.style.minWidth = '0'
    right.style.whiteSpace = 'normal'
    right.style.textAlign = 'right'
    right.textContent = keys
    row.append(left, right)
    pane.append(row)
  }
  const tip = document.createElement('p')
  tip.className = 'pane-hint'
  tip.style.marginTop = '10px'
  tip.textContent =
    'Đổi phím ở tab “Phím”. Bấm chuột vào màn hình để khóa chuột, ESC để mở lại mục này.'
  pane.append(tip)
}

/* ------------------------------------------------------------------ */
/* server tab (owner-only controls + presets + map picker)             */
/* ------------------------------------------------------------------ */

function renderOwnerControls(): void {
  ui.ownerControls.hidden = !isRoomOwner
  ui.ownerHint.hidden = isRoomOwner
  ui.botsCount.textContent = String(roomBots())
}

function roomBots(): number {
  return Number(ui.botsCount.textContent) || 0
}

async function setBots(count: number): Promise<void> {
  try {
    const view = await api<Pick<RoomView, 'bots'>>(`/api/rooms/${roomId}`, { bots: count }, 'PATCH')
    ui.botsCount.textContent = String(view.bots)
  } catch (error) {
    log.push('server', `đổi số bot lỗi: ${String(error)}`)
    renderOwnerControls()
  }
}

async function installMap(): Promise<void> {
  const url = ui.mapUrl.value.trim()
  const name = ui.mapName.value.trim().toLowerCase()
  if (!url || !name) {
    log.push('server', 'Cần nhập URL và tên map')
    return
  }
  ui.btnInstall.disabled = true
  ui.btnInstall.textContent = 'đang cài…'
  try {
    const res = await api<{ installed: string[] }>(`/api/admin/maps/install`, { url, name }, 'POST')
    log.push('server', `Đã cài map: ${res.installed.join(', ')}`)
    ui.btnInstall.textContent = '✔ xong'
    ui.mapUrl.value = ''
    ui.mapName.value = ''
    await refreshServerPane()
  } catch (error) {
    log.push('server', `Cài map lỗi: ${String(error)}`)
    ui.btnInstall.textContent = '✗ lỗi (xem Nhật ký)'
  }
  window.setTimeout(() => {
    ui.btnInstall.disabled = false
    ui.btnInstall.textContent = 'Cài'
  }, 2500)
}

async function refreshServerPane(): Promise<void> {
  ui.btnRestart.disabled = true
  try {
    const [presets, maps, roomInfo] = await Promise.all([
      api('/api/presets') as Promise<Record<string, { label: string; maps: string[] }>>,
      api('/api/maps') as Promise<{ maps: string[] }>,
      roomId ? api<RoomView>(`/api/rooms/${roomId}`) : Promise.resolve(null),
    ])

    isRoomOwner = Boolean(roomInfo?.isOwner)
    renderOwnerControls()

    ui.presetList.innerHTML = ''
    for (const [id, preset] of Object.entries(presets)) {
      const button = document.createElement('button')
      button.type = 'button'
      button.className = 'btn btn--small'
      button.style.margin = '0 0 6px'
      button.textContent = preset.label
      button.addEventListener('click', () => void applyPreset(id, button))
      ui.presetList.append(button)
    }
    if (!ui.presetList.childElementCount) {
      ui.presetList.innerHTML = '<span class="pane-hint">Không có preset nào.</span>'
    }

    ui.mapList.innerHTML = ''
    for (const map of maps.maps ?? []) {
      const button = document.createElement('button')
      button.type = 'button'
      button.className = 'btn btn--ghost btn--small'
      button.style.margin = '0 4px 4px 0'
      button.style.display = 'inline-block'
      button.style.width = 'auto'
      button.textContent = map
      button.addEventListener('click', () => void changeMap(map, button))
      ui.mapList.append(button)
    }
  } catch (error) {
    ui.mapList.innerHTML = `<span class="pane-hint">Không nạp được: ${String(error)}</span>`
  } finally {
    ui.btnRestart.disabled = false
  }
}

interface RoomView {
  bots: number
  isOwner?: boolean
  map?: string
}

async function applyPreset(id: string, button: HTMLButtonElement): Promise<void> {
  const previous = button.textContent
  button.disabled = true
  button.textContent = 'đang áp…'
  try {
    await api(`/api/rooms/${roomId}/preset`, { name: id })
    button.textContent = '✔ đã áp'
    await refreshStatus()
  } catch (error) {
    button.textContent = previous
    log.push('server', `preset lỗi: ${String(error)}`)
  }
  window.setTimeout(() => {
    button.disabled = false
    button.textContent = previous
  }, 2500)
}

async function changeMap(map: string, button: HTMLButtonElement): Promise<void> {
  button.disabled = true
  try {
    await api(`/api/rooms/${roomId}`, { map }, 'PATCH')
    ui.hudNet.textContent = `đang đổi map → ${map}`
    log.push('server', `changelevel ${map}`)
    await refreshStatus()
  } catch (error) {
    log.push('server', `changelevel lỗi: ${String(error)}`)
  }
  window.setTimeout(() => {
    button.disabled = false
  }, 1500)
}

/* ------------------------------------------------------------------ */
/* binds                                                               */
/* ------------------------------------------------------------------ */

function renderBinds(): void {
  ui.bindGrid.innerHTML = ''

  for (const def of BINDS) {
    const row = document.createElement('div')
    row.className = 'bind-row'

    const label = document.createElement('span')
    label.textContent = def.label

    const keys = document.createElement('span')
    keys.className = 'bind-keys'

    const slots = prefs.binds[def.cmd] ?? []
    slots.forEach((key, index) => {
      const wrap = document.createElement('span')
      wrap.className = 'keywrap'

      const cap = document.createElement('button')
      cap.type = 'button'
      cap.className = 'keycap'
      cap.textContent = displayKey(key)
      cap.title = 'Click để đổi phím này'
      cap.addEventListener('click', () => startCapture(def.cmd, index, cap))

      const clear = document.createElement('button')
      clear.type = 'button'
      clear.className = 'keyclear'
      clear.textContent = '×'
      clear.title = 'Gỡ phím này (unbind)'
      clear.addEventListener('click', (event) => {
        event.stopPropagation()
        clearSlot(def.cmd, index)
      })

      wrap.append(cap, clear)
      keys.append(wrap)
    })

    if (slots.length < maxKeysPerAction()) {
      const add = document.createElement('button')
      add.type = 'button'
      add.className = 'keycap keyadd'
      add.textContent = '＋ thêm'
      add.title = 'Gán thêm phím (bàn phím / nút chuột / scroll)'
      add.addEventListener('click', () => startCapture(def.cmd, slots.length, add))
      keys.append(add)
    }

    row.append(label, keys)
    ui.bindGrid.append(row)
  }
}

function startCapture(cmd: string, slot: number, button: HTMLButtonElement): void {
  capturing?.button.classList.remove('capturing')
  capturing = { cmd, slot, button }
  button.textContent = 'nhấn phím…'
  button.classList.add('capturing')
}

function clearSlot(cmd: string, index: number): void {
  if (capturing) {
    capturing.button.classList.remove('capturing')
    capturing = null
  }
  const keys = prefs.binds[cmd] ?? []
  const [key] = keys.splice(index, 1)
  if (!key) {
    renderBinds()
    return
  }
  const stillUsed = Object.values(prefs.binds).some((list) => list.includes(key))
  if (!stillUsed) {
    prefs.unbound = [...new Set([...prefs.unbound, key])]
    exec(`unbind ${key}`)
  }
  savePrefs(prefs)
  renderBinds()
}

function commitCapture(key: string | null): void {
  const pending = capturing
  if (!pending) return
  capturing = null
  if (!key) {
    renderBinds()
    return
  }

  const { cmd, slot } = pending

  for (const [other, keys] of Object.entries(prefs.binds)) {
    if (other !== cmd) prefs.binds[other] = keys.filter((k) => k !== key)
  }
  prefs.unbound = prefs.unbound.filter((k) => k !== key)

  const slots = prefs.binds[cmd]
  if (slot >= 0 && slot < slots.length) slots[slot] = key
  else if (!slots.includes(key) && slots.length < maxKeysPerAction()) slots.push(key)

  savePrefs(prefs)
  exec(`bind ${key} "${cmd}"`)
  renderBinds()
}

function onCaptureKeydown(event: KeyboardEvent): void {
  if (!capturing) return
  event.preventDefault()
  event.stopPropagation()
  commitCapture(event.code === 'Escape' ? null : keyNameFromEvent(event))
}

function onCapturePointerDown(event: PointerEvent): void {
  if (!capturing) return
  event.preventDefault()
  event.stopPropagation()
  commitCapture(mouseNameFromEvent(event))
}

function onCaptureWheel(event: WheelEvent): void {
  if (!capturing) return
  event.preventDefault()
  event.stopPropagation()
  commitCapture(wheelNameFromEvent(event))
}

/* ------------------------------------------------------------------ */
/* boot flow                                                           */
/* ------------------------------------------------------------------ */

function onDownloadProgress(progress: DownloadProgress): void {
  if (progress.total > 0) {
    const pct = (progress.received / progress.total) * 100
    setProgress(pct)
    ui.progressText.textContent = `${fmtMB(progress.received)} / ${fmtMB(progress.total)} (${pct.toFixed(0)}%)`
  } else {
    setProgress(null)
    ui.progressText.textContent = fmtMB(progress.received)
  }
}

async function startGame(): Promise<void> {
  if (starting || session) return
  starting = true

  ui.loading.hidden = false
  ui.loadingLog.textContent = ''
  setLoading('Đang chuẩn bị…', '0%')
  setProgress(0)

  blockMicrophone()

  const nickname = localStorage.getItem(STORE_NICK)?.trim() || 'player'
  const sensitivity = prefs.numbers.sensitivity
  const accessCode = localStorage.getItem(STORE_CODE)?.trim() ?? ''

  const unsubscribe = log.subscribe(appendLoadingLog)
  try {
    // Kiểm mã trước khi tải 30MB engine: sai mã thì báo ngay, đừng để WS chết
    // lặng rồi engine boot thành game cục bộ.
    try {
      await api('/api/entry')
    } catch (error) {
      throw new Error(
        `Không vào được server: ${error instanceof Error ? error.message : String(error)}. ` +
          'Quay lại dashboard, nhập mã truy cập rồi bấm Vào game.',
      )
    }

    setLoading('Đang tải file game…', '0%')
    log.push('boot', `Tải ${WEBASSETS_URL}`)
    const zip = await downloadGameZip(WEBASSETS_URL, onDownloadProgress)

    setLoading('Đang khởi động engine…', 'đang nạp')
    log.push('boot', `Đã tải ${fmtMB(zip.byteLength)}, khởi động engine`)
    setProgress(null)

    // Map custom (parkour/kz...) — gói riêng, chỉ tải lại khi có map mới.
    let customZip: Uint8Array | undefined
    try {
      const { version } = await api<{ version: string }>('/api/custom')
      if (version) {
        setLoading('Đang tải map custom…', '')
        const res = await fetch(`/custom.pk3?v=${version}`)
        if (res.ok) customZip = new Uint8Array(await res.arrayBuffer())
        log.push('boot', `custom.pk3 v${version}: ${customZip ? fmtMB(customZip.byteLength) : 'không có'}`)
      }
    } catch (error) {
      log.push('boot', `custom maps bỏ qua: ${String(error)}`)
    }
    setProgress(null)

    ui.stage.hidden = false
    ui.body.classList.remove('state-lobby')
    ui.body.classList.add('state-game')

    const started = await startEngine({
      canvas: ui.canvas,
      nickname,
      sensitivity,
      zip,
      customZip,
      accessCode,
    })
    session = started

    // Replay stored settings (sensitivity, volume, binds…) sau khi engine sống.
    window.setTimeout(() => {
      if (session === started) applyPrefs(exec, prefs)
    }, 700)

    setProgress(100)
    setLoading('Đang vào server…', 'xong')
    window.setTimeout(() => {
      ui.loading.hidden = true
      ui.hudNet.textContent = 'đang kết nối…'
      ui.hudNet.className = 'hud-chip'
      syncPointerState()
      if (localStorage.getItem(STORE_FULLSCREEN) === '1') void toggleFullscreen()
      requestLock()
      if (document.fullscreenElement) void lockKeyboard()
      const first = localStorage.getItem(STORE_ONBOARDED) !== '1'
      localStorage.setItem(STORE_ONBOARDED, '1')
      showTab(first ? 'guide' : 'settings')
    }, 400)

    const onTransportState = (state: 'connecting' | 'open' | 'closed'): void => {
      if (state === 'open') {
        ui.hudNet.textContent = everOpened ? 'đã nối lại — đang vào server' : 'đang vào server…'
        ui.hudNet.className = 'hud-chip'
        if (everOpened) {
          connected = false
          attempts = 0
          stopRetry()
          window.setTimeout(retryLoop, 800)
        }
        everOpened = true
      }

      if (state === 'closed' && session) {
        connected = false
        stopRetry()
        ui.hudNet.textContent = localStorage.getItem(STORE_CODE)?.trim()
          ? 'mất kết nối — đang thử lại'
          : 'mất kết nối — thiếu mã vào (nhập ở dashboard)'
        ui.hudNet.className = 'hud-chip hud-chip--bad'
        // Chỉ tự nối lại khi từng vào được; lỗi lúc mở (vd. 401 vì thiếu mã) thì
        // để retryLoop thưa hơn xử lý, tránh spam 1 req/1.2s.
        if (everOpened) {
          window.setTimeout(() => {
            if (!session) return
            started.transport.reconnect()
          }, 1200)
        }
      }
    }
    started.transport.onState = onTransportState
    // WS có thể đã chết trước khi gắn hook — bắt kịp để báo đúng lý do ngay.
    if (started.transport.state === 'closed') onTransportState('closed')

    log.subscribe((line) => {
      if (!session) return
      if (/Connection accepted|Spawned with|Server info|server \d+\.\d+\.\d+\.\d+:\d+/i.test(line)) {
        connected = true
        stopRetry()
        ui.hudNet.textContent = 'đã kết nối'
        ui.hudNet.className = 'hud-chip hud-chip--good'
        void refreshStatus()
      }
      if (/Server is not responding|Connection refused/i.test(line)) {
        connected = false
        if (retryTimer === undefined) retryLoop()
      }
    })

    window.setTimeout(retryLoop, 8000)
  } catch (error) {
    log.push('boot', `Lỗi: ${String(error)}`)
    showError(error instanceof Error ? error.message : String(error))
  } finally {
    unsubscribe()
  }
}

// Connection supervision — hoisted declarations used above.
let connected = false
let attempts = 0
let everOpened = false
let retryTimer: number | undefined

function stopRetry(): void {
  if (retryTimer !== undefined) window.clearTimeout(retryTimer)
  retryTimer = undefined
}

function retryLoop(): void {
  if (!session || connected) return
  if (attempts >= 15) {
    ui.hudNet.textContent = 'không kết nối được — tải lại trang để thử lại'
    ui.hudNet.className = 'hud-chip hud-chip--bad'
    return
  }
  attempts += 1
  // Chỉ nối lại WS khi nó đã chết: reconnect một socket đang mở sẽ cắt ngang
  // quá trình signon của engine. `connect` phía engine thì luôn gửi lại.
  if (session.transport.state !== 'open') session.transport.reconnect()
  session.connect()
  retryTimer = window.setTimeout(retryLoop, 5000)
}

function leaveGame(): void {
  unlockKeyboard()
  session?.transport.close()
  session?.xash.quit()
  session = null
  location.href = '/'
}

/* ------------------------------------------------------------------ */
/* wiring                                                              */
/* ------------------------------------------------------------------ */

function wireUi(): void {
  ui.canvas.addEventListener('click', () => {
    if (document.pointerLockElement !== ui.canvas) requestLock()
  })

  ui.btnResume.addEventListener('click', requestLock)
  ui.btnUnlock.addEventListener('click', requestLock)
  ui.btnFs.addEventListener('click', () => void toggleFullscreen())
  ui.btnToggleFs.addEventListener('click', () => void toggleFullscreen())
  ui.btnLeave.addEventListener('click', leaveGame)

  ui.tabBtnGuide.addEventListener('click', () => showTab('guide'))
  ui.tabBtnSettings.addEventListener('click', () => showTab('settings'))
  ui.tabBtnBinds.addEventListener('click', () => showTab('binds'))
  ui.tabBtnServer.addEventListener('click', () => showTab('server'))
  ui.btnRestart.addEventListener('click', async () => {
    try {
      await api(`/api/rooms/${roomId}`, { restart: true }, 'PATCH')
    } catch (error) {
      log.push('server', `restart lỗi: ${String(error)}`)
    }
  })
  ui.btnBindsReset.addEventListener('click', () => {
    prefs.binds = defaultPrefs().binds
    prefs.unbound = []
    savePrefs(prefs)
    renderBinds()
    if (session) applyPrefs(exec, prefs)
  })
  ui.btnConsole.addEventListener('click', () => exec('togglebrowserconsole'))
  ui.btnInstall.addEventListener('click', () => void installMap())

  ui.botPlus.addEventListener('click', () => void setBots(roomBots() + 1))
  ui.botMinus.addEventListener('click', () => void setBots(Math.max(0, roomBots() - 1)))
  ui.btnCloseRoom.addEventListener('click', async () => {
    if (!confirm('Đóng phòng này? Mọi người trong phòng sẽ bị ngắt.')) return
    try {
      await api(`/api/rooms/${roomId}`, undefined, 'DELETE')
    } catch {
      /* room manager đã đóng */
    }
    localStorage.removeItem(`webcs.owner.${roomId}`)
    location.href = '/'
  })

  document.addEventListener('fullscreenchange', () => {
    window.dispatchEvent(new Event('resize'))
    if (document.fullscreenElement) void lockKeyboard()
    else unlockKeyboard()
  })
  // Mất WebGL context (GPU reset, chuyển tab lâu) = đứng hình vĩnh viễn; ghi
  // lại để lần sau biết đúng nguyên nhân thay vì đoán.
  ui.canvas.addEventListener('webglcontextlost', () => {
    log.push('gl', 'WebGL context lost — game sẽ đứng hình, tải lại trang')
    ui.hudNet.textContent = 'mất WebGL — F5'
    ui.hudNet.className = 'hud-chip hud-chip--bad'
  })
  document.addEventListener('pointerlockchange', syncPointerState)
  window.addEventListener('keydown', onCaptureKeydown, true)
  window.addEventListener('pointerdown', onCapturePointerDown, true)
  window.addEventListener('wheel', onCaptureWheel, { capture: true, passive: false })

  // giữ ESC cho overlay, không để engine mở menu (VGUI hỏng trên wasm)
  window.addEventListener(
    'keydown',
    (event) => {
      if (event.code !== 'Escape' || !session) return
      event.preventDefault()
      event.stopImmediatePropagation()
      if (document.pointerLockElement === ui.canvas) document.exitPointerLock()
      else syncPointerState()
    },
    { capture: true },
  )

  ui.btnLog.addEventListener('click', () => {
    ui.logPanel.hidden = !ui.logPanel.hidden
    ui.logBuffer.scrollTop = ui.logBuffer.scrollHeight
  })
  ui.btnLogClose.addEventListener('click', () => {
    ui.logPanel.hidden = true
  })

  log.subscribe((line) => {
    if (ui.logPanel.hidden) return
    ui.logBuffer.textContent += `${line}\n`
    const lines = ui.logBuffer.textContent.split('\n')
    if (lines.length > 600) ui.logBuffer.textContent = lines.slice(-600).join('\n')
    ui.logBuffer.scrollTop = ui.logBuffer.scrollHeight
  })

  window.addEventListener('beforeunload', (event) => {
    if (!session) return
    event.preventDefault()
    event.returnValue = ''
  })
}

function main(): void {
  ;(window as unknown as Record<string, unknown>).__webcs = { log }

  buildGuidePane()
  buildSettingsPane()
  wireUi()

  if (!roomId) {
    log.push('boot', 'Không có ?room= — sẽ vào phòng đầu tiên nếu có.')
  }

  // Link play share kèm ?code=: nhớ luôn cho các lần vào sau.
  const urlCode = new URLSearchParams(location.search).get('code')?.trim()
  if (urlCode) localStorage.setItem(STORE_CODE, urlCode)

  void refreshStatus()
  startStatusPolling()
  void startGame() // trang chơi: tự vào game luôn (nick/preset đã chọn ở dashboard)

  if (new URLSearchParams(location.search).has('debug')) {
    ui.logPanel.hidden = false
  }
}

main()
