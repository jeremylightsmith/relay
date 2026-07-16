// Hand-rolled HTML5 drag-and-drop for board cards (MMF 05) — no JS
// dependency. One delegated hook on #board: dragstart/dragend bubble up
// from .board-card, dragover/drop from the .stage-drop zones (RLY-116:
// the zone wraps the .stage-cards stream list; cards may be grandchildren).
// The hook never mutates the card lists — it only pushes "move_card" with
// what was dropped where; the server owns all state and re-streams.
const CARD_SELECTOR = ".board-card"
const ZONE_SELECTOR = ".stage-drop"

const BoardDnD = {
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
      this.clearPlaceholder()
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
      this.showPlaceholder(zone, e.clientY)
    })

    this.el.addEventListener("dragleave", e => {
      const zone = e.target.closest(ZONE_SELECTOR)
      if (zone && !zone.contains(e.relatedTarget)) {
        zone.classList.remove("drag-over")
        this.clearPlaceholder()
      }
    })

    this.el.addEventListener("drop", e => {
      const zone = e.target.closest(ZONE_SELECTOR)
      if (!zone || !this.draggedRef) return
      e.preventDefault()
      this.clearPlaceholder()
      this.pushEvent("move_card", {
        ref: this.draggedRef,
        stage_id: zone.dataset.stageId,
        index: this.dropIndex(zone, e.clientY),
      })
      this.clearDropTargets()
    })

    this.handleEvent("focus_card", ({ref}) => {
      const card = this.el.querySelector(`${CARD_SELECTOR}[data-ref="${ref}"]`)
      if (!card) return
      card.scrollIntoView({block: "nearest"})
      card.focus()
    })
  },

  // 0-based insertion index among the zone's cards *excluding* the
  // dragged card — mirroring the server's ordered "other cards" list.
  dropIndex(zone, y) {
    const cards = Array.from(zone.querySelectorAll(CARD_SELECTOR))
      .filter(el => el !== this.draggedEl)
    return cards.filter(el => {
      const rect = el.getBoundingClientRect()
      return y > rect.top + rect.height / 2
    }).length
  },

  clearDropTargets(except = null) {
    this.el.querySelectorAll(`${ZONE_SELECTOR}.drag-over`).forEach(zone => {
      if (zone !== except) zone.classList.remove("drag-over")
    })
  },

  // Insert a thin line at the computed drop slot, tracking the cursor. Uses the
  // same midpoint rule as dropIndex, excluding the dragged card and the placeholder.
  // Cards live in the .stage-cards list *inside* the zone (RLY-116), so insertion
  // targets the card's own parent, never the zone itself, except when empty.
  showPlaceholder(zone, y) {
    const placeholder = this.placeholder()
    const cards = Array.from(zone.querySelectorAll(CARD_SELECTOR))
      .filter(el => el !== this.draggedEl)
    const index = cards.filter(el => {
      const rect = el.getBoundingClientRect()
      return y > rect.top + rect.height / 2
    }).length
    const before = cards[index]
    if (before) {
      before.parentNode.insertBefore(placeholder, before)
    } else if (cards.length > 0) {
      cards[cards.length - 1].after(placeholder)
    } else {
      const list = zone.querySelector(".stage-cards") || zone
      list.appendChild(placeholder)
    }
  },

  placeholder() {
    if (!this._placeholder) {
      this._placeholder = document.createElement("div")
      this._placeholder.className = "drop-placeholder"
    }
    return this._placeholder
  },

  clearPlaceholder() {
    if (this._placeholder && this._placeholder.parentNode) {
      this._placeholder.parentNode.removeChild(this._placeholder)
    }
  },
}

export default BoardDnD
