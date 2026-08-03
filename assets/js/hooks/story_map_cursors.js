// RE257 — live cursors on the story map.
//
// Cursors are CLIENT-rendered, never LiveView assigns. At ~20 messages/second/user, driving
// cursor positions through assigns would re-render and diff the whole map on every mouse move.
// The server relays with push_event/3 — which sends no template diff — and this hook owns every
// node inside #story-map-cursor-layer, which carries phx-update="ignore". The server holds NO
// cursor state at all.
//
// COORDINATE SPACE: raw pixels in the map's scrollable CONTENT space,
// x = clientX - #story-map-grid's rect left. The grid's geometry is a pure function of the
// structure data, the cards and the (shared) view settings, so window size and scroll change
// only what you can SEE, never where anything IS. The layer sits at the content origin, so one
// viewer's raw pixel lands on the same card for every other viewer — safe only BECAUSE map view
// settings are shared board-wide (Relay.StoryMap.view/1). The UNMAPPED tray is a flex sibling
// outside the scroll container, so its width never shifts map coordinates either.
//
// KNOWN RESIDUAL DRIFT, ACCEPTED: a viewer with an inline draft or composer open has slightly
// different geometry (the add-activity column widens 58px -> 156px; an open composer adds height
// to one row), so their cursor is a little off for others while they type. Transient,
// self-inflicted, and cheaper to live with than cell anchoring.
//
// Deliberately NOT copied from the artboard: its decorative CSS keyframe animations, which
// exist only to make the static mockup look alive. The only animation here is an 80ms linear
// transition that smooths the 20Hz stream.
const PUSH_FLOOR_MS = 50
const SWEEP_MS = 1000
const STALE_MS = 5000
const SURFACE_ID = "story-map-surface"
const GRID_ID = "story-map-grid"

// docs/designs/Relay Story Map.dc.html, showPresence, lines 117-123. No user data is
// interpolated: the name goes in via textContent and the colour via setAttribute/style.
const CURSOR_HTML = `
  <svg width="16" height="16" viewBox="0 0 16 16">
    <path d="M1 1 L1 12 L4 9 L6.5 14 L8.5 13 L6 8 L10 8 Z" stroke="white" stroke-width="1"></path>
  </svg>
  <span style="position:absolute;left:14px;top:12px;color:white;font-family:var(--font-mono);font-size:9.5px;font-weight:600;padding:2px 6px;border-radius:5px;white-space:nowrap;"></span>
`

const StoryMapCursors = {
  mounted() {
    this.cursors = new Map()
    this.pending = null
    this.frame = null
    this.lastPush = 0

    this.onMove = e => this.queue(e)
    this.onLeave = () => this.leave()
    this.onVisibility = () => { if (document.visibilityState === "hidden") this.leave() }

    const surface = document.getElementById(SURFACE_ID)
    if (surface) {
      surface.addEventListener("pointermove", this.onMove)
      surface.addEventListener("pointerleave", this.onLeave)
    }
    document.addEventListener("visibilitychange", this.onVisibility)
    window.addEventListener("phx:disconnected", this.onLeave)

    this.handleEvent("story_map_cursor", ({user_id, name, color, x, y}) => {
      this.upsert(user_id, name, color, x, y)
    })
    this.handleEvent("story_map_cursor_gone", ({user_id}) => this.remove(user_id))

    // A hard-crashed tab's leave message can be missed; nothing unheard-from for 5s stays on
    // screen.
    this.sweep = setInterval(() => {
      const cutoff = Date.now() - STALE_MS
      for (const [id, cursor] of this.cursors) {
        if (cursor.seen < cutoff) this.remove(id)
      }
    }, SWEEP_MS)
  },

  destroyed() {
    clearInterval(this.sweep)
    if (this.frame) cancelAnimationFrame(this.frame)
    const surface = document.getElementById(SURFACE_ID)
    if (surface) {
      surface.removeEventListener("pointermove", this.onMove)
      surface.removeEventListener("pointerleave", this.onLeave)
    }
    document.removeEventListener("visibilitychange", this.onVisibility)
    window.removeEventListener("phx:disconnected", this.onLeave)
  },

  queue(e) {
    const grid = document.getElementById(GRID_ID)
    if (!grid) return // an empty board has no map to point at
    const rect = grid.getBoundingClientRect()
    this.pending = {x: Math.round(e.clientX - rect.left), y: Math.round(e.clientY - rect.top)}
    this.schedule()
  },

  // requestAnimationFrame-coalesced with a 50ms floor between pushes (<=20/s). Re-scheduling
  // rather than dropping inside the floor means the LAST position before the pointer stops is
  // still delivered, one frame later.
  schedule() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      if (!this.pending) return
      if (Date.now() - this.lastPush < PUSH_FLOOR_MS) return this.schedule()
      this.lastPush = Date.now()
      this.pushEvent("cursor_moved", this.pending)
      this.pending = null
    })
  },

  leave() {
    this.pending = null
    this.pushEvent("cursor_left", {})
  },

  upsert(userId, name, color, x, y) {
    let cursor = this.cursors.get(userId)

    if (!cursor) {
      const node = document.createElement("div")
      node.id = `story-map-cursor-${userId}`
      node.style.cssText =
        "position:absolute;z-index:40;pointer-events:none;transition:left 80ms linear, top 80ms linear;"
      node.innerHTML = CURSOR_HTML
      this.el.appendChild(node)
      cursor = {node, path: node.querySelector("path"), label: node.querySelector("span"), seen: 0}
      this.cursors.set(userId, cursor)
    }

    cursor.path.setAttribute("fill", color)
    cursor.label.style.background = color
    cursor.label.textContent = name || ""
    cursor.node.style.left = `${x}px`
    cursor.node.style.top = `${y}px`
    cursor.seen = Date.now()
  },

  remove(userId) {
    const cursor = this.cursors.get(userId)
    if (!cursor) return
    cursor.node.remove()
    this.cursors.delete(userId)
  },
}

export default StoryMapCursors
