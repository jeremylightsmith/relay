// Plain Enter submits the surrounding form; Shift+Enter falls through as a
// newline (RLY-51 owner-aware composer). Distinct from SubmitOnCmdEnter
// (⌘/Ctrl+Enter) — the board composer wants a bare Enter to hand work off.
const SubmitOnEnter = {
  mounted() {
    this.onKeydown = e => {
      if (e.key === "Enter" && !e.shiftKey && !e.metaKey && !e.ctrlKey) {
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

export default SubmitOnEnter
