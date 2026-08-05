// RE268 · TypingKeyGuard — a capture-phase keydown guard for single-letter shortcuts bound with
// `phx-window-keydown`. LiveView's window bindings fire regardless of focus, so `t` (open Talk)
// would swallow the `t` in "throughput" typed into any drawer field. Sibling of ArrowKeyGuard,
// which does the same for Left/Right; kept separate because that hook is mounted only when
// card navigation is on, and this guard must apply on every drawer.
//
// Guarded keys are declared on the element as `data-guard-keys="t"` (comma-separated).
const TypingKeyGuard = {
  mounted() {
    this.keys = (this.el.dataset.guardKeys || "").split(",").filter(Boolean)
    this.onKeydown = e => {
      if (!this.keys.includes(e.key)) return
      const t = e.target
      const tag = t && t.tagName
      if (tag === "INPUT" || tag === "TEXTAREA" || (t && t.isContentEditable)) {
        e.stopImmediatePropagation() // let the letter land in the field, not switch tabs
      }
    }
    window.addEventListener("keydown", this.onKeydown, true)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown, true)
  },
}

export default TypingKeyGuard
