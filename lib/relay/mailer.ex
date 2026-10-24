defmodule Relay.Mailer do
  @moduledoc """
  The app's Swoosh mailer (RE464). The adapter is per environment: `Swoosh.Adapters.Local` in dev
  (browse it at `/dev/mailbox`), `Swoosh.Adapters.Test` in test, and `Swoosh.Adapters.Resend` in
  prod once `RESEND_API_KEY` and `MAIL_FROM` are set (`config/runtime.exs`).

  Callers go through `Relay.Billing.Notifier.deliver/1`, which honors the `:mail_enabled` switch.
  """

  use Boundary, deps: []
  use Swoosh.Mailer, otp_app: :relay
end
