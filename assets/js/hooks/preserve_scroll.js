// RE454 — keep a lane's scroll position across a card-move restream. LiveView owns all
// DOM content (no phx-update="ignore"); this hook only reads scrollTop and puts it back.
//
// Mounted on every lane scroll body in `stage_column/1`: the main lane's
// `#stage-col-<position>-scroll` and the sub-lane's `#sublane-<id>-cards`. A move
// (drop, "Move to…", a realtime card_moved, the RLY-217 stranded-move restream) resets
// the stage streams server-side (`reset: true`), and the browser clamps the lane's
// scrollTop to 0 while its cards are torn down and rebuilt.
//
// Why not just snapshot in `beforeUpdate`: LiveView removes a reset stream's children at
// the start of the patch, BEFORE morphdom walks the tree and calls any hook's
// `beforeUpdate` — so for a lane being reset, scrollTop already reads the clamped 0 there.
// Instead the hook remembers the last scrollTop the lane reported through its own
// `scroll` events, and refreshes it in `beforeUpdate` only while the lane still holds
// its cards (not being reset, so the read is true).
//
// Contract: scrollTop after a LiveView patch equals scrollTop before it (the browser
// clamps it if the lane genuinely got shorter). The restore is synchronous in
// `updated` — the same task as the patch, before the clamp's own scroll event fires
// and before LiveView dispatches pushed events — so a deliberate `scrollIntoView`
// (RE389) still runs after it and wins.
const CARD_SELECTOR = ".board-card"

const PreserveScroll = {
  mounted() {
    this.scrollTop = this.el.scrollTop
    this.el.addEventListener("scroll", () => { this.scrollTop = this.el.scrollTop }, {passive: true})
  },

  // A lane mid-reset has already lost its cards here, and its scrollTop may read the
  // clamped 0 — keep the remembered value. A lane that still holds its cards reads true,
  // so refresh from it: that catches a `scrollIntoView` (RE389) whose scroll event hasn't
  // fired yet when the next patch lands.
  beforeUpdate() {
    if (this.el.querySelector(CARD_SELECTOR)) this.scrollTop = this.el.scrollTop
  },

  updated() {
    if (this.el.scrollTop !== this.scrollTop) this.el.scrollTop = this.scrollTop
  },
}

export default PreserveScroll
