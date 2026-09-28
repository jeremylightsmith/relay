// RE356 — the task body's code-block header strip (docs/designs/Relay Card Detail v5.dc.html,
// "Running fine · DE4"): the fence's language label, its line count, and a `copy` button that
// briefly reads `copied`. Relay.Markdown stays untouched for its other callers, so the strip is
// added on the client: each `pre > code` in the hooked body gets a `.code-block-strip` inserted
// right before its `pre`. A LiveView patch that re-renders the body drops the strips along with
// the old markup, and updated() puts them back; the sibling check keeps a surviving `pre` from
// getting a second strip.
const COPIED_MS = 1400
const LANG_PREFIX = "language-"

const span = (className, text) => {
  const el = document.createElement("span")
  el.className = className
  el.textContent = text
  return el
}

const CodeBlockCopy = {
  mounted() {
    this.decorate()
  },

  updated() {
    this.decorate()
  },

  destroyed() {
    clearTimeout(this.timer)
  },

  decorate() {
    this.el.querySelectorAll("pre > code").forEach(code => {
      const pre = code.parentElement
      const prev = pre.previousElementSibling
      if (prev && prev.classList.contains("code-block-strip")) return
      pre.parentNode.insertBefore(this.strip(code), pre)
    })
  },

  strip(code) {
    const langClass = Array.from(code.classList).find(c => c.startsWith(LANG_PREFIX))
    const text = code.textContent.replace(/\n$/, "")
    const lines = text === "" ? 0 : text.split("\n").length

    const button = document.createElement("button")
    button.type = "button"
    button.className = "code-block-copy"
    button.textContent = "copy"
    button.addEventListener("click", () => {
      navigator.clipboard.writeText(text).then(() => {
        button.textContent = "copied"
        clearTimeout(this.timer)
        this.timer = setTimeout(() => { button.textContent = "copy" }, COPIED_MS)
      })
    })

    const strip = document.createElement("div")
    strip.className = "code-block-strip"
    strip.append(
      span("code-block-lang", langClass ? langClass.slice(LANG_PREFIX.length) : ""),
      span("code-block-lines", `${lines} ${lines === 1 ? "line" : "lines"}`),
      button,
    )
    return strip
  },
}

export default CodeBlockCopy
