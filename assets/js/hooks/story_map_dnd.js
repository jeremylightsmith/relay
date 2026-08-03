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
const CARD_SELECTOR = ".story-map-card[data-ref]"
const CELL_SELECTOR = ".story-map-drop"
const TRAY_SELECTOR = ".story-map-drop-tray"
const ZONE_SELECTOR = `${CELL_SELECTOR}, ${TRAY_SELECTOR}`

const StoryMapDnD = {
  mounted() {
    this.draggedRef = null
    this.draggedEl = null

    this.el.addEventListener("dragstart", e => {
      const card = e.target.closest(CARD_SELECTOR)
      if (!card) return
      this.draggedRef = card.dataset.ref
      this.draggedEl = card
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", card.dataset.ref)
      card.classList.add("dragging")
    })

    this.el.addEventListener("dragend", e => {
      const card = e.target.closest(CARD_SELECTOR)
      if (card) card.classList.remove("dragging")
      this.clearDropTargets()
      this.draggedRef = null
      this.draggedEl = null
    })

    this.el.addEventListener("dragover", e => {
      const zone = e.target.closest(ZONE_SELECTOR)
      if (!zone || !this.draggedRef) return
      e.preventDefault() // required to allow the drop
      e.dataTransfer.dropEffect = "move"
      this.clearDropTargets(zone)
      zone.classList.add("drag-over")
    })

    this.el.addEventListener("dragleave", e => {
      const zone = e.target.closest(ZONE_SELECTOR)
      if (zone && !zone.contains(e.relatedTarget)) zone.classList.remove("drag-over")
    })

    this.el.addEventListener("drop", e => {
      const zone = e.target.closest(ZONE_SELECTOR)
      if (!zone || !this.draggedRef) return
      e.preventDefault()
      const ref = this.draggedRef
      const index = this.dropIndex(zone, e.clientY)
      this.clearDropTargets()
      if (zone.matches(TRAY_SELECTOR)) {
        this.pushEvent("unassign_card", {ref})
      } else {
        this.pushEvent("assign_card", {ref, column: zone.dataset.column, lane: zone.dataset.lane, index})
      }
    })
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
