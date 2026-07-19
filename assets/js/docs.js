// Docs-site bundle. Deliberately separate from app.js: mermaid is ~3MB, and only /docs
// pages carry diagrams — the board must never pay for it. Loaded from Layouts.docs.
//
// No `import` of the vendored mermaid here on purpose. mermaid's published UMD dist only
// ever assigns `globalThis["mermaid"]` (it never sets `module.exports`, unlike e.g.
// vendor/topbar.js) — that assignment only lands on the real global object when the file
// runs as its own top-level classic script. Pulling it in via `--bundle` wraps its code in
// an esbuild CommonJS factory, which shadows the global write and leaves `mermaid`
// undefined. So `vendor/mermaid.min.js` is its own esbuild entry (see config/config.exs'
// `docs` profile) and loads as its own <script> before this one (see layouts.ex) — this
// file just uses the resulting `mermaid` global.

// Pick the mermaid theme from the active daisyUI theme so diagrams stay legible in dark mode.
const theme = () =>
  document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "default"

mermaid.initialize({startOnLoad: false, securityLevel: "strict", theme: theme()})

const render = async () => {
  const blocks = document.querySelectorAll("pre > code.language-mermaid")

  for (const [i, code] of [...blocks].entries()) {
    const pre = code.parentElement
    // textContent, not innerHTML: it decodes the &gt;/&amp; entities MDEx emits.
    const source = code.textContent

    try {
      const {svg} = await mermaid.render(`docs-mermaid-${i}`, source)
      const figure = document.createElement("figure")
      figure.className = "docs-mermaid"
      figure.innerHTML = svg
      pre.replaceWith(figure)
    } catch (_error) {
      // Leave the original code block in place — a bad diagram must not blank the page.
    }
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", render)
} else {
  render()
}
