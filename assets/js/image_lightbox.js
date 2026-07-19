// RLY-157 — click any rendered image to view it full size.
//
// Deliberately a plain module, NOT a LiveView hook. `phx-hook` callbacks only run on
// pages driven by a LiveView, and the docs site, the landing page and the legal pages
// are dead controller-rendered pages. They all render through root.html.heex and load
// app.js, so a module-scope delegated listener covers every page; a hook would cover
// none of them.
//
// One delegated listener on `document`, not one per <img>: LiveView re-renders markdown
// constantly (comments stream in, inline fields commit, the drawer re-patches), so
// per-image listeners would silently stop working after a patch and would need
// re-binding on every update. Delegation needs no lifecycle bookkeeping.
const SELECTOR = ".md img, .docs img, #ai-result-screens img"

let initialized = false

export default function initImageLightbox() {
  if (initialized) return
  initialized = true

  document.addEventListener("click", e => {
    const dialog = document.getElementById("image-lightbox")
    const target = document.getElementById("image-lightbox-img")
    if (!dialog || !target) return

    // Never intercept a click on the viewer's own image or its backdrop.
    if (dialog.contains(e.target)) return

    const img = e.target.closest(SELECTOR)
    // The `src` guard skips decorative/placeholder elements with nothing to show.
    if (!img || !img.getAttribute("src")) return

    e.preventDefault()
    target.src = img.currentSrc || img.src
    target.alt = img.alt || ""
    dialog.showModal()
  })

  document.addEventListener(
    "close",
    e => {
      // Clear the src on close so the previous image never flashes on the next open.
      if (e.target && e.target.id === "image-lightbox") {
        const target = document.getElementById("image-lightbox-img")
        if (target) target.src = ""
      }
    },
    true, // `close` does not bubble — capture it on the way down.
  )
}
