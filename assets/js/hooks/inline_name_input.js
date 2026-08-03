// RE263 — the story map's inline create input (<.inline_name_input>). Enter commits and the
// input must come back EMPTY and still focused, so a whole backbone can be typed without ever
// touching the mouse.
//
// The server cannot do this alone: LiveView deliberately never patches a FOCUSED input's value
// (it would clobber active typing — see dom_patch.js `mergeFocusedInput`, and the same note in
// the CommitField hook). So BoardLive pushes "story_map_draft_cleared" after a create actually
// succeeds, and only then do we clear. Pushing on success only is what keeps the two other
// commit rules honest: a blank name and a changeset error both leave the text exactly as typed.
//
// `mounted()` also re-focuses after a create that rebuilds the input's surroundings (the empty
// panel becoming the grid destroys and recreates it, so LiveView's own post-submit focus
// restore has nothing left to restore to).
const InlineNameInput = {
  mounted() {
    this.el.focus()
    this.handleEvent("story_map_draft_cleared", () => {
      this.el.value = ""
      this.el.focus()
    })
  },
}

export default InlineNameInput
