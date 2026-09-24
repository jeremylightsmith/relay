// RE333 — hover/focus emphasis on the flow graph (#flow-graph).
//
// Hovering (or focusing) a `[data-node]` puts the graph into "hover" focus: `data-dim="hover"` on
// the root, and `data-hot` on the node, its neighbours, and its incident edges — both the SVG
// strokes (`[data-edge-path]`) and the label pills (`[data-edge]`). app.css does the rest:
// everything not hot recedes and unrelated labels hide, so you can tell which text belongs to
// which line.
//
// Adjacency comes from the `data-adjacency` JSON the component renders (node key → incident edge
// indices), so there is no LiveView round-trip. The server renders the SAME marks for a selected
// node (`data-dim="select"` + `data-selected`), so when the pointer leaves we fall back to the
// selection rather than clearing it.
const FlowFocus = {
  mounted() {
    this.hovered = null
    this.onOver = e => {
      const node = e.target.closest("[data-node]")
      if (node && node.dataset.node !== this.hovered) this.focus(node.dataset.node)
    }
    this.onOut = e => {
      const node = e.target.closest("[data-node]")
      if (node && !node.contains(e.relatedTarget)) this.focus(null)
    }
    this.listeners = [
      ["mouseover", this.onOver],
      ["focusin", this.onOver],
      ["mouseout", this.onOut],
      ["focusout", this.onOut],
    ]
    this.listeners.forEach(([type, fn]) => this.el.addEventListener(type, fn))
  },

  // A server patch rewrites the marks from @selected; re-apply a hover that is still in progress.
  updated() {
    if (this.hovered) this.paint()
  },

  destroyed() {
    this.listeners.forEach(([type, fn]) => this.el.removeEventListener(type, fn))
  },

  focus(key) {
    this.hovered = key
    this.paint()
  },

  paint() {
    const key = this.hovered || this.el.dataset.selected
    const adjacency = JSON.parse(this.el.dataset.adjacency || "{}")
    const edges = new Set((key && adjacency[key]) || [])

    this.el.querySelectorAll("[data-hot]").forEach(el => el.removeAttribute("data-hot"))

    if (edges.size === 0) {
      this.el.removeAttribute("data-dim")
      return
    }

    this.el.setAttribute("data-dim", this.hovered ? "hover" : "select")

    for (const [node, incident] of Object.entries(adjacency)) {
      if (incident.some(i => edges.has(i))) this.mark(`[data-node="${CSS.escape(node)}"]`)
    }
    edges.forEach(i => this.mark(`[data-edge="${i}"], [data-edge-path="${i}"]`))
  },

  mark(selector) {
    this.el.querySelectorAll(selector).forEach(el => el.setAttribute("data-hot", ""))
  },
}

export default FlowFocus
