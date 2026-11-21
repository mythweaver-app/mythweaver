defmodule Mythweaver.Moderation.RulesTest do
  use Mythweaver.DataCase

  alias Mythweaver.Moderation.Rule
  alias Mythweaver.Moderation.Rules

  @regex %{"name" => "Words", "kind" => "regex", "content_types" => ["characters"], "pattern" => "bad"}

  test "an invalid regex errors on pattern" do
    assert {:error, changeset} = Rules.create_rule(scope!(), %{@regex | "pattern" => "(unclosed"})
    assert ["is not a valid regular expression: " <> _] = errors_on(changeset).pattern
  end

  test "a callback webhook rule needs a callback URL on the server" do
    config = Application.get_env(:mythweaver, Mythweaver.Moderation)
    on_exit(fn -> Application.put_env(:mythweaver, Mythweaver.Moderation, config) end)
    Application.put_env(:mythweaver, Mythweaver.Moderation, Keyword.put(config, :callback_url, nil))

    attrs = %{
      "name" => "Hook",
      "kind" => "webhook",
      "content_types" => ["lore"],
      "url" => "https://mod.example/check",
      "webhook_mode" => "callback"
    }

    assert {:error, changeset} = Rules.create_rule(scope!(), attrs)
    assert %{webhook_mode: ["needs MODERATION_CALLBACK_URL set on the server"]} = errors_on(changeset)
    assert {:ok, %Rule{webhook_mode: :sync}} = Rules.create_rule(scope!(), %{attrs | "webhook_mode" => "sync"})
  end

  test "a blank secret keeps the stored one; clear_secret removes it" do
    scope = scope!()

    {:ok, rule} =
      Rules.create_rule(scope, %{
        "name" => "Hook",
        "kind" => "webhook",
        "content_types" => ["ai"],
        "url" => "https://mod.example/check",
        "secret" => "s3cret"
      })

    {:ok, rule} = Rules.update_rule(scope, rule, %{"secret" => "", "name" => "Hook 2"})
    assert Repo.reload(rule).secret == "s3cret"
    {:ok, rule} = Rules.update_rule(scope, rule, %{"clear_secret" => "true"})
    assert Repo.reload(rule).secret == nil
  end

  test "rules need moderation.rules.manage" do
    user = scope!(%{role: :user})
    assert {:error, :unauthorized} = Rules.list_rules(user)
    assert {:error, :unauthorized} = Rules.create_rule(user, @regex)
    {:ok, rule} = Rules.create_rule(scope!(), @regex)
    assert {:error, :unauthorized} = Rules.delete_rule(user, rule)
    assert [%Rule{}] = Enum.filter(Rules.enabled_for(:characters), &(&1.id == rule.id))
    assert Enum.all?(Rules.enabled_for(:chats), &(&1.id != rule.id))
  end
end
