// RLY-94 · BOARD-01 — the phone-width stage pager's client half. LiveView owns all
// DOM content (no phx-update="ignore"); this hook only reads scroll position and
// scrolls, plus reports "is the pager active?" so the server can disable the
// desktop-only stage collapse (every stage gets a page in pager mode).
//
// Mounted on #board-pager-nav (the chip strip). Pages are the .stage-column
// sections inside #board-bands, addressed by data-stage-id.
const BoardPager = {
  mounted() {
    this.pager = document.getElementById("board-bands")
    this.mq = window.matchMedia("(min-width: 45rem)") // --breakpoint-drawer
    this.reportMode = () => this.pushEvent("pager", {active: !this.mq.matches})
    this.mq.addEventListener("change", this.reportMode)
    this.reportMode()

    // Scroll position → active chip: the snap page covering ≥60% of the pager
    // viewport is the active one.
    this.observer = new IntersectionObserver(
      entries => {
        entries.forEach(entry => {
          if (entry.isIntersecting) this.setActive(entry.target.dataset.stageId)
        })
      },
      {root: this.pager, threshold: 0.6},
    )
    this.observePages()

    // Chip tap → smooth-scroll that stage's page into view.
    this.el.addEventListener("click", e => {
      const chip = e.target.closest("[data-chip-stage-id]")
      if (!chip) return
      this.pager
        .querySelector(`.stage-column[data-stage-id="${chip.dataset.chipStageId}"]`)
        ?.scrollIntoView({behavior: "smooth", block: "nearest", inline: "start"})
    })
  },

  // LiveView patches (count updates, expand/collapse) re-render chips and pages,
  // dropping the client-owned data-active attribute: re-observe and re-apply.
  updated() {
    this.observePages()
    this.markActive()
  },

  destroyed() {
    this.observer.disconnect()
    this.mq.removeEventListener("change", this.reportMode)
  },

  observePages() {
    this.observer.disconnect()
    this.pager
      .querySelectorAll(".stage-column[data-stage-id]")
      .forEach(page => this.observer.observe(page))
  },

  setActive(stageId) {
    if (this.activeId === stageId) return
    this.activeId = stageId
    this.markActive()
  },

  markActive() {
    const id = this.activeId || this.el.querySelector("[data-chip-stage-id]")?.dataset.chipStageId
    this.el.querySelectorAll("[data-chip-stage-id]").forEach(chip => {
      chip.toggleAttribute("data-active", chip.dataset.chipStageId === id)
    })
    // Keep the highlighted chip visible inside the strip's own scroller.
    this.el
      .querySelector(`[data-chip-stage-id="${id}"]`)
      ?.scrollIntoView({behavior: "smooth", block: "nearest", inline: "nearest"})
  },
}

export default BoardPager
