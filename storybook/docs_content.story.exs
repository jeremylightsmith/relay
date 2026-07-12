defmodule Storybook.DocsContent do
  @moduledoc false
  use PhoenixStorybook.Story, :page

  def doc, do: "Docs content styles (RLY-64) — callouts, numbered steps, and code cards."
  def navigation, do: []

  def render(assigns) do
    ~H"""
    <article class="docs">
      <h2 id="callouts">Callouts</h2>
      <p>Three tinted admonitions map to the theme tokens.</p>
      <div class="markdown-alert markdown-alert-note">
        <p class="markdown-alert-title">Note</p>
        <p>Human = blue. Neutral, informational context.</p>
      </div>
      <div class="markdown-alert markdown-alert-tip">
        <p class="markdown-alert-title">Tip</p>
        <p>AI = violet. A helpful shortcut or aside.</p>
      </div>
      <div class="markdown-alert markdown-alert-warning">
        <p class="markdown-alert-title">Warning</p>
        <p>Amber. Something to be careful about.</p>
      </div>

      <h2 id="steps">Numbered steps</h2>
      <ol>
        <li>Mint a board API key.</li>
        <li>Point your shell at the board.</li>
        <li>Run <code>bin/relay board</code> to confirm access.</li>
      </ol>

      <h2 id="code">Code</h2>
      <pre><code class="language-bash">export RELAY_URL="https://your-relay-host"
    bin/relay board</code></pre>
    </article>
    """
  end
end
