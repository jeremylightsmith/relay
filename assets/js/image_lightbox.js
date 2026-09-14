// RLY-157 — click any rendered image to view it full size.
// RE322 — …and step through the rest of its group as a carousel.
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
//
// RE322 — the same holds for the carousel: its set is computed from the live DOM when the
// viewer opens and dropped when it closes. Nothing is recorded per image, so a patch that
// re-renders a comment or the screenshots strip can never leave the viewer with stale state.
const SELECTOR = ".md img, .docs img, #ai-result-screens img"

// D1 — the set is the clicked image's own group. The AI Result screenshots strip is one group;
// every other markdown block (a description, a spec, one timeline comment, a docs page) is its
// own. `closest` finds the nearest, so a screenshot never steps into a comment's images and a
// comment image never steps into the screenshots.
const GROUP = "#ai-result-screens, .md, .docs"

// D4 — ←/k previous, →/j next (vim/Gmail). Matched against the lowercased key, the same
// case-folding LiveView applies to `phx-key` and TypingKeyGuard mirrors (RE306).
const STEPS = {arrowleft: -1, k: -1, arrowright: 1, j: 1}

const byId = id => document.getElementById(id)

let initialized = false
let images = []
let index = 0

// D3 — a screenshot's caption is its figcaption, which the server mirrors onto `data-caption`
// (blank when there is none: its `alt` falls back to a generic "Screenshot", not a caption).
// A markdown image has no figure, so its alt text is the caption.
function captionOf(img) {
  const caption = img.hasAttribute("data-caption") ? img.dataset.caption : img.getAttribute("alt")
  return (caption || "").trim()
}

function show() {
  const img = images[index]
  const target = byId("image-lightbox-img")
  const caption = byId("image-lightbox-caption")
  const counter = byId("image-lightbox-counter")
  const many = images.length > 1

  target.src = img.currentSrc || img.src
  target.alt = img.alt || ""

  caption.textContent = captionOf(img)
  caption.hidden = caption.textContent === ""

  // A lone image looks and behaves exactly like the pre-carousel viewer: no counter, no buttons.
  counter.textContent = many ? `${index + 1} / ${images.length}` : ""
  counter.hidden = !many
  byId("image-lightbox-prev").hidden = !many
  byId("image-lightbox-next").hidden = !many
}

function step(delta) {
  if (images.length < 2) return
  // D2 — wrap around at both ends.
  index = (index + delta + images.length) % images.length
  show()
}

function open(img, dialog) {
  const group = img.closest(GROUP)
  images = Array.from(group.querySelectorAll("img")).filter(
    candidate => candidate.getAttribute("src") && candidate.closest(GROUP) === group,
  )
  index = images.indexOf(img)
  show()
  dialog.showModal()
}

// Key isolation. The card drawer binds ←/→ to previous/next CARD and Esc to close the drawer with
// `phx-window-keydown`, and LiveView's window bindings fire even behind a modal <dialog>: without
// this, → in the viewer would also switch the card behind it, and Esc would close the viewer AND
// the drawer. A capture-phase listener on `window` runs before any of LiveView's window listeners,
// and stopImmediatePropagation keeps the key from reaching them. While the viewer is closed it
// touches nothing, so the drawer's card navigation, `t` and Esc work exactly as before.
function onKeydown(e) {
  const dialog = byId("image-lightbox")
  if (!dialog || !dialog.open) return

  // Chrome's autocomplete fires a keydown with no `key` at all.
  const key = e.key && e.key.toLowerCase()
  if (!key) return

  if (key === "escape") {
    e.preventDefault()
    e.stopImmediatePropagation()
    dialog.close()
    return
  }

  // A chord (⌘←, Ctrl+J, …) belongs to the browser, not the carousel.
  if (!Object.hasOwn(STEPS, key) || e.ctrlKey || e.metaKey || e.altKey) return

  // Swallowed even for a lone image, where the step is a no-op: the key must still not reach the
  // drawer behind the viewer.
  e.preventDefault()
  e.stopImmediatePropagation()
  step(STEPS[key])
}

export default function initImageLightbox() {
  if (initialized) return
  initialized = true

  document.addEventListener("click", e => {
    const dialog = byId("image-lightbox")
    if (!dialog || !byId("image-lightbox-img")) return

    if (dialog.contains(e.target)) {
      const nav = e.target.closest("#image-lightbox-prev, #image-lightbox-next")
      if (nav) step(nav.id === "image-lightbox-next" ? 1 : -1)
      // Never intercept any other click on the viewer's own image or its backdrop.
      return
    }

    const img = e.target.closest(SELECTOR)
    // The `src` guard skips decorative/placeholder elements with nothing to show.
    if (!img || !img.getAttribute("src")) return

    e.preventDefault()
    open(img, dialog)
  })

  window.addEventListener("keydown", onKeydown, true)

  document.addEventListener(
    "close",
    e => {
      // Clear the src on close so the previous image never flashes on the next open, and drop
      // the set so the next open computes a fresh one from the live DOM.
      if (e.target && e.target.id === "image-lightbox") {
        const target = byId("image-lightbox-img")
        if (target) target.src = ""
        images = []
        index = 0
      }
    },
    true, // `close` does not bubble — capture it on the way down.
  )
}
