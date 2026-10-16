// RE455 — the New board picker's Card key box. LiveView deliberately never patches a FOCUSED
// input's value (dom.js `mergeFocusedInput`), so the server's sanitized key
// (`Schemas.Board.key_from_name/1`) can't reach the box while the user types in it. This hook
// does the live filtering instead: upper-cased, A–Z only, at most 2. It rewrites the value in an
// `input` listener on the element itself, which runs before the event bubbles up to LiveView's
// form-level phx-change listener, so the server only ever sees the filtered key. No
// `phx-update="ignore"`: the server still sets the key it derives from the name while the user
// types there.
const MAX_LETTERS = 2

const lettersOnly = value => value.toUpperCase().replace(/[^A-Z]/g, "").slice(0, MAX_LETTERS)

const CardKeyInput = {
  mounted() {
    this.onInput = () => {
      const filtered = lettersOnly(this.el.value)
      if (filtered === this.el.value) return

      this.el.value = filtered
      this.el.setSelectionRange(filtered.length, filtered.length)
    }

    // `maxlength` truncates a paste before `input` fires ("a1c" would land as "a1" → "A"), so
    // filter the pasted text first and insert the result ourselves.
    this.onPaste = e => {
      const pasted = e.clipboardData?.getData("text") ?? ""
      e.preventDefault()

      const {selectionStart: start, selectionEnd: end, value} = this.el
      const filtered = lettersOnly(value.slice(0, start) + pasted + value.slice(end))

      this.el.value = filtered
      this.el.setSelectionRange(filtered.length, filtered.length)
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
    }

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("paste", this.onPaste)
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("paste", this.onPaste)
  },
}

export default CardKeyInput
