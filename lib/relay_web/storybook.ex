defmodule RelayWeb.Storybook do
  @moduledoc false
  use PhoenixStorybook,
    otp_app: :relay,
    content_path: Path.expand("../../storybook", __DIR__),
    # assets path are remote path, not local file-system paths
    css_path: "/assets/css/storybook.css",
    js_path: "/assets/js/storybook.js",
    # Ex: "https://github.com/my-org/my-app/blob/main"
    # source_permalink_base_url: "https://github.com/my-org/my-app/blob/main",
    sandbox_class: "relay",
    # RE237 — renders PhoenixStorybook's light/dark/system switcher and flips its own chrome
    # (header, sidebar, search), which is styled with a `.psb:dark` class. Our components are
    # styled off `data-theme` instead, so assets/js/storybook.js bridges the two and keeps both
    # tied to the app's `phx:theme` preference — see that file.
    color_mode: true
end
