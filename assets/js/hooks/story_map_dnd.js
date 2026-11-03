// RE262 — hand-rolled HTML5 drag-and-drop for the story map. A NEW hook rather than a change
// to BoardDnD: a board drop carries a stage id and draws a placeholder line into a stream list;
// a story-map drop targets a 2-D grid plus one tray and carries {ref, column, lane, index}.
// Generalising one hook to serve both would put the app's most-used interaction at risk to save
// ~60 lines.
//
// Delegated on the story-map viewport (#story-map), which contains BOTH the tray and the grid.
// The hook never mutates state beyond the drop line and the tray's hover class — the server owns
// placement and re-renders from assigns, which is what makes a second tab follow along for free.
// Dropping a card back where it already was is a no-op write that renders identically.
//
// RE261 adds a SECOND draggable kind — an activity band, a step column header or a release
// label — alongside cards. The two worlds are kept strictly apart by dropZone(): a card only
// ever targets a body cell or the tray, a header only ever targets another header. Anything
// else resolves to null, so nothing shows, the hook never preventDefaults, and drop() pushes
// nothing. (LiveView's own window-level dragover listener preventDefaults every dragover, so a
// drop CAN still fire there — which is why drop() recomputes the target rather than trusting
// the hover.) The card drag is the shipped, most-used interaction on this page; it must not
// regress.
//
// RE272 — the drop affordance is ONE 3px line (`.story-map-drop-line`, app.css) at the exact
// landing spot, replacing the cell tint and the header ring. It lives in the server-rendered
// `#story-map-drop-layer` (phx-update="ignore", 0x0 at the surface's content origin), OUTSIDE the
// grid, so it never reflows a cell, and is positioned in #story-map-grid's coordinates — the
// origin story_map_cursors.js measures from — so it scrolls with the map. dropTarget() computes
// {zone, side, index, line} for BOTH dragover (draw) and drop (push), so what you see is what
// you get. A header drop carries a side: the pointer's half of the hovered header (or, for an
// activity, of the whole activity) decides "before" or "after". A pair the server would ignore
// (a release against an activity or step, a header on itself) is no target at all.
//
// RE272 — edge autoscroll. While a story-map drag is active (`this.dragged`), every dragover
// records the pointer; within EDGE px of any edge of #story-map-surface — the scroller, not this
// hook's element — ONE guarded requestAnimationFrame loop scrolls the surface toward that edge,
// ramping linearly from ~0 at the band's inner edge to MAX_SCROLL_STEP at the surface edge, each
// axis independently (a corner scrolls both). It is the loop, not the dragover, that keeps
// scrolling: a real browser repeats dragover while the pointer is still, a synthetic one never
// does, and both feed the same single loop. Each step re-runs dropTarget() at the last pointer
// position, so the line follows whatever the scroll brings under the pointer. The loop stops
// when the pointer leaves the band (or the surface — the tray sits outside it), on drop, on
// dragend, and in destroyed(); at a scroll limit it just has nothing left to do.
const CARD_SELECTOR = ".story-map-card[data-ref]"
const CELL_SELECTOR = ".story-map-drop"
const TRAY_SELECTOR = ".story-map-drop-tray"
const ZONE_SELECTOR = `${CELL_SELECTOR}, ${TRAY_SELECTOR}`
const HEADER_SELECTOR = ".story-map-header[data-kind][data-id]"
const HEADER_DROP_SELECTOR = ".story-map-header-drop[data-kind][data-id]"
const GRID_ID = "story-map-grid"
const LAYER_ID = "story-map-drop-layer"
const LINE_CLASS = "story-map-drop-line"
const LANE_LABELS = `#${GRID_ID} [id^="story-map-release-"]`
const ACTIVITY_EXTENTS = `#${GRID_ID} [id^="story-map-activity-"], #${GRID_ID} [id^="story-map-stub-"]`
// The mockup's line geometry: 3px thick, centred on the boundary (`margin-left/top:-2px`), and a
// card line overhangs the cell's content box by 3px each side (`margin:1px -3px`).
const LINE_THICKNESS = 3
const LINE_CENTRE_OFFSET = 2
const CARD_LINE_OVERHANG = 3
const FALLBACK_CELL_GAP = 6
const SURFACE_ID = "story-map-surface"
// The edge band that autoscrolls, in px from each edge of the surface, and the fastest a frame
// scrolls (reached at the surface's very edge).
const EDGE = 48
const MAX_SCROLL_STEP = 16

const StoryMapDnD = {
  mounted() {
    this.dragged = null
    this.draggedEl = null
    this.pointer = null
    this.scrollFrame = null

    this.el.addEventListener("dragstart", e => {
      const card = e.target.closest(CARD_SELECTOR)
      if (card) return this.startDrag(e, card, {type: "card", ref: card.dataset.ref}, card.dataset.ref)

      const header = e.target.closest(HEADER_SELECTOR)
      if (!header) return
      const {kind, id} = header.dataset
      this.startDrag(e, header, {type: "header", kind, id}, `${kind}:${id}`)
    })

    this.el.addEventListener("dragend", () => {
      if (this.draggedEl) this.draggedEl.classList.remove("dragging")
      this.stopAutoscroll()
      this.hideLine()
      this.clearDropTargets()
      this.dragged = null
      this.draggedEl = null
    })

    this.el.addEventListener("dragover", e => {
      if (this.dragged) this.autoscroll(e.clientX, e.clientY)
      const target = this.dropTarget(e)
      if (!target) return this.hideLine()
      e.preventDefault() // required to allow the drop
      e.dataTransfer.dropEffect = "move"
      this.paint(target)
    })

    this.el.addEventListener("dragleave", e => {
      if (!this.el.contains(e.relatedTarget)) this.hideLine()
      const zone = this.dropZone(e.target)
      if (zone && zone.matches(TRAY_SELECTOR) && !zone.contains(e.relatedTarget)) {
        zone.classList.remove("drag-over")
      }
    })

    this.el.addEventListener("drop", e => {
      this.stopAutoscroll()
      const target = this.dropTarget(e)
      this.hideLine()
      if (!target) return
      e.preventDefault()
      const {zone, side, index} = target
      const dragged = this.dragged
      this.clearDropTargets()
      this.dragged = null

      if (dragged.type === "header") {
        // Ids and the side only — the SERVER computes the new order (StoryMap.insert_at/4).
        this.pushEvent("story_map_reorder", {
          kind: dragged.kind,
          id: dragged.id,
          target_kind: zone.dataset.kind,
          target_id: zone.dataset.id,
          side,
        })
      } else if (zone.matches(TRAY_SELECTOR)) {
        this.pushEvent("unassign_card", {ref: dragged.ref})
      } else {
        this.pushEvent("assign_card", {
          ref: dragged.ref,
          column: zone.dataset.column,
          lane: zone.dataset.lane,
          index,
        })
      }
    })

    // RE326 — BoardLive pushes `focus_card` when the drawer closes (and on a URL-driven switch
    // between two ?card= URLs), so keyboard focus lands back on the card you were viewing. It
    // mirrors BoardDnD's handler against this hook's own selector (RE262: the hooks stay split). A
    // card the map isn't rendering (filtered out, in a collapsed activity, outside focus mode, or in
    // a closed tray) is simply not found and nothing happens. Never un-hide it.
    this.handleEvent("focus_card", ({ref}) => {
      const card = this.el.querySelector(`${CARD_SELECTOR}[data-ref="${ref}"]`)
      if (!card) return
      card.scrollIntoView({block: "nearest"})
      card.focus()
    })

    // RE389 — BoardLive pushes `scroll_card` when a card opens from a closed drawer (a click, a
    // search result, a ?card= deep link). It only reveals the card: focus is NOT moved, because a
    // click already focused the card and a search or deep link must never steal keyboard focus.
    // A card this view isn't rendering is not found, and nothing happens.
    this.handleEvent("scroll_card", ({ref}) => {
      const card = this.el.querySelector(`${CARD_SELECTOR}[data-ref="${ref}"]`)
      if (!card) return
      card.scrollIntoView({block: "nearest"})
    })
  },

  destroyed() {
    this.stopAutoscroll()
  },

  startDrag(e, el, dragged, payload) {
    this.dragged = dragged
    this.draggedEl = el
    e.dataTransfer.effectAllowed = "move"
    e.dataTransfer.setData("text/plain", payload)
    el.classList.add("dragging")
  },

  // Draws a non-null dropTarget(): the tray keeps its own RE262 drop state; everything else is
  // the line.
  paint(target) {
    if (target.zone.matches(TRAY_SELECTOR)) {
      this.hideLine()
      target.zone.classList.add("drag-over")
    } else {
      this.clearDropTargets()
      this.showLine(target.line)
    }
  },

  // Records the pointer and starts the one scroll loop when it sits in the surface's edge band;
  // a pointer outside the band (or outside the surface) stops it.
  autoscroll(x, y) {
    this.pointer = {x, y}
    const surface = document.getElementById(SURFACE_ID)
    if (!surface || !this.scrollVelocity(surface)) return this.stopAutoscroll()
    if (this.scrollFrame) return
    this.scrollFrame = requestAnimationFrame(() => this.scrollStep())
  },

  scrollStep() {
    this.scrollFrame = null
    const surface = document.getElementById(SURFACE_ID)
    const velocity = this.dragged && surface && this.scrollVelocity(surface)
    if (!velocity) return

    const {scrollTop, scrollLeft} = surface
    surface.scrollTop += velocity.dy
    surface.scrollLeft += velocity.dx
    // At the scroll limit there is nothing left to do; a later dragover restarts the loop.
    if (surface.scrollTop === scrollTop && surface.scrollLeft === scrollLeft) return
    this.retarget()
    this.scrollFrame = requestAnimationFrame(() => this.scrollStep())
  },

  // {dx, dy} px for this frame from the last pointer, or null outside the band. Each axis ramps
  // linearly from 0 at the band's inner edge to MAX_SCROLL_STEP at the surface's edge.
  scrollVelocity(surface) {
    if (!this.pointer) return null
    const {x, y} = this.pointer
    const rect = surface.getBoundingClientRect()
    if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) return null

    const ramp = (low, high, at) => {
      if (at < low + EDGE) return -MAX_SCROLL_STEP * (1 - (at - low) / EDGE)
      if (at > high - EDGE) return MAX_SCROLL_STEP * (1 - (high - at) / EDGE)
      return 0
    }
    const dx = ramp(rect.left, rect.right, x)
    const dy = ramp(rect.top, rect.bottom, y)
    return dx || dy ? {dx, dy} : null
  },

  // After a scroll step the pointer is still but the map moved under it: re-run the same target
  // function at the last pointer position so the line tracks what is now under it.
  retarget() {
    const {x, y} = this.pointer
    const under = document.elementFromPoint(x, y)
    const target = under && this.dropTarget({target: under, clientX: x, clientY: y})
    if (target) this.paint(target)
    else this.hideLine()
  },

  stopAutoscroll() {
    if (this.scrollFrame) cancelAnimationFrame(this.scrollFrame)
    this.scrollFrame = null
    this.pointer = null
  },

  // The one rule that keeps the two drag worlds apart. Returns null when nothing is being
  // dragged, so a stray dragover from outside the hook never draws anything.
  dropZone(target) {
    if (!this.dragged || !target.closest) return null
    const selector = this.dragged.type === "header" ? HEADER_DROP_SELECTOR : ZONE_SELECTOR
    return target.closest(selector)
  },

  // Where a drop at this event would land: null (no line, no preventDefault, nothing pushed) or
  // {zone, side, index, line}. `line` is a grid-content box for showLine(), or null
  // for the tray, which keeps its own drop state.
  dropTarget(e) {
    const zone = this.dropZone(e.target)
    if (!zone) return null

    if (this.dragged.type === "header") return this.headerTarget(zone, e)
    if (zone.matches(TRAY_SELECTOR)) return {zone, side: null, index: null, line: null}

    const index = this.dropIndex(zone, e.clientY)
    const line = this.cardLine(zone, index)
    return line && {zone, side: null, index, line}
  },

  // A header drop. `zone` is the hovered header — always measured as a whole, never e.target,
  // which is whatever child (name, grip, ✕) the pointer is over.
  headerTarget(zone, e) {
    if (zone === this.draggedEl) return null // self-hover: the drop never fires
    const {kind, id} = this.dragged
    const targetKind = zone.dataset.kind
    const before = (rect, horizontal) =>
      horizontal ? e.clientX < rect.left + rect.width / 2 : e.clientY < rect.top + rect.height / 2

    if (kind === "release" || targetKind === "release") {
      if (kind !== targetKind) return null // a release only ever reorders against a release
      // The pointer's half of the LABEL picks the side (the label is the only drop zone, so a
      // half of the taller lane would leave "after" unreachable); the line sits on the LANE's edge.
      const side = before(zone.getBoundingClientRect(), false) ? "before" : "after"
      const lane = this.laneRect(zone)
      const line = this.releaseLine(side === "before" ? lane.top : lane.bottom)
      return line && {zone, side, index: null, line}
    }

    // An activity always lands against a whole activity: a step header resolves to its own.
    let extent = zone
    if (kind === "activity") {
      const activityId = targetKind === "activity" ? zone.dataset.id : zone.dataset.activityId
      if (activityId === id) return null // over itself, or one of its own steps
      extent =
        document.getElementById(`story-map-activity-${activityId}`) ||
        document.getElementById(`story-map-stub-${activityId}`)
      if (!extent) return null
    }

    const rect = extent.getBoundingClientRect()
    const side = before(rect, true) ? "before" : "after"
    const line = this.structuralLine(side === "before" ? rect.left : rect.right)
    return line && {zone, side, index: null, line}
  },

  // 0-based insertion index among the cell's OTHER cards — BoardDnD's midpoint rule, and the
  // same meaning of "index" Cards.move_card/3 and StoryMap.assign_card/2 both take. The line
  // cardLine/2 draws sits on exactly this boundary.
  dropIndex(zone, y) {
    return this.otherCards(zone).filter(el => {
      const rect = el.getBoundingClientRect()
      return y > rect.top + rect.height / 2
    }).length
  },

  otherCards(zone) {
    return Array.from(zone.querySelectorAll(CARD_SELECTOR)).filter(el => el !== this.draggedEl)
  },

  // A horizontal line across the cell's content box at the boundary for `index`: mid-gap between
  // two cards, half a gap outside the first or last, or the padding edge of an empty cell.
  cardLine(cell, index) {
    const origin = this.gridOrigin()
    if (!origin) return null
    const style = getComputedStyle(cell)
    const rect = cell.getBoundingClientRect()
    const gap = parseFloat(style.rowGap) || FALLBACK_CELL_GAP
    const cards = this.otherCards(cell).map(el => el.getBoundingClientRect())

    let y
    if (cards.length === 0) y = rect.top + parseFloat(style.paddingTop)
    else if (index === 0) y = cards[0].top - gap / 2
    else if (index >= cards.length) y = cards[cards.length - 1].bottom + gap / 2
    else y = (cards[index - 1].bottom + cards[index].top) / 2

    const left = rect.left + parseFloat(style.paddingLeft) - CARD_LINE_OVERHANG
    const right = rect.right - parseFloat(style.paddingRight) + CARD_LINE_OVERHANG
    return {
      orientation: "h",
      left: left - origin.left,
      top: y - origin.top - LINE_CENTRE_OFFSET,
      width: right - left,
      height: LINE_THICKNESS,
    }
  },

  // A step or activity boundary: vertical, from the grid's top to the last lane's bottom.
  structuralLine(x) {
    const origin = this.gridOrigin()
    const labels = document.querySelectorAll(LANE_LABELS)
    if (!origin || labels.length === 0) return null
    return {
      orientation: "v",
      left: x - origin.left - LINE_CENTRE_OFFSET,
      top: 0,
      width: LINE_THICKNESS,
      height: this.laneRect(labels[labels.length - 1]).bottom - origin.top,
    }
  },

  // A lane's real vertical extent. The grid is `align-items:start`, so a release label is only as
  // tall as its text while its row is as tall as the row's tallest cell: the lane spans from the
  // label's top to the lowest bottom among the label and that lane's cells (`data-lane`).
  laneRect(label) {
    const rect = label.getBoundingClientRect()
    const lane = label.dataset.lane
    const cells = lane ? document.querySelectorAll(`#${GRID_ID} ${CELL_SELECTOR}[data-lane="${CSS.escape(lane)}"]`) : []
    const bottom = Array.from(cells).reduce((max, el) => Math.max(max, el.getBoundingClientRect().bottom), rect.bottom)
    return {top: rect.top, bottom}
  },

  // A release boundary: horizontal, from the grid's left to the map's right edge (the rightmost
  // activity band or collapsed stub).
  releaseLine(y) {
    const origin = this.gridOrigin()
    const extents = Array.from(document.querySelectorAll(ACTIVITY_EXTENTS))
    if (!origin || extents.length === 0) return null
    const right = Math.max(...extents.map(el => el.getBoundingClientRect().right))
    return {
      orientation: "h",
      left: 0,
      top: y - origin.top - LINE_CENTRE_OFFSET,
      width: right - origin.left,
      height: LINE_THICKNESS,
    }
  },

  // #story-map-grid's viewport origin — the drop layer's content origin. Null on an empty board,
  // which renders no grid, so every geometry read no-ops there.
  gridOrigin() {
    const grid = document.getElementById(GRID_ID)
    return grid && grid.getBoundingClientRect()
  },

  // The layer is phx-update="ignore", so the one line survives every patch — and a remount of
  // this hook, which is why it is looked up in the layer rather than cached on `this`.
  showLine({orientation, left, top, width, height}) {
    const layer = document.getElementById(LAYER_ID)
    if (!layer) return
    let line = layer.querySelector(`.${LINE_CLASS}`)
    if (!line) {
      line = document.createElement("div")
      layer.appendChild(line)
    }
    line.className = `${LINE_CLASS} ${LINE_CLASS}--${orientation}`
    Object.assign(line.style, {left: `${left}px`, top: `${top}px`, width: `${width}px`, height: `${height}px`})
    line.hidden = false
  },

  hideLine() {
    const line = document.querySelector(`#${LAYER_ID} .${LINE_CLASS}`)
    if (line) line.hidden = true
  },

  // Only the tray carries a hover class now (RE272 replaced the cell tint and header ring).
  clearDropTargets() {
    this.el.querySelectorAll(".drag-over").forEach(zone => zone.classList.remove("drag-over"))
  },
}

export default StoryMapDnD
