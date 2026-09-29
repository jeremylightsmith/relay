// ⌘/Ctrl+Enter submits the surrounding form (RLY-5). Attached to the explicit-
// submit composer textareas (comment, answer, review-reject, send-back) so the
// "⌘+Enter commits text" reflex is universal. Unlike InlineEdit it does NOT
// focus, place the caret, or handle Escape.
//
// RE323 — the needs-input stepper reuses one textarea for every question, and
// LiveView never overwrites a focused input's value, so after ⌘+Enter advances
// to the next question the box would still hold the previous answer (and the
// next ⌘+Enter would send it again). A textarea that opts in with `data-step`
// and `data-value` takes the server's text for the new step whenever its step
// changes. Composers without `data-step` are untouched.
const SubmitOnCmdEnter = {
  mounted() {
    this.step = this.el.dataset.step
    this.onKeydown = e => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        if (this.el.form) this.el.form.requestSubmit()
      }
    }
    this.el.addEventListener("keydown", this.onKeydown)
  },

  updated() {
    const step = this.el.dataset.step
    if (step === undefined || step === this.step) return
    this.step = step
    this.el.value = this.el.dataset.value || ""
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
  },
}

export default SubmitOnCmdEnter
