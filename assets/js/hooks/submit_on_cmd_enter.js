// ⌘/Ctrl+Enter submits the surrounding form (RLY-5). Attached to the explicit-
// submit composer textareas (comment, answer, review-reject, send-back) so the
// "⌘+Enter commits text" reflex is universal. Unlike InlineEdit it does NOT
// focus, place the caret, or handle Escape.
const SubmitOnCmdEnter = {
  mounted() {
    this.onKeydown = e => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        if (this.el.form) this.el.form.requestSubmit()
      }
    }
    this.el.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
  },
}

export default SubmitOnCmdEnter
