// RE198 — the board header's card search box. Escape (and opening a result) empties the search
// on the server, but LiveView deliberately never patches a FOCUSED input's value (it would
// clobber active typing — see dom.js `mergeFocusedInput`, and the same note on InlineNameInput
// and CommitField). Escape leaves the cursor right there in the box, so without this the
// popover would vanish while the typed text stayed on screen. BoardLive pushes
// "board_search_cleared" whenever the query actually goes from something to nothing; only then
// do we empty the box, so a normal keystroke never fights the user's typing.
const BoardSearchInput = {
  mounted() {
    this.handleEvent("board_search_cleared", () => {
      this.el.value = ""
    })
  },
}

export default BoardSearchInput
