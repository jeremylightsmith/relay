// RE459 — fade the flow-editor inspector's prompt preview only when it actually overflows.
// The clamp (`.prompt-preview`, max-height in app.css) can't be predicted server-side: a
// prompt's wrapped height in the 328px inspector depends on line length, not line count.
// This hook only toggles `data-overflow`, which the `.prompt-preview[data-overflow]` mask
// keys on; LiveView owns the content, so no phx-update="ignore".
const PromptClamp = {
  mounted() { this.measure() },
  updated() { this.measure() },

  measure() {
    if (this.el.scrollHeight > this.el.clientHeight + 1) {
      this.el.setAttribute("data-overflow", "")
    } else {
      this.el.removeAttribute("data-overflow")
    }
  },
}

export default PromptClamp
