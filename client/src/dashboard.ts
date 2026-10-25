import './style.css'
import './dashboard.css'

interface Room {
  id: string
  name: string
  map: string
  maxplayers: number
  hasPassword: boolean
  bots: number
  players: number
  humans: number
}

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id)
  if (!el) throw new Error(`Thiếu phần tử #${id}`)
  return el as T
}

const roomsEl = $<HTMLElement>('rooms')
const roomsCount = $<HTMLElement>('rooms-count')
const nickInput = $<HTMLInputElement>('nick')
const mapSelect = $<HTMLSelectElement>('room-map')

const STORE_NICK = 'webcs.nick'

function myRooms(): Record<string, string> {
  // Token chủ phòng lưu per-key: `webcs.owner.<id>` (trang play đọc cùng key).
  const owners: Record<string, string> = {}
  for (let i = 0; i < localStorage.length; i += 1) {
    const key = localStorage.key(i)
    const match = key?.match(/^webcs\.owner\.([\w-]+)$/)
    if (key && match) owners[match[1]] = localStorage.getItem(key) ?? ''
  }
  return owners
}

function rememberOwner(id: string, token: string): void {
  localStorage.setItem(`webcs.owner.${id}`, token)
}

async function api<T>(path: string, body?: unknown): Promise<T> {
  const owners = myRooms()
  const roomId = path.startsWith('/api/rooms/') ? path.split('/')[3] : ''
  const response = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      'content-type': 'application/json',
      ...(roomId && owners[roomId] ? { 'x-room-token': owners[roomId] } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const json = (await response.json().catch(() => ({}))) as T & { error?: string }
  if (!response.ok) throw new Error(json.error ?? `HTTP ${response.status}`)
  return json
}

async function refreshRooms(): Promise<void> {
  try {
    const { rooms } = await api<{ rooms: Room[] }>('/api/rooms')
    renderRooms(rooms)
  } catch (error) {
    roomsEl.innerHTML = `<div class="empty-state is-offline">Lỗi kết nối server: ${String(error)}</div>`
  }
}

function mapPrefix(map: string): string {
  return map.split(/[_.]/)[0].toLowerCase()
}

function renderRooms(rooms: Room[]): void {
  const owners = myRooms()
  const rows: HTMLElement[] = []

  if (!rooms.length) {
    const empty = document.createElement('div')
    empty.className = 'empty-state'
    empty.innerHTML =
      '<b>Chưa có phòng nào.</b><br />Tạo phòng ở bên phải — cả team chỉ cần bấm vào là chơi.'
    rows.push(empty)
  }

  for (const room of rooms) {
    const mine = Boolean(owners[room.id])
    const live = room.players > 0
    const prefix = mapPrefix(room.map)

    const card = document.createElement('article')
    card.className = 'room-card' + (mine ? ' mine' : '') + (live ? ' live' : '')

    const tile = document.createElement('div')
    tile.className = `room-tile tile-${prefix}`
    tile.textContent = prefix.toUpperCase()

    const body = document.createElement('div')
    body.className = 'room-body'

    const title = document.createElement('div')
    title.className = 'room-title'
    title.append(document.createTextNode(room.name))
    if (mine) {
      const badge = document.createElement('span')
      badge.className = 'badge badge--mine'
      badge.textContent = 'của bạn'
      title.append(badge)
    }
    if (room.hasPassword) {
      const lock = document.createElement('span')
      lock.className = 'badge badge--lock'
      lock.textContent = '🔒'
      title.append(lock)
    }

    const meta = document.createElement('div')
    meta.className = 'room-meta'
    meta.textContent =
      `${room.map} · ${room.players}/${room.maxplayers} người` + (room.bots ? ` · ${room.bots} bots` : '')

    const status = document.createElement('div')
    status.className = 'room-status'
    status.innerHTML = live
      ? '<span class="dot dot--live"></span> đang có người chơi'
      : '<span class="dot"></span> đang trống'

    body.append(title, meta, status)

    const join = document.createElement('button')
    join.type = 'button'
    join.className = 'btn btn--primary join-btn'
    join.textContent = 'Vào →'
    join.addEventListener('click', () => {
      localStorage.setItem(STORE_NICK, nickInput?.value.trim() || localStorage.getItem(STORE_NICK) || 'player')
      location.href = `/play.html?room=${encodeURIComponent(room.id)}`
    })

    card.append(tile, body, join)
    rows.push(card)
  }

  // Build xong rồi thay một lần: hai lần refresh chạy chồng nhau không nhân đôi.
  roomsEl.replaceChildren(...rows)
  roomsCount.textContent = `${rooms.length} phòng`
}

async function loadMaps(): Promise<void> {
  try {
    const { maps } = await api<{ maps: string[] }>('/api/maps')
    mapSelect.innerHTML = ''
    for (const map of maps) {
      const option = document.createElement('option')
      option.value = map
      option.textContent = map
      mapSelect.append(option)
    }
    if (maps.includes('de_dust2')) mapSelect.value = 'de_dust2'
  } catch (error) {
    mapSelect.innerHTML = `<option value="de_dust2">de_dust2 (lỗi nạp danh sách: ${String(error)})</option>`
  }
}

async function createRoom(): Promise<void> {
  const button = $<HTMLButtonElement>('btn-create')
  const name = ($<HTMLInputElement>('room-name').value || '').trim()
  button.disabled = true
  button.textContent = 'Đang tạo…'
  try {
    const created = await api<Room & { ownerToken: string }>('/api/rooms', {
      name,
      map: mapSelect.value,
      maxplayers: Number($<HTMLInputElement>('room-max').value) || 16,
      password: $<HTMLInputElement>('room-password').value.trim(),
      bots: Number($<HTMLInputElement>('room-bots').value) || 0,
    })
    if (created.id && created.ownerToken) rememberOwner(created.id, created.ownerToken)
    location.href = `/play.html?room=${encodeURIComponent(created.id)}`
  } catch (error) {
    button.disabled = false
    button.textContent = 'Tạo phòng'
    alert(`Không tạo được phòng: ${String(error)}`)
  }
}

function main(): void {
  const nick = localStorage.getItem(STORE_NICK)
  if (nick) nickInput.value = nick
  nickInput.addEventListener('input', () => {
    localStorage.setItem(STORE_NICK, nickInput.value.trim())
  })

  void loadMaps()
  void refreshRooms()
  window.setInterval(() => void refreshRooms(), 5000)
  $<HTMLButtonElement>('btn-refresh').addEventListener('click', () => void refreshRooms())
  $<HTMLButtonElement>('btn-create').addEventListener('click', () => void createRoom())
  $<HTMLButtonElement>('btn-log-close').addEventListener('click', () => {
    $<HTMLElement>('logpanel').hidden = true
  })
}

main()
