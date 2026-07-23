// RLY-234 · ArrowKeyGuard — a capture-phase keydown guard that lets Left/Right
// arrow keys move the TEXT cursor (not the card) while the user is typing in the
// web board drawer. RLY-227 originally shipped touch-swipe card navigation here;
// RLY-234 removed the touch machinery (swipe is native-only now) and kept only
// this guard. The drawer's prev/next chevrons still carry the arrow-key
// `phx-window-keydown` bindings, so LiveView navigates cards on Left/Right
// globally — this hook stops that from firing when the user is typing in a field.
const ArrowKeyGuard = {
  mounted() {
    // Capture phase, before LiveView's own window listener runs.
    this.onKeydown = e => this.guardArrowKeys(e)
    window.addEventListener("keydown", this.onKeydown, true)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown, true)
  },

  guardArrowKeys(e) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return
    const t = e.target
    const tag = t && t.tagName
    const typing = tag === "INPUT" || tag === "TEXTAREA" || (t && t.isContentEditable)
    if (typing) e.stopImmediatePropagation() // let the cursor move, not the card
  },
}

export default ArrowKeyGuard
