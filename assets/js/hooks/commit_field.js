// Commit-field behaviour for the shared <.inline_field> / <.boxed_field>
// components (RLY-49 — replaces InlineEdit). One hook, attached per field,
// branching on data-field-role:
//
//   * "display" — the rest element of an inline / toggle-mode boxed field.
//     Enter/Space re-fires the element's declarative phx-click so the keyboard
//     opens the editor exactly like a click.
//   * "edit" — the <input>/<textarea>. With data-autofocus, on mount focus() and
//     drop the caret at the END (textarea also scrolls to bottom). data-commit
//     picks the submit chord ("enter" → plain Enter; "cmd-enter" → ⌘/Ctrl+Enter).
//     Escape cancels: preventDefault + stopPropagation (so an enclosing
//     phx-window-keydown="close_drawer" does not also fire), then clicks the
//     data-cancel-id button. With data-dirty-pill the field owns its own commit:
//     the floating pill stays hidden until the value differs from the mount
//     baseline, and re-baselines after each save.
const CommitField = {
  mounted() {
    const el = this.el

    if (el.dataset.fieldRole === "display") {
      this.onKeydown = e => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault()
          el.click()
        }
      }
      el.addEventListener("keydown", this.onKeydown)
      return
    }

    if (el.dataset.autofocus) {
      el.focus()
      const end = el.value.length
      el.setSelectionRange(end, end)
      if (el.tagName === "TEXTAREA") el.scrollTop = el.scrollHeight
    }

    const cmdOnly = el.dataset.commit === "cmd-enter"
    this.onKeydown = e => {
      const submit =
        e.key === "Enter" && (cmdOnly ? e.metaKey || e.ctrlKey : !e.shiftKey)
      if (submit) {
        e.preventDefault()
        if (el.form) el.form.requestSubmit()
      } else if (e.key === "Escape") {
        e.preventDefault()
        e.stopPropagation()
        const cancel = document.getElementById(el.dataset.cancelId)
        if (cancel) cancel.click()
      }
    }
    el.addEventListener("keydown", this.onKeydown)

    if (el.dataset.dirtyPill) {
      this.pill = document.getElementById(`${el.id.replace(/-input$/, "")}-pill`)
      this.baseline = el.defaultValue
      this.onInput = () => this.syncPill()
      el.addEventListener("input", this.onInput)
    }
  },

  updated() {
    if (this.el.dataset.dirtyPill) {
      this.baseline = this.el.defaultValue
      this.syncPill()
    }
  },

  syncPill() {
    if (this.pill) this.pill.classList.toggle("hidden", this.el.value === this.baseline)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    if (this.onInput) this.el.removeEventListener("input", this.onInput)
  },
}

export default CommitField
