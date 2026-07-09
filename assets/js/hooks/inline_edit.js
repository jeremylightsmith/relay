// Inline text-edit behaviour for the shared `<.editable_text>` component
// (RLY-5). One hook module, attached to two elements per field:
//
//   * the READ display (data-inline-role="display") — Enter/Space re-fires the
//     element's declarative phx-click, so keyboard opens the editor exactly like
//     a mouse click (keeping phx-value-* plumbing on the server side);
//   * the EDIT <input>/<textarea> (default role) — on mount it focuses the field
//     and drops the caret at the END of the text; ⌘/Ctrl+Enter submits the
//     surrounding form; Escape cancels the edit AND stops propagation so an
//     enclosing phx-window-keydown="close_drawer" does not also fire (the drawer
//     Escape bug this MMF fixes).
const InlineEdit = {
  mounted() {
    if (this.el.dataset.inlineRole === "display") {
      this.onKeydown = e => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault()
          this.el.click()
        }
      }
    } else {
      const el = this.el
      el.focus()
      const end = el.value.length
      el.setSelectionRange(end, end)
      if (el.tagName === "TEXTAREA") el.scrollTop = el.scrollHeight

      this.onKeydown = e => {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
          e.preventDefault()
          if (el.form) el.form.requestSubmit()
        } else if (e.key === "Escape") {
          e.preventDefault()
          e.stopPropagation()
          const cancel = document.getElementById(el.dataset.cancelId)
          if (cancel) cancel.click()
        }
      }
    }

    this.el.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
  },
}

export default InlineEdit
