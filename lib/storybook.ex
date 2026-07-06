defmodule Storybook do
  @moduledoc false
  # Declares the Storybook boundary so phoenix_storybook-compiled modules (Storybook.*)
  # are classified. Checks are disabled because storybook is dev/test tooling and may
  # freely reference any app or web modules.
  use Boundary, check: [in: false, out: false]
end
