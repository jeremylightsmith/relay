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
    sandbox_class: "relay"
end
