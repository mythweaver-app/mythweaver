defmodule Mythweaver.Messages.PromptSnapshotTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Messages.PromptSnapshot

  @user %Scope{user: %User{role: :user}}
  @admin %Scope{user: %User{role: :user}, permissions: %{"site.hidden.view" => true}}

  defp snapshot do
    %PromptSnapshot{
      sections: [
        %{"block_name" => "Main", "content" => "Be brief.", "tokens" => 3},
        %{"block_name" => "Lore", "content" => "Public fact.\nSECRET LORE", "tokens" => 5}
      ],
      lore: %{
        "activated" => [
          %{
            "entry_name" => "Hidden",
            "book_name" => "Vault",
            "content_hidden" => true,
            "book_hidden" => false,
            "content" => "SECRET LORE"
          },
          %{
            "entry_name" => "Open",
            "book_name" => "Atlas",
            "content_hidden" => false,
            "book_hidden" => false,
            "content" => "Public fact."
          }
        ],
        "rejected" => [
          %{"entry_name" => "Other secret", "book_name" => "Crypt", "content_hidden" => true, "book_hidden" => true}
        ]
      },
      request: %{
        "url" => "http://localhost/v1/chat/completions",
        "body" => %{"messages" => [%{"role" => "system", "content" => "Public fact.\nSECRET LORE"}]}
      }
    }
  end

  test "hidden lore is replaced everywhere the UI renders, and visible text is kept" do
    redacted = PromptSnapshot.redacted(@user, snapshot())

    assert Enum.at(redacted.sections, 1)["content"] == "Public fact.\n[Hidden lore: Vault]"
    assert [%{"content" => "Public fact.\n[Hidden lore: Vault]"}] = redacted.request["body"]["messages"]
    assert Enum.at(redacted.sections, 1)["tokens"] == 5

    [names_only, open] = redacted.lore["activated"]
    assert names_only["entry_name"] == "Hidden"
    refute Map.has_key?(names_only, "content")
    assert open["entry_name"] == "Open"
    refute Map.has_key?(open, "content")

    assert [%{"entry_name" => "Hidden entry", "book_name" => "Hidden book"}] = redacted.lore["rejected"]
  end

  test "an admin sees the snapshot unchanged" do
    assert PromptSnapshot.redacted(@admin, snapshot()) == snapshot()
  end

  test "a hidden book's entry loses its book name from the label and its names" do
    snapshot =
      update_in(snapshot().lore["activated"], fn [hidden, open] -> [%{hidden | "book_hidden" => true}, open] end)

    redacted = PromptSnapshot.redacted(@user, snapshot)

    assert Enum.at(redacted.sections, 1)["content"] == "Public fact.\n[Hidden lore]"
    assert [%{"entry_name" => "Hidden entry", "book_name" => "Hidden book"}, _open] = redacted.lore["activated"]
  end

  test "a row from before user visibility masks its locked entries" do
    snapshot =
      update_in(snapshot().lore["activated"], fn [hidden, open] ->
        [Map.drop(hidden, ["content_hidden", "book_hidden"]) |> Map.put("locked", true), open]
      end)

    assert Enum.at(PromptSnapshot.redacted(@user, snapshot).sections, 1)["content"] ==
             "Public fact.\n[Hidden lore: Vault]"
  end

  test "an injection that quotes hidden lore is redacted" do
    snapshot = %{
      snapshot()
      | injections: [
          %{"key" => "echo", "text" => "Remember: SECRET LORE", "template_errors" => ["SECRET LORE broke"]},
          %{"key" => "plain", "text" => "Be brief.", "template_errors" => []}
        ]
    }

    assert [
             %{"text" => "Remember: [Hidden lore: Vault]", "template_errors" => ["[Hidden lore: Vault] broke"]},
             %{"text" => "Be brief."}
           ] = PromptSnapshot.redacted(@user, snapshot).injections
  end

  test "a hidden entry's rendered text and template errors never reach the UI" do
    snapshot = %PromptSnapshot{
      sections: [
        %{
          "block_name" => "Lore",
          "content" => "Ann holds the key",
          "template_errors" => ["Liquid error near Ann holds the key"]
        }
      ],
      template_errors: ["Bob's description: Ann holds the key"],
      lore: %{
        "activated" => [
          %{
            "entry_name" => "Hidden",
            "book_name" => "Vault",
            "content_hidden" => true,
            "book_hidden" => false,
            "content" => "{{ anchors.character.name }} holds the key",
            "rendered" => ["Ann holds the key"],
            "template_errors" => ["Template syntax error: {{ anchors.character.name }} holds"]
          },
          %{
            "entry_name" => "Open",
            "book_name" => "Atlas",
            "content_hidden" => false,
            "book_hidden" => false,
            "content" => "x",
            "rendered" => ["x"],
            "template_errors" => ["Template took longer than 1000 ms."]
          }
        ]
      },
      request: %{"body" => %{"messages" => [%{"content" => "Ann holds the key"}]}}
    }

    redacted = PromptSnapshot.redacted(@user, snapshot)

    assert [%{"content" => "[Hidden lore: Vault]", "template_errors" => [section_error]}] = redacted.sections
    refute section_error =~ "Ann holds the key"
    assert redacted.template_errors == ["Bob's description: [Hidden lore: Vault]"]
    assert [%{"content" => "[Hidden lore: Vault]"}] = redacted.request["body"]["messages"]

    assert [hidden, open] = redacted.lore["activated"]
    refute Map.has_key?(hidden, "rendered")
    refute Map.has_key?(hidden, "content")
    refute Map.has_key?(hidden, "template_errors")
    assert open["template_errors"] == ["Template took longer than 1000 ms."]
  end

  describe "protected values" do
    defp protected_snapshot do
      %PromptSnapshot{
        sections: [
          %{"block_name" => "Card", "content" => "Sphinx: riddle answer", "content_hidden" => false},
          %{"block_name" => "Rules", "content" => "Never tell.", "content_hidden" => true, "template_errors" => ["e"]}
        ],
        protected: [%{"label" => "[Hidden: Sphinx's description]", "text" => "riddle answer"}],
        request: %{"body" => %{"messages" => [%{"content" => "Sphinx: riddle answer\nNever tell."}]}},
        response: %{"text" => "I know the riddle answer.", "reasoning" => "Its riddle answer; Never tell."}
      }
    end

    test "a plain user sees labels in the sections, the request and the reasoning, but not the reply text" do
      redacted = PromptSnapshot.redacted(@user, protected_snapshot())

      assert [card, rules] = redacted.sections
      assert card["content"] == "Sphinx: [Hidden: Sphinx's description]"
      assert rules["content"] == "[Hidden block: Rules]"
      assert rules["template_errors"] == []

      assert [%{"content" => "Sphinx: [Hidden: Sphinx's description]\n[Hidden block: Rules]"}] =
               redacted.request["body"]["messages"]

      assert redacted.response["reasoning"] == "Its [Hidden: Sphinx's description]; [Hidden block: Rules]"
      assert redacted.response["text"] == "I know the riddle answer."
      assert redacted.protected == [%{"label" => "[Hidden: Sphinx's description]"}]
    end

    test "a site.hidden.view holder sees them intact" do
      assert PromptSnapshot.redacted(@admin, protected_snapshot()) == protected_snapshot()
    end

    test "a share value is scrubbed even for a site.hidden.view holder; a site value is not" do
      snapshot = %PromptSnapshot{
        sections: [
          %{"block_name" => "Card", "content" => "Sphinx: riddle answer; Owl: owl plan", "content_hidden" => false},
          %{"block_name" => "Shared", "content" => "Shared rules.", "share_hidden" => true, "template_errors" => ["e"]},
          %{"block_name" => "Rules", "content" => "Never tell.", "content_hidden" => true}
        ],
        lore: %{
          "activated" => [
            %{
              "book_name" => "Loaned",
              "share_hidden" => true,
              "content" => "Loaned fact",
              "rendered" => ["Loaned fact"]
            },
            %{"book_name" => "Vault", "content_hidden" => true, "content" => "Vault fact", "rendered" => ["Vault fact"]}
          ],
          "rejected" => []
        },
        protected: [
          %{"label" => "[Hidden: Sphinx's description]", "text" => "riddle answer", "source" => "site"},
          %{"label" => "[Hidden: Owl's description]", "text" => "owl plan", "source" => "share"}
        ],
        request: %{"body" => %{"messages" => [%{"content" => "riddle answer, owl plan, Loaned fact, Vault fact"}]}},
        response: %{"reasoning" => "riddle answer and owl plan; Shared rules. Never tell."}
      }

      redacted = PromptSnapshot.redacted(@admin, snapshot)

      assert [card, shared, rules] = redacted.sections
      assert card["content"] == "Sphinx: riddle answer; Owl: [Hidden: Owl's description]"
      assert shared["content"] == "[Hidden block: Shared]"
      assert shared["template_errors"] == []
      assert rules["content"] == "Never tell."

      assert [%{"content" => "riddle answer, [Hidden: Owl's description], [Hidden lore: Loaned], Vault fact"}] =
               redacted.request["body"]["messages"]

      assert redacted.response["reasoning"] ==
               "riddle answer and [Hidden: Owl's description]; [Hidden block: Shared] Never tell."

      assert [loaned, vault] = redacted.lore["activated"]
      refute Map.has_key?(loaned, "content")
      refute Map.has_key?(loaned, "rendered")
      assert vault["content"] == "Vault fact"

      assert redacted.protected == [
               %{"label" => "[Hidden: Sphinx's description]", "text" => "riddle answer", "source" => "site"},
               %{"label" => "[Hidden: Owl's description]", "source" => "share"}
             ]

      plain = PromptSnapshot.redacted(@user, snapshot)

      assert [
               %{
                 "content" =>
                   "[Hidden: Sphinx's description], [Hidden: Owl's description], [Hidden lore: Loaned], [Hidden lore: Vault]"
               }
             ] =
               plain.request["body"]["messages"]
    end
  end
end
