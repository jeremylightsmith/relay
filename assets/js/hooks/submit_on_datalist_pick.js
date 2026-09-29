// RE363 · SubmitOnDatalistPick — the drawer's Blocked by input is a plain `<input list=…>` whose
// form only persists on `phx-submit` (Enter). Picking a suggestion from the native datalist just
// filled the box, so it looked saved when it wasn't. This hook submits the form when an `input`
// event is a suggestion PICK and the value is exactly one of the datalist's options.
//
// It keys on the KIND of input event, not just the value: refs are prefixes of each other
// (RE1 / RE12), so "value matches an option" alone would submit RE1 mid-way through typing RE12.
// Keystroke edits (insertText, deleteContentBackward, insertFromPaste, …) are never picks.
// Chromium and Firefox report a pick as inputType "insertReplacementText"; WebKit fires a bare
// Event with no inputType.
//
// The server's add_dependency path is reused unchanged — success and inline-error rendering
// (cycle, self-reference, unknown ref) behave exactly as they do for Enter.
const isPick = e =>
  !(e instanceof InputEvent) || !e.inputType || e.inputType === "insertReplacementText"

const SubmitOnDatalistPick = {
  mounted() {
    this.onInput = e => {
      if (!isPick(e)) return

      const value = this.el.value.trim()
      // Read the options live from the DOM so they track re-renders of the datalist.
      const options = this.el.list ? Array.from(this.el.list.options, o => o.value) : []

      if (value !== "" && options.includes(value) && this.el.form) this.el.form.requestSubmit()
    }
    this.el.addEventListener("input", this.onInput)
    // LiveView leaves a focused input's value alone on patch, so the server's cleared
    // @dependency_input never reaches the box the user is still focused in.
    this.handleEvent("dependency_added", () => { this.el.value = "" })
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput)
  },
}

export default SubmitOnDatalistPick
