// RE268 · TypingKeyGuard — a capture-phase keydown guard for single-letter shortcuts bound with
// `phx-window-keydown`. LiveView's window bindings fire regardless of focus, so `t` (open Talk)
// would swallow the `t` in "throughput" typed into any drawer field.
//
// Also mounted as `ArrowKeyGuard` (RLY-234, app.js): that hook did the identical
// capture-phase/INPUT-TEXTAREA/isContentEditable dance hardcoded to Left/Right, so it now reuses
// this implementation via `data-guard-keys="ArrowLeft,ArrowRight"` instead of carrying its own
// copy. The two mount points stay separate (ArrowKeyGuard only when card nav is on, TypingKeyGuard
// on every drawer) — only the JS body was duplicated, and that's what's gone.
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
