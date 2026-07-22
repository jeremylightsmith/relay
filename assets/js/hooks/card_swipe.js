// RLY-227 · CardSwipe — touch swipe + keyboard-arrow stepping between cards in
// the web board drawer. Mounted on the drawer panel only when swipe is enabled
// (web board, non-embed). LiveView owns DOM content; this hook only reads the
// has-prev/has-next data attributes, animates the panel's transform, and drives
// navigation by CLICKING the existing prev/next chevrons — so the server stays
// the single source of neighbor + stop-at-ends logic.
const COMMIT_FRACTION = 0.25 // commit past 25% of the panel width
const SLIDE_MS = 180

const CardSwipe = {
  mounted() {
    this.panel = this.el
    this.startX = 0
    this.startY = 0
    this.dx = 0
    this.dragging = false
    this.pendingDir = null
    this.reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    this.onTouchStart = e => this.touchStart(e)
    this.onTouchMove = e => this.touchMove(e)
    this.onTouchEnd = () => this.touchEnd()
    this.panel.addEventListener("touchstart", this.onTouchStart, {passive: true})
    this.panel.addEventListener("touchmove", this.onTouchMove, {passive: false})
    this.panel.addEventListener("touchend", this.onTouchEnd)

    // The chevrons carry phx-window-keydown for the arrow keys, so LiveView
    // navigates on left/right globally. Block that (capture phase, before
    // LiveView's own window listener runs) whenever the user is typing in a
    // field, so the arrows move the text cursor instead of the card.
    this.onKeydown = e => this.guardArrowKeys(e)
    window.addEventListener("keydown", this.onKeydown, true)
  },

  // The drawer re-renders in place on navigation (same #card-drawer-panel id),
  // so `updated` runs instead of a fresh mount. Play the slide-in for the just-
  // patched card, or clear any stale drag transform otherwise.
  updated() {
    const dir = this.pendingDir
    this.pendingDir = null
    if (!dir || this.reduceMotion) return this.reset()

    const width = this.panel.offsetWidth
    // New card starts off-screen on the side the swipe came from, then settles.
    this.panel.style.transition = "none"
    this.panel.style.transform = `translateX(${dir === "next" ? width : -width}px)`
    requestAnimationFrame(() => {
      this.panel.style.transition = `transform ${SLIDE_MS}ms ease-out`
      this.panel.style.transform = "translateX(0)"
    })
  },

  destroyed() {
    this.panel.removeEventListener("touchstart", this.onTouchStart)
    this.panel.removeEventListener("touchmove", this.onTouchMove)
    this.panel.removeEventListener("touchend", this.onTouchEnd)
    window.removeEventListener("keydown", this.onKeydown, true)
  },

  hasPrev() {
    return !!this.panel.dataset.prev
  },

  hasNext() {
    return !!this.panel.dataset.next
  },

  touchStart(e) {
    if (e.touches.length !== 1) return
    this.startX = e.touches[0].clientX
    this.startY = e.touches[0].clientY
    this.dx = 0
    this.dragging = true
    this.panel.style.transition = "none"
  },

  touchMove(e) {
    if (!this.dragging) return
    const dx = e.touches[0].clientX - this.startX
    const dy = e.touches[0].clientY - this.startY
    if (Math.abs(dx) <= Math.abs(dy)) return // vertical scroll wins the gesture
    e.preventDefault() // own the horizontal gesture
    // At an end there's nowhere to go: resist the drag so it feels bounded.
    const atEnd = (dx > 0 && !this.hasPrev()) || (dx < 0 && !this.hasNext())
    this.dx = atEnd ? dx / 3 : dx
    this.panel.style.transform = `translateX(${this.dx}px)`
  },

  touchEnd() {
    if (!this.dragging) return
    this.dragging = false
    const width = this.panel.offsetWidth || 1
    const committed = Math.abs(this.dx) > width * COMMIT_FRACTION
    const goPrev = this.dx > 0 && this.hasPrev()
    const goNext = this.dx < 0 && this.hasNext()

    if (committed && (goPrev || goNext)) {
      this.commit(goPrev ? "prev" : "next")
    } else {
      this.bounce() // below threshold or at an end → rubber-band back
    }
  },

  commit(dir) {
    this.pendingDir = dir
    const btn = document.getElementById(dir === "prev" ? "card-drawer-prev" : "card-drawer-next")
    if (btn) {
      btn.click() // server computes the neighbor + patches; `updated` slides it in
    } else {
      this.bounce()
    }
  },

  bounce() {
    this.panel.style.transition = "transform 200ms cubic-bezier(0.22, 1, 0.36, 1)"
    this.panel.style.transform = "translateX(0)"
  },

  reset() {
    this.panel.style.transition = "none"
    this.panel.style.transform = "translateX(0)"
  },

  guardArrowKeys(e) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return
    const t = e.target
    const tag = t && t.tagName
    const typing = tag === "INPUT" || tag === "TEXTAREA" || (t && t.isContentEditable)
    if (typing) e.stopImmediatePropagation() // let the cursor move, not the card
  },
}

export default CardSwipe
