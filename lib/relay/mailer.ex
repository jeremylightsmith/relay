defmodule Relay.Mailer do
  @moduledoc false
  use Boundary, deps: []
  use Swoosh.Mailer, otp_app: :relay
end
