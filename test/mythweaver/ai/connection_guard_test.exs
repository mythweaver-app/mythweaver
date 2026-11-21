defmodule Mythweaver.AI.ConnectionGuardTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI

  setup do
    old = Application.get_env(:mythweaver, :ai_req_options)
    Application.put_env(:mythweaver, :ai_req_options, [])
    on_exit(fn -> Application.put_env(:mythweaver, :ai_req_options, old) end)
  end

  defp provider!(scope, name, attrs, opts \\ []) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        Map.merge(%{name: name, adapter: :openai_compatible, base_url: "http://localhost:8080/v1"}, attrs),
        opts
      )

    provider
  end

  defp model!(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, model} = AI.create_model(scope, Map.merge(%{name: name, api_model_id: "gemma-4"}, attrs), opts)
    model
  end

  describe "private addresses" do
    test "a user's personal connection may not reach a local address" do
      scope = scope!(%{role: :user})
      provider = provider!(scope, "Local", %{base_url: "http://127.0.0.1:1"})
      model = model!(scope, "Gemma")
      {:ok, link} = AI.link_model(scope, provider, model)

      assert {:error, {:transport_error, message}} = AI.test_link(scope, AI.get_link(link.id))
      assert message =~ "127.0.0.1 is a private or local network address"
    end

    test "a site connection may" do
      admin = scope!()
      provider = provider!(admin, "Local", %{base_url: "http://127.0.0.1:1"}, site: true)
      model = model!(admin, "Gemma", %{}, site: true)
      {:ok, link} = AI.link_model(admin, provider, model)

      assert {:error, {:transport_error, message}} = AI.test_link(admin, AI.get_link(link.id))
      refute message =~ "private or local network address"
    end

    test "an AI admin's personal connection may" do
      admin = scope!()
      provider = provider!(admin, "Local", %{base_url: "http://127.0.0.1:1"})
      model = model!(admin, "Gemma")
      {:ok, link} = AI.link_model(admin, provider, model)

      assert {:error, {:transport_error, message}} = AI.test_link(admin, AI.get_link(link.id))
      refute message =~ "private or local network address"
    end
  end
end
