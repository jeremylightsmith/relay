// RE507 — hand-rolled HTML5 drag-and-drop for the drawer's Plan task list (ul#card-plan-tasks), in
// the style of board_dnd.js — no JS dependency. Delegated listeners on the list: a drag starts
// only from a row's ⠿ grip, the drop slot is the midpoint rule over the rows EXCLUDING the dragged
// one (the server's `to_position` is the final index), and a title double-click opens the editor.
// The hook never moves or removes rows — it only pushes `move_task` / `edit_task`, and the server
// re-renders. Everything is a no-op unless the list is editable (`data-editable="true"`: no
// running run, not archived).
//
// LiveView's window-level dragover handler also preventDefaults, so `drop` recomputes the slot
// from its own clientY instead of trusting the last dragover (story_map_dnd.js's note).
const ROW_SELECTOR = "li[data-task-id]"
const GRIP_SELECTOR = '[id$="-grip"], .task-grip'

const TaskListDnD = {
  mounted() {
    this.draggedEl = null

    this.el.addEventListener("dragstart", e => {
      if (!this.editable()) return
      const grip = e.target.closest && e.target.closest(GRIP_SELECTOR)
      const row = grip && grip.closest(ROW_SELECTOR)
      if (!row || !this.el.contains(row)) return
      this.draggedEl = row
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", row.dataset.taskId)
      e.dataTransfer.setDragImage(row, 12, 12)
      row.classList.add("dragging")
    })

    this.el.addEventListener("dragover", e => {
      if (!this.editable() || !this.draggedEl) return
      e.preventDefault() // required to allow the drop
      e.dataTransfer.dropEffect = "move"
      this.showPlaceholder(e.clientY)
    })

    this.el.addEventListener("dragleave", e => {
      if (!this.el.contains(e.relatedTarget)) this.clearPlaceholder()
    })

    this.el.addEventListener("drop", e => {
      if (!this.editable() || !this.draggedEl) return
      e.preventDefault()
      const id = parseInt(this.draggedEl.dataset.taskId, 10)
      const toPosition = this.dropIndex(e.clientY)
      this.clear()
      this.pushEvent("move_task", {id, to_position: toPosition})
    })

    this.el.addEventListener("dragend", () => this.clear())

    this.el.addEventListener("dblclick", e => {
      if (!this.editable()) return
      const title = e.target.closest && e.target.closest("[data-task-title]")
      const row = title && title.closest(ROW_SELECTOR)
      if (!row) return
      this.pushEvent("edit_task", {id: row.dataset.taskId})
    })
  },

  destroyed() {
    this.clearPlaceholder()
  },

  editable() {
    return this.el.dataset.editable === "true"
  },

  rows() {
    return Array.from(this.el.querySelectorAll(ROW_SELECTOR)).filter(el => el !== this.draggedEl)
  },

  // 0-based insertion index among the rows *excluding* the dragged one — the final position.
  dropIndex(y) {
    return this.rows().filter(el => {
      const rect = el.getBoundingClientRect()
      return y > rect.top + rect.height / 2
    }).length
  },

  // A thin line at the computed slot, tracking the cursor (board_dnd.js's showPlaceholder).
  showPlaceholder(y) {
    const placeholder = this.placeholder()
    const rows = this.rows()
    const before = rows[this.dropIndex(y)]
    if (before) {
      before.parentNode.insertBefore(placeholder, before)
    } else if (rows.length > 0) {
      rows[rows.length - 1].after(placeholder)
    }
  },

  placeholder() {
    if (!this._placeholder) {
      this._placeholder = document.createElement("li")
      this._placeholder.className = "drop-placeholder"
      this._placeholder.setAttribute("aria-hidden", "true")
    }
    return this._placeholder
  },

  clearPlaceholder() {
    if (this._placeholder && this._placeholder.parentNode) {
      this._placeholder.parentNode.removeChild(this._placeholder)
    }
  },

  clear() {
    if (this.draggedEl) this.draggedEl.classList.remove("dragging")
    this.draggedEl = null
    this.clearPlaceholder()
  },
}

export default TaskListDnD
