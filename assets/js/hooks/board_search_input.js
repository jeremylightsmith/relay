// RE198 — the board header's card search box. Escape (and opening a result) empties the search
// on the server, but LiveView deliberately never patches a FOCUSED input's value (it would
// clobber active typing — see dom.js `mergeFocusedInput`, and the same note on InlineNameInput
// and CommitField). Escape leaves the cursor right there in the box, so without this the
// popover would vanish while the typed text stayed on screen. BoardLive pushes
// "board_search_cleared" whenever the query actually goes from something to nothing; only then
// do we empty the box, so a normal keystroke never fights the user's typing.
//
// RE342 — `/` anywhere on the page focuses this box (the GitHub/Slack convention). It is a window
// listener here rather than `phx-window-keydown` + `JS.focus` because it must stand down in every
// case below, and a declarative binding can express none of them. Living in this hook means the
// shortcut exists exactly where the box does (board + story map; not the storybook page).
const FOCUS_KEY = "/"

const isEditable = el =>
  !!el &&
  (el.tagName === "INPUT" ||
    el.tagName === "TEXTAREA" ||
    el.tagName === "SELECT" ||
    el.isContentEditable)

const BoardSearchInput = {
  mounted() {
    this.handleEvent("board_search_cleared", () => {
      this.el.value = ""
    })

    this.onShortcutKeydown = e => {
      if (e.key !== FOCUS_KEY || e.isComposing) return
      // ⌘/ and friends belong to the browser/OS. Shift is not checked: the match is on the
      // produced character, so layouts that need Shift to type `/` still work.
      if (e.ctrlKey || e.metaKey || e.altKey) return
      // `a/b` typed into a card title, the comment composer, or this box is a literal slash.
      if (isEditable(e.target)) return
      // The drawer is an overlay over the board; focusing a control underneath it would strand
      // focus behind the overlay. card_drawer/1 is only rendered while a card is open.
      if (document.getElementById("card-drawer")) return
      // `hidden lg:block` (board) / `hidden xl:block` (story map): below those widths the box is
      // not shown, so leave the key alone rather than swallow it.
      if (this.el.offsetParent === null) return

      e.preventDefault()
      this.el.focus()
      this.el.select()
    }

    window.addEventListener("keydown", this.onShortcutKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onShortcutKeydown)
  },
}

export default BoardSearchInput
