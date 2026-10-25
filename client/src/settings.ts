/**
 * In-game settings, stored in localStorage and replayed into the engine on boot.
 *
 * The engine's own VGUI menu renders as a black screen in the wasm build, so
 * this panel is the only way players can change sensitivity, binds, etc. Every
 * value maps 1:1 onto a console command (`sensitivity 2.5`, `bind w "+forward"`)
 * — no magic, so anything here can also be typed in the engine console.
 */

export interface NumberSetting {
  id: string
  label: string
  cvar: string
  min: number
  max: number
  step: number
  def: number
  /** Display transform for the value chip, e.g. volume as percent. */
  format?: (value: number) => string
}

export interface BoolSetting {
  id: string
  label: string
  cvar: string
  on: string
  off: string
  def: boolean
}

export interface BindDef {
  label: string
  cmd: string
}

export const NUMBER_SETTINGS: NumberSetting[] = [
  { id: 'sensitivity', label: 'Độ nhạy chuột', cvar: 'sensitivity', min: 0.5, max: 20, step: 0.1, def: 3 },
  {
    id: 'volume',
    label: 'Âm lượng',
    cvar: 'volume',
    min: 0,
    max: 1,
    step: 0.05,
    def: 0.6,
    format: (value) => `${Math.round(value * 100)}%`,
  },
]

export const BOOL_SETTINGS: BoolSetting[] = [
  { id: 'righthand', label: 'Cầm súng tay phải', cvar: 'cl_righthand', on: '1', off: '0', def: true },
  {
    id: 'autowep',
    label: 'Tự đổi sang vũ khí nhặt được',
    cvar: 'cl_autowepswitch',
    on: '1',
    off: '0',
    def: true,
  },
  {
    id: 'fastswitch',
    label: 'Đổi súng không cần xác nhận',
    cvar: 'hud_fastswitch',
    on: '1',
    off: '0',
    def: true,
  },
  { id: 'crosshair', label: 'Hiện tâm ngắm', cvar: 'crosshair', on: '1', off: '0', def: true },
]

export const BINDS: BindDef[] = [
  { label: 'Tiến', cmd: '+forward' },
  { label: 'Lùi', cmd: '+back' },
  { label: 'Sang trái', cmd: '+moveleft' },
  { label: 'Sang phải', cmd: '+moveright' },
  { label: 'Nhảy', cmd: '+jump' },
  { label: 'Ngồi', cmd: '+duck' },
  { label: 'Đi bộ', cmd: '+speed' },
  { label: 'Bắn', cmd: '+attack' },
  { label: 'Bắn phụ', cmd: '+attack2' },
  { label: 'Nạp đạn', cmd: '+reload' },
  { label: 'Dùng / gỡ bom', cmd: '+use' },
  { label: 'Vứt vũ khí', cmd: 'drop' },
  { label: 'Mua súng', cmd: 'buy' },
  { label: 'Bảng điểm', cmd: '+showscores' },
  { label: 'Súng chính', cmd: 'slot1' },
  { label: 'Súng phụ', cmd: 'slot2' },
  { label: 'Dao', cmd: 'slot3' },
  { label: 'Lựu đạn', cmd: 'slot4' },
  { label: 'Đổi súng gần nhất', cmd: 'lastinv' },
  { label: 'Đèn pin', cmd: 'impulse 100' },
  { label: 'Radio 1', cmd: 'radio1' },
]

const DEFAULT_BINDS: Record<string, string[]> = {
  '+forward': ['w'],
  '+back': ['s'],
  '+moveleft': ['a'],
  '+moveright': ['d'],
  '+jump': ['space'],
  '+duck': ['ctrl'],
  '+speed': ['shift'],
  '+attack': ['mouse1'],
  '+attack2': ['mouse2'],
  '+reload': ['r'],
  '+use': ['e'],
  drop: ['g'],
  buy: ['b'],
  '+showscores': ['tab'],
  slot1: ['1'],
  slot2: ['2'],
  slot3: ['3'],
  slot4: ['4'],
  slot5: ['5'],
  lastinv: ['q'],
  'impulse 100': ['f'],
  radio1: ['z'],
}

export interface Prefs {
  numbers: Record<string, number>
  bools: Record<string, boolean>
  /** command → tối đa 2 phím (vd `+jump` → ['space', 'mwheelup']) */
  binds: Record<string, string[]>
  /** phím đã bị gỡ chủ động — phải `unbind` lại khi boot */
  unbound: string[]
}

const STORAGE_KEY = 'webcs.prefs.v1'
const MAX_KEYS_PER_ACTION = 2

/** Số phím tối đa cho một hành động (hiển thị + logic). */
export function maxKeysPerAction(): number {
  return MAX_KEYS_PER_ACTION
}

export function defaultPrefs(): Prefs {
  const numbers: Record<string, number> = {}
  for (const setting of NUMBER_SETTINGS) numbers[setting.id] = setting.def

  const bools: Record<string, boolean> = {}
  for (const setting of BOOL_SETTINGS) bools[setting.id] = setting.def

  const binds: Record<string, string[]> = {}
  for (const [cmd, keys] of Object.entries(DEFAULT_BINDS)) binds[cmd] = [...keys]

  return { numbers, bools, binds, unbound: [] }
}

export function loadPrefs(): Prefs {
  const prefs = defaultPrefs()
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return prefs
    const saved = JSON.parse(raw) as Partial<Prefs>
    for (const [id, value] of Object.entries(saved.numbers ?? {})) {
      if (id in prefs.numbers && typeof value === 'number') prefs.numbers[id] = value
    }
    for (const [id, value] of Object.entries(saved.bools ?? {})) {
      if (id in prefs.bools && typeof value === 'boolean') prefs.bools[id] = value
    }
    // Migration: bản cũ lưu `binds: Record<cmd, string>` (1 phím).
    const savedBinds = (saved.binds ?? {}) as Record<string, unknown>
    for (const cmd of Object.keys(prefs.binds)) {
      const value = savedBinds[cmd]
      if (typeof value === 'string') prefs.binds[cmd] = value ? [value] : []
      else if (Array.isArray(value)) {
        prefs.binds[cmd] = value.filter((k) => typeof k === 'string' && k).slice(0, MAX_KEYS_PER_ACTION)
      }
    }
    if (Array.isArray(saved.unbound)) {
      prefs.unbound = saved.unbound.filter((k) => typeof k === 'string' && k)
    }
  } catch {
    /* corrupt prefs fall back to defaults */
  }
  return prefs
}

export function savePrefs(prefs: Prefs): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs))
  } catch {
    /* private mode etc. — settings just won't persist */
  }
}

/** KeyboardEvent.code → GoldSrc key name, or null when not bindable. */
export function keyNameFromEvent(event: KeyboardEvent): string | null {
  const { code } = event
  if (code.startsWith('Key')) return code.slice(3).toLowerCase()
  if (code.startsWith('Digit')) return code.slice(5)
  const named: Record<string, string> = {
    Space: 'space',
    Enter: 'enter',
    Tab: 'tab',
    Backspace: 'backspace',
    ShiftLeft: 'shift',
    ShiftRight: 'shift',
    ControlLeft: 'ctrl',
    ControlRight: 'ctrl',
    AltLeft: 'alt',
    AltRight: 'alt',
    ArrowUp: 'uparrow',
    ArrowDown: 'downarrow',
    ArrowLeft: 'leftarrow',
    ArrowRight: 'rightarrow',
    Insert: 'ins',
    Delete: 'del',
    Home: 'home',
    End: 'end',
    PageUp: 'pgup',
    PageDown: 'pgdn',
  }
  if (named[code]) return named[code]
  const fn = code.match(/^F(\d{1,2})$/)
  if (fn) return `f${fn[1].toLowerCase()}`
  return null
}

/** PointerEvent.button → GoldSrc mouse key name. */
export function mouseNameFromEvent(event: PointerEvent | MouseEvent): string | null {
  const names = ['mouse1', 'mouse3', 'mouse2', 'mouse4', 'mouse5']
  return names[event.button] ?? null
}

/** WheelEvent → 'mwheelup' | 'mwheeldown'. */
export function wheelNameFromEvent(event: WheelEvent): 'mwheelup' | 'mwheeldown' | null {
  if (Math.abs(event.deltaY) < 1 && Math.abs(event.deltaX) < 1) return null
  return (event.deltaY !== 0 ? event.deltaY : event.deltaX) < 0 ? 'mwheelup' : 'mwheeldown'
}

const FRIENDLY_KEYS: Record<string, string> = {
  mouse1: 'chuột trái',
  mouse2: 'chuột phải',
  mouse3: 'chuột giữa',
  mouse4: 'chuột 4',
  mouse5: 'chuột 5',
  mwheelup: 'lăn lên',
  mwheeldown: 'lăn xuống',
  space: 'space',
  shift: 'shift',
  ctrl: 'ctrl',
  alt: 'alt',
  tab: 'tab',
}

/** What the keycap shows: engine name for keys, friendly text for mouse. */
export function displayKey(key: string): string {
  return FRIENDLY_KEYS[key] ?? key
}

/** Push every pref into the engine through console commands. */
export function applyPrefs(execute: (command: string) => void, prefs: Prefs): void {
  for (const setting of NUMBER_SETTINGS) {
    execute(`${setting.cvar} ${prefs.numbers[setting.id]}`)
  }
  for (const setting of BOOL_SETTINGS) {
    execute(`${setting.cvar} ${prefs.bools[setting.id] ? setting.on : setting.off}`)
  }
  for (const [cmd, keys] of Object.entries(prefs.binds)) {
    for (const key of keys) execute(`bind ${key} "${cmd}"`)
  }
  // Gỡ các phím user chủ động bỏ — chạy SAU bind để "gỡ" thắng.
  for (const key of prefs.unbound) execute(`unbind ${key}`)
}
