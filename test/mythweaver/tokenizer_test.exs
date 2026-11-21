defmodule Mythweaver.TokenizerTest do
  use ExUnit.Case, async: false

  alias Mythweaver.AI.HuggingFace
  alias Mythweaver.AI.Model
  alias Mythweaver.Tokenizer

  # Failed loads log a warning by design.
  @moduletag :capture_log

  @fixture File.read!("test/support/fixtures/word_level_tokenizer.json")

  setup do
    File.rm_rf!(Tokenizer.cache_dir())
    :ok
  end

  test "a model without a tokenizer gets the chars / 3.3 estimate" do
    assert Tokenizer.count(nil, "abcdefgh") == {3, :estimate}
    refute Tokenizer.exact?(%Model{tokenizer: nil})
  end

  test "blank text is exactly zero" do
    assert Tokenizer.count(%Model{tokenizer: nil}, "") == {0, :exact}
  end

  test "a downloaded tokenizer counts exactly" do
    stub_fixture()
    model = %Model{tokenizer: "test/word-level"}

    assert Tokenizer.count(model, "hello brave world") == {3, :exact}
    assert Tokenizer.exact?(model)
  end

  test "a repo without a tokenizer.json falls back to the estimate" do
    Req.Test.stub(HuggingFace, &Plug.Conn.send_resp(&1, 404, "not found"))
    model = %Model{tokenizer: "test/missing"}

    assert {_, :estimate} = Tokenizer.count(model, "hello brave world")
    refute Tokenizer.exact?(model)
  end

  test "a downloaded file is reused after the in-memory cache is gone, without a request" do
    stub_fixture()
    model = %Model{tokenizer: "test/disk"}

    assert Tokenizer.count(model, "hello brave world") == {3, :exact}

    :ets.delete(:mythweaver_tokenizers, "test/disk")
    Req.Test.stub(HuggingFace, fn _conn -> flunk("network hit") end)

    assert Tokenizer.count(model, "hello brave world") == {3, :exact}
  end

  test "a corrupt cached file is deleted so the next load downloads again" do
    path = Path.join(Tokenizer.cache_dir(), "test--corrupt.json")
    File.mkdir_p!(Tokenizer.cache_dir())
    File.write!(path, "not json")
    Req.Test.stub(HuggingFace, &Plug.Conn.send_resp(&1, 404, "not found"))

    assert {_, :estimate} = Tokenizer.count(%Model{tokenizer: "test/corrupt"}, "hello")
    refute File.exists?(path)
  end

  test "a download over the size cap is refused and leaves no partial file" do
    previous = Application.fetch_env(:mythweaver, :tokenizer_max_bytes)
    Application.put_env(:mythweaver, :tokenizer_max_bytes, 16)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mythweaver, :tokenizer_max_bytes, value)
        :error -> Application.delete_env(:mythweaver, :tokenizer_max_bytes)
      end
    end)

    stub_fixture()

    assert Tokenizer.ensure("test/too-large") == {:error, :too_large}
    assert Path.wildcard(Path.join(Tokenizer.cache_dir(), "*.part")) == []
  end

  defp stub_fixture, do: Req.Test.stub(HuggingFace, &Plug.Conn.send_resp(&1, 200, @fixture))
end
