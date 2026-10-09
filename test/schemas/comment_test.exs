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

  describe "origins/0 (RE428)" do
    test "is [:answer, :rejection]" do
      assert Comment.origins() == [:answer, :rejection]
    end
  end

  describe "changeset/3 origin rule (RE428)" do
    test ":answer without origin_question is an error on :origin_question" do
      comment = %Comment{card_id: 1, actor_type: :agent, origin: :answer, origin_question: nil}
      changeset = Comment.changeset(comment, %{body: ""}, 1)

      refute changeset.valid?
      assert errors_on(changeset)[:origin_question]
    end

    test ":answer with origin_question 2 is valid" do
      comment = %Comment{card_id: 1, actor_type: :agent, origin: :answer, origin_question: 2}
      assert Comment.changeset(comment, %{body: ""}, 1).valid?
    end

    test ":answer with origin_question 0 is an error on :origin_question" do
      comment = %Comment{card_id: 1, actor_type: :agent, origin: :answer, origin_question: 0}
      assert errors_on(Comment.changeset(comment, %{body: ""}, 1))[:origin_question]
    end

    test ":rejection with an origin_question is an error on :origin_question" do
      comment = %Comment{card_id: 1, actor_type: :agent, origin: :rejection, origin_question: 2}
      changeset = Comment.changeset(comment, %{body: ""}, 1)

      refute changeset.valid?
      assert errors_on(changeset)[:origin_question]
    end

    test "no origin and no origin_question is valid" do
      comment = %Comment{card_id: 1, actor_type: :agent, origin: nil, origin_question: nil}
      assert Comment.changeset(comment, %{body: "hi"}, 0).valid?
    end

    test "no origin with an origin_question is an error on :origin_question" do
      comment = %Comment{card_id: 1, actor_type: :agent, origin: nil, origin_question: 2}
      assert errors_on(Comment.changeset(comment, %{body: "hi"}, 0))[:origin_question]
    end

    test "origin and origin_question are never cast from input" do
      changeset =
        Comment.changeset(%Comment{card_id: 1, actor_type: :agent}, %{body: "x", origin: "answer", origin_question: 3})

      refute Map.has_key?(changeset.changes, :origin)
      refute Map.has_key?(changeset.changes, :origin_question)
    end
  end
end
