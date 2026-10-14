// RLY-94 · BOARD-01 — the phone-width stage pager's client half. LiveView owns all
// DOM content (no phx-update="ignore"); this hook only reads scroll position and
// scrolls, plus reports "is the pager active?" so the server can render a collapsed
// stage as its compact row page instead of the desktop strip (RE377).
//
// Mounted on #board-pager-nav (the chip strip). Pages are the .stage-column
// sections inside #board-bands, addressed by data-stage-id.
//
// RE452 — `?stage=<id>` opens the pager on that stage's page (a sub-lane id resolves
// to its parent's page), and the active page is reported to the native shell
// (relayStageChanged) so the app can reopen there; an id not on the board is
// reported once (relayStageMissing). Both calls are no-ops in a plain browser.
// The shell can also re-show a stage page later by dispatching
// `relay:show-stage` ({detail: {stage_id}}) on window: a card restore loads this
// board UNDER the pushed card, where the one-shot restore scroll runs with no
// real layout and drifts, so the shell re-applies the page once it is revealed.
const BoardPager = {
  mounted() {
    this.pager = document.getElementById("board-bands")
    this.mq = window.matchMedia("(min-width: 45rem)") // --breakpoint-drawer
    this.requestedStage = new URLSearchParams(window.location.search).get("stage")
    // The restore scrolls in the reply: turning the pager on re-streams collapsed
    // strips as full compact pages, shifting every later page — scrolling before
    // that patch lands would drift a page or two off.
    this.reportMode = () =>
      this.pushEvent("pager", {active: !this.mq.matches}, () => this.restoreStage())
    this.mq.addEventListener("change", this.reportMode)
    this.reportMode()

    this.onShowStage = e => this.showStage(String(e.detail?.stage_id))
    window.addEventListener("relay:show-stage", this.onShowStage)

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
    // strips re-render as compact .stage-column pages) patches #board-bands, not this
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

    // RE376 · BOARD-01 — embedded, the board name is the switcher: hand the tap to
    // the native shell, which opens its "Switch board" sheet. No handler in a plain
    // browser (the button only renders in embed mode anyway): the tap is a no-op.
    this.el.addEventListener("click", e => {
      const sw = e.target.closest("#board-switch-board")
      if (!sw || !window.flutter_inappwebview) return
      window.flutter_inappwebview.callHandler("relayOpenBoardSwitcher", {board: sw.dataset.board})
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
    window.removeEventListener("relay:show-stage", this.onShowStage)
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
    this.reportStage(stageId)
  },

  // Once per mount: scroll to the `?stage=` page, or report the id missing.
  restoreStage() {
    if (this.stageRestored) return
    this.stageRestored = true
    const wanted = this.requestedStage
    if (!wanted) return

    const chip = this.chipFor(wanted)
    if (!chip) {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler("relayStageMissing", {stage_id: Number(wanted)})
      }
      return
    }
    this.scrollToChip(chip)
  },

  // The shell's `relay:show-stage`: jump to that stage's page. Again a frame or two
  // later — the webview is mid-reveal and its layout may still be settling.
  showStage(stageId) {
    const chip = this.chipFor(stageId)
    if (!chip) return
    this.scrollToChip(chip)
    requestAnimationFrame(() => requestAnimationFrame(() => this.scrollToChip(chip)))
  },

  // The chip with that id, else the chip whose sub-lanes include it.
  chipFor(stageId) {
    const chips = Array.from(this.el.querySelectorAll("[data-chip-stage-id]"))
    return (
      chips.find(c => c.dataset.chipStageId === stageId) ||
      chips.find(c => (c.dataset.sublaneIds || "").split(",").includes(stageId))
    )
  },

  scrollToChip(chip) {
    this.pager
      .querySelector(`.stage-column[data-stage-id="${chip.dataset.chipStageId}"]`)
      ?.scrollIntoView({behavior: "instant", block: "nearest", inline: "start"})
  },

  // The page showing changed: tell the native shell (top-level stage, chip's name).
  reportStage(stageId) {
    if (!window.flutter_inappwebview) return
    const chip = this.el.querySelector(`[data-chip-stage-id="${stageId}"]`)
    const board = this.el.querySelector("#board-switch-board, #board-create-card")?.dataset.board
    if (!chip || !board) return
    window.flutter_inappwebview.callHandler("relayStageChanged", {
      board: board,
      stage_id: Number(stageId),
      stage_name: chip.dataset.stageName,
    })
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
