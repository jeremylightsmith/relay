// RE399 — browser notifications. RelayWeb.BrowserNotify pushes "relay:notify" (one per push-worthy
// card status change, the same copy APNs carries) to this hook, mounted by Layouts.app on
// #browser-notify. Per event:
//   * focused tab   → an in-page toast cloned from the kind's <template>, plus the horn;
//   * background tab → "(n) " title prefix and an amber favicon dot (every tab), and — once across
//     all tabs — an OS Notification (when granted) plus the horn.
// "Once across all tabs" is a Web Lock named after the event id, taken with ifAvailable: the first
// tab to ask wins, the rest get `null`. A focused tab asks at once, a background tab a beat later,
// so the tab you are looking at wins.
//
// RE404: the server only sends events for the board this tab is showing (pages with no board get
// none), so a toast never names a board.
//
// MODULE-SCOPE STATE: the hook element lives in the layout, so every live navigation destroys and
// remounts it. The unread count, the original favicon, the listeners and the <title> observer
// live here, installed once; mounted() only re-points `current` and re-syncs the UI.
//
// No color literal anywhere: the dot reads the theme's --color-warning token. The horn URL comes
// from data-sound (Relay.Push.web_sound_path/0). Toast text is set as text, never parsed as HTML.
const SOUND_KEY = "relay:notify-sound"
const LOCK_HOLD_MS = 5000
const BACKGROUND_DELAY_MS = 300
const TOAST_MS = 8000
const MAX_TOASTS = 3
const TITLE_PREFIX = /^\(\d+\) /

let current = null
let installed = false
let unread = 0
let originalIcon = null
let dotted = false

// ── permission ───────────────────────────────────────────────────────────────────────────────
// Read at call time, never cached: the user can change it in browser settings at any moment.

const permission = () => ("Notification" in window ? window.Notification.permission : "unsupported")

const syncPermission = () => {
  document.documentElement.dataset.notifyPermission = permission()
}

// ── sound ────────────────────────────────────────────────────────────────────────────────────
// localStorage throws in some private modes; then Sound is simply on and not remembered.

const soundOn = () => {
  try {
    return localStorage.getItem(SOUND_KEY) !== "off"
  } catch (_e) {
    return true
  }
}

const writeSound = on => {
  try {
    if (on) localStorage.removeItem(SOUND_KEY)
    else localStorage.setItem(SOUND_KEY, "off")
  } catch (_e) {}
}

const syncSoundToggle = () => {
  const toggle = document.getElementById("notify-sound-toggle")
  if (toggle) toggle.checked = soundOn()
}

const playHorn = () => {
  if (!current || !soundOn()) return
  const played = new Audio(current.el.dataset.sound).play()
  // Autoplay policy rejects play() until the user has interacted with the page.
  if (played && played.catch) played.catch(() => {})
}

// ── title count ──────────────────────────────────────────────────────────────────────────────
// Idempotent: setting the title it already has is a no-op, so the observer re-entering here
// after our own write stops at once and never stacks a second prefix.

const applyTitle = () => {
  const bare = document.title.replace(TITLE_PREFIX, "")
  const want = unread > 0 ? `(${unread}) ${bare}` : bare
  if (document.title !== want) document.title = want
}

// LiveView's live_title rewrites <title> on navigation and page_title changes; put the count back.
const observeTitle = () => {
  const target = document.querySelector("title") || document.head
  new MutationObserver(() => {
    if (unread > 0) applyTitle()
  }).observe(target, {childList: true, characterData: true, subtree: true})
}

// ── favicon dot ──────────────────────────────────────────────────────────────────────────────

const iconLink = () => document.querySelector("link[rel=icon]")

// Captured once, before the first swap — afterwards the link holds our data URL.
const captureOriginalIcon = () => {
  if (originalIcon !== null) return
  const link = iconLink()
  originalIcon = link ? link.href : ""
}

const applyDot = () => {
  const link = iconLink()
  if (dotted || !link || !originalIcon) return
  dotted = true

  const img = new Image()
  img.onload = () => {
    if (!dotted) return // cleared while loading
    const size = img.naturalWidth || 32
    const canvas = document.createElement("canvas")
    canvas.width = size
    canvas.height = size
    const ctx = canvas.getContext("2d")
    ctx.drawImage(img, 0, 0, size, size)

    const r = size * 0.22
    ctx.beginPath()
    ctx.arc(size - r, r, r, 0, 2 * Math.PI)
    ctx.fillStyle = getComputedStyle(document.documentElement).getPropertyValue("--color-warning").trim()
    ctx.fill()

    link.href = canvas.toDataURL("image/png")
  }
  img.src = originalIcon
}

const clearUnread = () => {
  if (unread === 0 && !dotted) return
  unread = 0
  applyTitle()
  dotted = false
  const link = iconLink()
  if (link && originalIcon) link.href = originalIcon
}

// ── toasts ───────────────────────────────────────────────────────────────────────────────────

const openCard = msg => {
  if (current) current.pushEvent("browser_notify:open", {board_slug: msg.board_slug, card_ref: msg.card_ref})
}

const setField = (toast, field, text) => {
  const slot = toast.querySelector(`[data-field="${field}"]`)
  if (slot) slot.textContent = text
}

const showToast = msg => {
  const template = document.getElementById(`browser-notify-toast-${msg.kind}`)
  const stack = document.getElementById("browser-notify-toasts")
  if (!template || !stack || !template.content.firstElementChild) return

  const toast = template.content.firstElementChild.cloneNode(true)
  setField(toast, "card_ref", msg.card_ref)
  setField(toast, "title", msg.title)
  setField(toast, "card_title", msg.card_title)

  // Auto-dismiss, paused while the pointer rests on the toast.
  let timer = null
  let remaining = TOAST_MS
  let startedAt = 0
  const dismiss = () => {
    clearTimeout(timer)
    toast.remove()
  }
  const start = () => {
    startedAt = Date.now()
    timer = setTimeout(dismiss, remaining)
  }
  toast.addEventListener("mouseenter", () => {
    clearTimeout(timer)
    remaining = Math.max(0, remaining - (Date.now() - startedAt))
  })
  toast.addEventListener("mouseleave", start)

  toast.addEventListener("click", e => {
    if (e.target.closest('[data-action="close"]')) {
      dismiss()
    } else if (e.target.closest('[data-action="open"]')) {
      dismiss()
      openCard(msg)
    }
  })

  stack.prepend(toast)
  while (stack.children.length > MAX_TOASTS) stack.lastElementChild.remove()
  start()
}

// ── OS notification ──────────────────────────────────────────────────────────────────────────

const showNotification = msg => {
  if (permission() !== "granted") return

  const notification = new window.Notification(msg.title, {
    body: msg.body,
    icon: originalIcon || undefined,
    tag: msg.card_ref,
  })
  notification.onclick = () => {
    window.focus()
    openCard(msg)
    notification.close()
  }
}

// ── one event ────────────────────────────────────────────────────────────────────────────────

const fire = (msg, background) => {
  if (background) showNotification(msg)
  else showToast(msg)
  playHorn()
}

// Exactly one open tab fires per event id. Without Web Locks every tab fires.
const fireOnce = (msg, background) => {
  if (!(navigator.locks && navigator.locks.request)) {
    fire(msg, background)
    return
  }

  const request = () =>
    navigator.locks.request("relay:notify:" + msg.id, {ifAvailable: true}, lock => {
      if (lock === null) return // another tab has it
      fire(msg, background)
      // Hold it long enough that a slower tab's request still finds it taken.
      return new Promise(resolve => setTimeout(resolve, LOCK_HOLD_MS))
    }).catch(() => {})

  if (background) setTimeout(request, BACKGROUND_DELAY_MS)
  else request()
}

const receive = msg => {
  const background = document.hidden || !document.hasFocus()

  if (background) {
    unread += 1
    applyTitle()
    applyDot()
  }

  fireOnce(msg, background)
}

// ── one-time installs ────────────────────────────────────────────────────────────────────────

const onMenuOpen = e => {
  if (e.target.closest && e.target.closest("#user-avatar")) {
    syncPermission()
    syncSoundToggle()
  }
}

const install = () => {
  if (installed) return
  installed = true

  captureOriginalIcon()
  observeTitle()

  window.addEventListener("focus", clearUnread)
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) clearUnread()
  })

  // The account menu: re-read the permission whenever it is opened.
  document.addEventListener("click", onMenuOpen)
  document.addEventListener("focusin", onMenuOpen)

  // Enable — the only place the browser's permission prompt is ever raised.
  document.addEventListener("click", e => {
    if (!(e.target.closest && e.target.closest("#notify-enable"))) return
    if (!("Notification" in window)) return syncPermission()
    Promise.resolve(window.Notification.requestPermission()).then(syncPermission, syncPermission)
  })

  document.addEventListener("change", e => {
    if (e.target.id === "notify-sound-toggle") writeSound(e.target.checked)
  })
}

const BrowserNotify = {
  mounted() {
    current = this
    install()
    syncPermission()
    syncSoundToggle()
    applyTitle()
    this.handleEvent("relay:notify", receive)
  },

  destroyed() {
    if (current === this) current = null
  },
}

export default BrowserNotify
