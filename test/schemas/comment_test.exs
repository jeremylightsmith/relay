defmodule Schemas.CommentTest do
  use Relay.DataCase, async: true

  alias Schemas.Comment

  describe "max_images/0 (RE427)" do
    test "is 6" do
      assert Comment.max_images() == 6
    end
  end

  describe "changeset/3 (RE427)" do
    test "a blank body is valid when the note carries an image" do
      assert Comment.changeset(%Comment{card_id: 1, actor_type: :agent}, %{body: ""}, 1).valid?
    end

    test "a blank body without images can't be blank" do
      changeset = Comment.changeset(%Comment{card_id: 1, actor_type: :agent}, %{body: ""}, 0)
      assert "can't be blank" in errors_on(changeset).body
    end

    test "more than max_images images is an error on :images" do
      changeset = Comment.changeset(%Comment{card_id: 1, actor_type: :agent}, %{body: ""}, 7)
      assert "can carry at most 6 images" in errors_on(changeset).images
    end
  end
end
