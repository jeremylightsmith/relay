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

    // The pager round-trip (reportMode → server sets @pager_mode → collapsed
    // strips re-render as .stage-column pages) patches #board-bands, not this
    // hook's own element (#board-pager-nav) — so `updated()` below never fires
    // for it. Watch the pages container directly so newly-expanded pages get
    // observed as soon as LiveView patches them in.
    this.pagerObserver = new MutationObserver(() => this.observePages())
    this.pagerObserver.observe(this.pager, {childList: true, subtree: true})

    // Chip tap → smooth-scroll that stage's page into view.
    this.el.addEventListener("click", e => {
      const chip = e.target.closest("[data-chip-stage-id]")
      if (!chip) return
      this.pager
        .querySelector(`.stage-column[data-stage-id="${chip.dataset.chipStageId}"]`)
        ?.scrollIntoView({behavior: "smooth", block: "nearest", inline: "start"})
    })

    // RLY-126 · BOARD-04 — the embed-only header "+" opens the native New-card
    // sheet. The payload is assembled client-side (board + stages off the button's
    // data attributes, current from the active pager chip) so it always matches
    // what's on screen — no server round-trip. In a plain browser there is no
    // native handler: the tap is a no-op.
    this.el.addEventListener("click", e => {
      const create = e.target.closest("#board-create-card")
      if (!create || !window.flutter_inappwebview) return
      const stages = JSON.parse(create.dataset.stages)
      const active = this.el.querySelector(`[data-chip-stage-id="${this.activeId}"]`)
      window.flutter_inappwebview.callHandler("relayCreateCard", {
        board: create.dataset.board,
        stages: stages,
        current: active?.dataset.stageName || stages[0],
      })
    })
  },

  // LiveView patches to this hook's own element (chip count updates) drop the
  // client-owned data-active attribute: re-apply it. (Page changes are handled
  // by the #board-bands MutationObserver above, not this callback.)
  updated() {
    this.markActive()
  },

  destroyed() {
    this.observer.disconnect()
    this.pagerObserver.disconnect()
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
