defmodule Mythweaver.BundleTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Mythweaver.Bundle
  alias Mythweaver.Schema

  @invalid "This isn't a valid Mythweaver bundle."

  defp bundle do
    chat_uid = Schema.generate_id()
    bytes = :crypto.strong_rand_bytes(64)
    blob_uid = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    %Bundle{
      meta: %{"title" => "Aria"},
      items: [
        %{
          uid: Schema.generate_id(),
          kind: :lore_entry,
          name: "Home",
          root: false,
          position: 0,
          data: %{"content" => "A"}
        },
        %{
          uid: Schema.generate_id(),
          kind: :character,
          name: "Aria",
          root: true,
          position: 1,
          data: %{"name" => "Aria", "avatar" => blob_uid, "tags" => ["series:x"], "talkativeness" => 0.5}
        },
        %{uid: chat_uid, kind: :chat, name: "Chat", root: true, position: 2, data: %{"name" => nil}}
      ],
      messages: %{
        chat_uid => [
          %{"uid" => Schema.generate_id(), "author_name" => "Aria", "bodies" => [%{"content" => "Hi"}]},
          %{"uid" => Schema.generate_id(), "author_name" => "Bo", "bodies" => [%{"content" => "Yo"}]}
        ]
      },
      blobs: %{
        blob_uid => %{kind: :image, content_type: "image/png", filename: "a.png", description: nil, bytes: bytes}
      }
    }
  end

  # Rewrites the database inside `encoded` with `sql`, keeping a valid zstd frame around it.
  defp tamper(encoded, sql) do
    database = encoded |> :zstd.decompress() |> IO.iodata_to_binary()
    {:ok, db} = Sqlite3.open(":memory:")
    :ok = Sqlite3.deserialize(db, "main", database)
    :ok = Sqlite3.execute(db, sql)
    {:ok, database} = Sqlite3.serialize(db, "main")
    :ok = Sqlite3.close(db)
    database |> :zstd.compress() |> IO.iodata_to_binary()
  end

  test "encode then decode returns the same items, messages and blobs" do
    bundle = bundle()

    assert {:ok, decoded} = bundle |> Bundle.encode() |> Bundle.decode()
    assert decoded.items == bundle.items
    assert decoded.messages == bundle.messages
    assert decoded.blobs == bundle.blobs
    assert %{"format" => "mythweaver-bundle", "version" => "1", "title" => "Aria", "exported_at" => _} = decoded.meta
  end

  test "an empty bundle round-trips" do
    assert {:ok, %Bundle{items: [], messages: %{}, blobs: %{}}} = %Bundle{} |> Bundle.encode() |> Bundle.decode()
  end

  test "decode rejects input that isn't a bundle" do
    assert Bundle.decode(:crypto.strong_rand_bytes(200)) == {:error, @invalid}
    assert Bundle.decode("") == {:error, @invalid}

    random_frame = :crypto.strong_rand_bytes(5000) |> :zstd.compress() |> IO.iodata_to_binary()
    assert Bundle.decode(random_frame) == {:error, @invalid}
  end

  test "decode rejects a frame without a declared size, or whose size doesn't match it" do
    database = bundle() |> Bundle.encode() |> :zstd.decompress()
    {:ok, context} = :zstd.context(:compress)
    {:continue, head} = :zstd.stream(context, database)
    {:done, tail} = :zstd.finish(context, "")
    assert Bundle.decode(IO.iodata_to_binary([head, tail])) == {:error, @invalid}

    encoded = Bundle.encode(bundle())
    extra = "more" |> :zstd.compress() |> IO.iodata_to_binary()
    assert Bundle.decode(encoded <> extra) == {:error, @invalid}
    assert Bundle.decode(binary_part(encoded, 0, byte_size(encoded) - 8)) == {:error, @invalid}
  end

  test "decode rejects a frame declaring more than 1 GiB" do
    # Magic, a single-segment descriptor with an 8-byte content size, then 2 GiB.
    header = <<0xFD2FB528::little-32, 0xE0, Bitwise.bsl(1, 31)::little-64>>
    assert Bundle.decode(header) == {:error, "This bundle is too large."}
  end

  test "decode rejects a wrong application_id" do
    encoded = bundle() |> Bundle.encode() |> tamper("PRAGMA application_id = 0")
    assert Bundle.decode(encoded) == {:error, @invalid}
  end

  test "decode rejects a schema with a trigger or a view" do
    trigger = "CREATE TRIGGER t AFTER INSERT ON meta BEGIN DELETE FROM meta; END"
    assert bundle() |> Bundle.encode() |> tamper(trigger) |> Bundle.decode() == {:error, @invalid}

    view = "CREATE VIEW v AS SELECT * FROM items"
    assert bundle() |> Bundle.encode() |> tamper(view) |> Bundle.decode() == {:error, @invalid}
  end

  test "decode rejects a newer format version" do
    encoded = bundle() |> Bundle.encode() |> tamper("PRAGMA user_version = 2")
    assert Bundle.decode(encoded) == {:error, "This bundle needs a newer Mythweaver."}
  end

  test "decode rejects missing tables, bad JSON and unknown kinds" do
    assert bundle() |> Bundle.encode() |> tamper("DROP TABLE blobs") |> Bundle.decode() == {:error, @invalid}

    bad_json = "UPDATE items SET data = '{not json' WHERE kind = 'chat'"
    assert bundle() |> Bundle.encode() |> tamper(bad_json) |> Bundle.decode() == {:error, @invalid}

    unknown = "UPDATE items SET kind = 'spaceship' WHERE kind = 'chat'"
    assert bundle() |> Bundle.encode() |> tamper(unknown) |> Bundle.decode() == {:error, @invalid}
  end

  test "kinds map atoms to strings both ways" do
    for {atom, string} <- Bundle.kinds(), do: assert(Bundle.kind(string) == atom)
    assert Bundle.kind("spaceship") == nil
    assert Enum.all?(Bundle.decision_kinds(), &Map.has_key?(Bundle.kinds(), &1))
  end

  test "digest is lowercase hex sha256 of the deterministic term" do
    term = %{kind: :character, description: "A", tags: ["x"]}
    expected = :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16(case: :lower)

    assert Bundle.digest(term) == expected
    assert Bundle.digest(term) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "to_embedded then from_embedded keeps items and messages, without blobs" do
    bundle = bundle()
    embedded = bundle |> Bundle.to_embedded("abc") |> Jason.encode!() |> Jason.decode!()

    assert %{"version" => 1, "digest" => "abc", "roots" => [_, _], "messages" => [_, _]} = embedded
    assert {:ok, decoded} = Bundle.from_embedded(embedded)
    assert decoded.items == bundle.items
    assert decoded.messages == bundle.messages
    assert decoded.blobs == %{}
  end

  test "from_embedded refuses wrong versions and shapes" do
    good = Bundle.to_embedded(bundle(), "abc") |> Jason.encode!() |> Jason.decode!()
    [item | rest] = good["items"]

    assert Bundle.from_embedded(%{good | "version" => 2}) == :error
    assert Bundle.from_embedded(%{good | "items" => %{}}) == :error
    assert Bundle.from_embedded(%{good | "items" => [%{item | "kind" => "spaceship"} | rest]}) == :error
    assert Bundle.from_embedded(%{good | "items" => [%{item | "uid" => "nope"} | rest]}) == :error
    assert Bundle.from_embedded(%{good | "items" => [item, item | rest]}) == :error
    assert Bundle.from_embedded(%{good | "roots" => [Schema.generate_id()]}) == :error
    assert Bundle.from_embedded(%{good | "messages" => [%{"uid" => "x"}]}) == :error
    assert Bundle.from_embedded(Map.delete(good, "items")) == :error
    assert {:ok, %Bundle{messages: %{}}} = Bundle.from_embedded(Map.delete(good, "messages"))
  end
end
