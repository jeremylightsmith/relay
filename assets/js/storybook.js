// RE237 — theme bridge for /storybook.
//
// PhoenixStorybook renders under its own root layout, NOT root.html.heex, so the app's
// synchronous theme resolver never runs on this route. Without this file <html> there carries
// no `data-theme`, every `[data-theme=dark]` rule in storybook.css is unreachable, and the
// storybook is stuck in light mode while the rest of the app is dark.
//
// Two vocabularies have to be kept in step:
//   phx:theme                — the APP's preference, "system" | "light" | "dark" (absent means
//                              system). Written by the toggle in Layouts, read by the resolver
//                              in root.html.heex. This is the source of truth: one theme choice
//                              for the whole app, storybook included.
//   psb_selected_color_mode  — PhoenixStorybook's own key, same three values. Its ColorModeHook
//                              reads it to drive the storybook CHROME (header, sidebar, search),
//                              which is styled with a `.psb:dark` class, not `data-theme`.
//
// So: resolve `phx:theme` onto `data-theme` exactly as root.html.heex does (the sandbox and our
// components), and mirror the preference into PhoenixStorybook's key (the chrome). Picking a
// mode from the storybook's own switcher writes back to `phx:theme`, so the choice follows you
// into the app.
//
// Loaded via `js_path` in RelayWeb.Storybook, which the storybook's root layout emits as a
// synchronous <script> in <head> — before first paint, and before PhoenixStorybook's own bundle
// reads its key. Both the chrome document and the story <iframe> documents run it.
(() => {
  const APP_KEY = "phx:theme";
  const PSB_KEY = "psb_selected_color_mode";
  const mq = window.matchMedia("(prefers-color-scheme: dark)");

  const read = () => {
    try {
      return localStorage.getItem(APP_KEY) || "system";
    } catch (e) {
      return "system";
    }
  };

  const write = (pref) => {
    try {
      if (pref === "system") {
        localStorage.removeItem(APP_KEY);
      } else {
        localStorage.setItem(APP_KEY, pref);
      }
      localStorage.setItem(PSB_KEY, pref);
    } catch (e) {}
  };

  const apply = (pref) => {
    const resolved = pref === "system" ? (mq.matches ? "dark" : "light") : pref;
    document.documentElement.setAttribute("data-theme", resolved);
    document.documentElement.setAttribute("data-theme-pref", pref);
  };

  // Seed PhoenixStorybook's key from the app preference before its bundle runs, so its chrome
  // and its switcher's checkmark start on the same mode the sandbox is about to render in.
  write(read());
  apply(read());

  mq.addEventListener("change", () => {
    if (read() === "system") apply("system");
  });

  // Fires in the OTHER documents of this origin — the story iframes when the chrome changes
  // mode, and an open storybook tab when the theme is changed from the app.
  window.addEventListener("storage", (e) => {
    if (e.key === APP_KEY) apply(e.newValue || "system");
  });

  // PhoenixStorybook's switcher dispatches this on #psb-colormode-dropdown; it bubbles to
  // window, where its own ColorModeHook listens too.
  window.addEventListener("psb:set-color-mode", (e) => {
    const pref = (e.detail && e.detail.mode) || "system";
    write(pref);
    apply(pref);
  });
})();
