defmodule Storybook.Components.CoreComponents.NotificationSettings do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.notification_settings/1
  def render_source, do: :function

  # The section is a fragment of `<li>`s for the avatar menu; the template stands in for
  # `#account-menu`. Each variation forces one permission state — in the app (`state: :auto`)
  # the BrowserNotify hook reveals the row matching `<html data-notify-permission>`.
  def template do
    """
    <ul class="menu w-60 rounded-box bg-base-100 p-2 shadow">
      <.psb-variation/>
    </ul>
    """
  end

  def variations do
    [
      %Variation{id: :default, description: "Not asked yet", attributes: %{state: :default}},
      %Variation{id: :granted, description: "Desktop alerts on", attributes: %{state: :granted}},
      %Variation{id: :denied, description: "Blocked in the browser", attributes: %{state: :denied}},
      %Variation{
        id: :unsupported,
        description: "No Notification API (renders the blocked row)",
        attributes: %{state: :unsupported}
      }
    ]
  end
end
