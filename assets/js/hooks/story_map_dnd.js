// RE262 — hand-rolled HTML5 drag-and-drop for the story map. A NEW hook rather than a change
// to BoardDnD: a board drop carries a stage id and draws a placeholder line into a stream list;
// a story-map drop targets a 2-D grid plus one tray and carries {ref, column, lane, index}.
// Generalising one hook to serve both would put the app's most-used interaction at risk to save
// ~60 lines.
//
// Delegated on the story-map viewport (#story-map), which contains BOTH the tray and the grid.
// The hook never mutates state beyond hover classes — the server owns placement and re-renders
// from assigns, which is what makes a second tab follow along for free. Dropping a card back
// where it already was is a no-op write that renders identically.
//
// RE261 adds a SECOND draggable kind — an activity band, a task column header or a release
// label — alongside cards. The two worlds are kept strictly apart by dropZone(): a card only
// ever targets a body cell or the tray, a header only ever targets another header. Anything
// else resolves to null, so nothing highlights, nothing preventDefaults, and the browser
// refuses the drop outright. The card drag is the shipped, most-used interaction on this page;
// it must not regress.
const CARD_SELECTOR = ".story-map-card[data-ref]"
const CELL_SELECTOR = ".story-map-drop"
const TRAY_SELECTOR = ".story-map-drop-tray"
const ZONE_SELECTOR = `${CELL_SELECTOR}, ${TRAY_SELECTOR}`
const HEADER_SELECTOR = ".story-map-header[data-kind][data-id]"
const HEADER_DROP_SELECTOR = ".story-map-header-drop[data-kind][data-id]"

const StoryMapDnD = {
  mounted() {
    this.dragged = null
    this.draggedEl = null

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
      this.clearDropTargets()
      this.dragged = null
      this.draggedEl = null
    })

    this.el.addEventListener("dragover", e => {
      const zone = this.dropZone(e.target)
      if (!zone) return
      e.preventDefault() // required to allow the drop
      e.dataTransfer.dropEffect = "move"
      this.clearDropTargets(zone)
      zone.classList.add("drag-over")
    })

    this.el.addEventListener("dragleave", e => {
      const zone = this.dropZone(e.target)
      if (zone && !zone.contains(e.relatedTarget)) zone.classList.remove("drag-over")
    })

    this.el.addEventListener("drop", e => {
      const zone = this.dropZone(e.target)
      if (!zone) return
      e.preventDefault()
      const dragged = this.dragged
      const index = dragged.type === "card" ? this.dropIndex(zone, e.clientY) : null
      this.clearDropTargets()
      this.dragged = null

      if (dragged.type === "header") {
        // Ids only — the SERVER computes the new order (StoryMap.insert_before/3).
        this.pushEvent("story_map_reorder", {
          kind: dragged.kind,
          id: dragged.id,
          target_kind: zone.dataset.kind,
          target_id: zone.dataset.id,
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
  },

  startDrag(e, el, dragged, payload) {
    this.dragged = dragged
    this.draggedEl = el
    e.dataTransfer.effectAllowed = "move"
    e.dataTransfer.setData("text/plain", payload)
    el.classList.add("dragging")
  },

  // The one rule that keeps the two drag worlds apart. Returns null when nothing is being
  // dragged, so a stray dragover from outside the hook never highlights anything.
  dropZone(target) {
    if (!this.dragged || !target.closest) return null
    const selector = this.dragged.type === "header" ? HEADER_DROP_SELECTOR : ZONE_SELECTOR
    return target.closest(selector)
  },

  // 0-based insertion index among the cell's OTHER cards — BoardDnD's midpoint rule, and the
  // same meaning of "index" Cards.move_card/3 and StoryMap.assign_card/2 both take. No
  // placeholder line is drawn: the artboard doesn't show one, the tinted cell is the whole
  // affordance.
  dropIndex(zone, y) {
    return Array.from(zone.querySelectorAll(CARD_SELECTOR))
      .filter(el => el !== this.draggedEl)
      .filter(el => {
        const rect = el.getBoundingClientRect()
        return y > rect.top + rect.height / 2
      }).length
  },

  clearDropTargets(except = null) {
    this.el.querySelectorAll(".drag-over").forEach(zone => {
      if (zone !== except) zone.classList.remove("drag-over")
    })
  },
}

export default StoryMapDnD
