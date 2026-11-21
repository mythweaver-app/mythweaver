defmodule Mythweaver.Sharing.VisibilityTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters.Character
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Visibility

  @user_id Ecto.UUID.generate()

  describe "site_visibility on personal rows" do
    test "a personal character, prompt, block or script refuses runtime_only" do
      changesets = [
        Character.changeset(%Character{user_id: @user_id}, %{name: "A", site_visibility: :runtime_only}),
        Prompt.changeset(%Prompt{user_id: @user_id}, %{name: "A", site_visibility: :runtime_only}),
        Block.changeset(%Block{user_id: @user_id}, %{
          name: "A",
          role: :system,
          kind: :template,
          content: "x",
          site_visibility: :runtime_only
        }),
        Script.changeset(%Script{user_id: @user_id}, %{
          name: "A",
          trigger: :ai_generation,
          site_visibility: :runtime_only
        })
      ]

      for changeset <- changesets do
        assert "only site items can be runtime-only" in errors_on(changeset).site_visibility
      end
    end

    test "a site row may be runtime_only" do
      changeset = Character.changeset(%Character{user_id: nil}, %{name: "A", site_visibility: :runtime_only})
      refute Map.has_key?(errors_on(changeset), :site_visibility)
    end
  end

  describe "content_hidden?/1 and block_hidden_for?/3" do
    test "only a non-readable site row is content-hidden" do
      assert Visibility.content_hidden?(%Character{user_id: nil, site_visibility: :runtime_only})
      refute Visibility.content_hidden?(%Character{user_id: nil, site_visibility: :readable})
      refute Visibility.content_hidden?(%Character{user_id: @user_id, site_visibility: :runtime_only})
    end

    test "a block is hidden when it or its prompt is, unless the scope may view hidden content" do
      hidden = %Block{user_id: nil, site_visibility: :runtime_only}
      open = %Block{user_id: nil, site_visibility: :readable}
      hidden_prompt = %Prompt{user_id: nil, site_visibility: :runtime_only}
      viewer = %Scope{permissions: %{"site.hidden.view" => true}}

      assert Visibility.block_hidden_for?(nil, hidden, nil)
      assert Visibility.block_hidden_for?(nil, open, hidden_prompt)
      refute Visibility.block_hidden_for?(nil, open, nil)
      refute Visibility.block_hidden_for?(viewer, hidden, hidden_prompt)
    end
  end
end
