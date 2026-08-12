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
//
// RE306 — the matching below MUST be identical to LiveView's own `phx-key` matching
// (`live_socket.js`: `matchKey.toLowerCase() !== e.key.toLowerCase()`). It used to be an exact,
// case-SENSITIVE match on the raw `e.key`, so Shift+T walked straight past this guard, LiveView
// matched it anyway and pushed `talk_shortcut` with `%{"key" => "T"}` — crashing BoardLive and
// remounting the whole board mid-sentence. A guard that re-derives the framework's key matching
// by hand and gets it 95% right is a hole, and the divergence is invisible until someone types a
// capital.
const TypingKeyGuard = {
  mounted() {
    this.keys = (this.el.dataset.guardKeys || "")
      .split(",")
      .filter(Boolean)
      .map(key => key.toLowerCase())

    this.onKeydown = e => {
      // Chrome's autocomplete fires a keydown with no `key` at all; LiveView guards this too.
      const key = e.key && e.key.toLowerCase()
      if (!key || !this.keys.includes(key)) return

      // ⌘T / Ctrl+T is "new browser tab" and ⌥← / ⌘← is caret motion — a chord belongs to the
      // browser, never to a single-letter app shortcut, so swallow it wherever focus is. Shift is
      // deliberately absent: it is how you type a capital, and the case-folded match above plus
      // the field check below already cover Shift+T.
      if (e.ctrlKey || e.metaKey || e.altKey) {
        e.stopImmediatePropagation()
        return
      }

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
