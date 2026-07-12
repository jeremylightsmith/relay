defmodule Relay.MarkdownAttachmentTest do
  use ExUnit.Case, async: true

  test "an attachment markdown image renders as a same-origin <img> the drawer can embed" do
    # This is exactly the call the card-drawer timeline makes on each comment
    # body (core_components.ex — `Relay.Markdown.to_html(comment.body)`), so
    # asserting on it proves the screenshot embeds inline with no CSP change.
    # to_html/1 returns a {:safe, html} tuple; the html is a plain binary.
    {:safe, html} = Relay.Markdown.to_html("![state](/attachments/abc-123)")
    doc = LazyHTML.from_fragment(html)

    # Attribute selector (not raw-HTML matching) proves an <img> with the
    # exact same-origin src survives MDEx's sanitizer. query/2 (not filter/2)
    # is required here: filter/2 only matches root nodes, and the <img> is
    # nested inside the rendered <p>.
    assert doc |> LazyHTML.query(~s(img[src="/attachments/abc-123"])) |> Enum.count() == 1
  end
end
