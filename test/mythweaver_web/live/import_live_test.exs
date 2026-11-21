defmodule MythweaverWeb.ImportLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Export
  alias Mythweaver.Import
  alias Mythweaver.Import.Review

  setup :register_and_log_in_user

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  test "a character card PNG is parsed, imported and opened", %{scope: scope, conn: conn} do
    card = %{
      "spec" => "chara_card_v2",
      "spec_version" => "2.0",
      "data" => %{"name" => "Seraphina", "description" => "A guardian of the forest.", "personality" => "Kind"}
    }

    png = card_png([{"chara", Base.encode64(Jason.encode!(card))}])

    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> file_input("#import-upload-form", :import_files, [%{name: "card.png", content: png, type: "image/png"}])
    |> render_upload("card.png")

    [ref] = item_ids(view)
    assert has_element?(view, "#import-item-form-#{ref}")

    view |> element("#import-item-form-#{ref}") |> render_submit()

    assert has_element?(view, "#import-item-open-#{ref}")
    assert Characters.find_character_by_name(scope, "Seraphina")
  end

  test "a chat maps its speakers to characters", %{scope: scope, conn: conn} do
    {:ok, aqua} = Characters.create_character(scope, %{name: "Aqua"})

    jsonl =
      [
        %{"user_name" => "Aqua", "character_name" => "Kazuma", "create_date" => "2024-01-01T10:00:00Z"},
        %{"name" => "Aqua", "is_user" => true, "mes" => "Hi", "send_date" => 1_704_103_200_000},
        %{"name" => "Kazuma", "is_user" => false, "mes" => "Hello", "send_date" => 1_704_103_260_000}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    {:ok, %{speakers: speakers}} = Import.parse("chat.jsonl", jsonl)
    aqua_key = Enum.find(speakers, &(&1.name == "Aqua")).key
    kazuma_key = Enum.find(speakers, &(&1.name == "Kazuma")).key

    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> file_input("#import-upload-form", :import_files, [
      %{name: "chat.jsonl", content: jsonl, type: "application/jsonl"}
    ])
    |> render_upload("chat.jsonl")

    [ref] = item_ids(view)
    assert has_element?(view, "#import-item-#{ref}-player")
    assert has_element?(view, "#import-item-#{ref}-speaker-#{kazuma_key}")

    view
    |> form("#import-item-form-#{ref}",
      import: %{
        player: to_string(aqua_key),
        speakers: %{
          to_string(aqua_key) => "character:#{aqua.id}",
          to_string(kazuma_key) => "create"
        }
      }
    )
    |> render_submit()

    assert has_element?(view, "#import-item-open-#{ref}")

    [chat] = Chats.list_chats(scope)
    chat = Chats.get_chat!(scope, chat.id)
    assert chat.player_character_id == aqua.id
    assert length(chat.participants) == 2
  end

  test "a Mythweaver bundle gets a decision per item", %{scope: scope, conn: conn} do
    {:ok, character} = Characters.create_character(scope, %{name: "Bundled"})
    {:ok, request} = Export.request(%{"items" => ["character:#{character.id}"], "format" => "native"})
    {:ok, %{bytes: bytes}} = Export.build(scope, request)
    {:ok, parsed} = Import.parse("Bundled.mythweaver", bytes)
    [row] = Review.review(scope, parsed.bundle)

    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> file_input("#import-upload-form", :import_files, [
      %{name: "Bundled.mythweaver", content: bytes, type: "application/vnd.mythweaver.bundle"}
    ])
    |> render_upload("Bundled.mythweaver")

    [ref] = item_ids(view)
    assert has_element?(view, "#import-item-#{ref}-decision-#{row.uid}")

    view
    |> form("#import-item-form-#{ref}", import: %{decisions: %{row.uid => "copy"}})
    |> render_submit()

    assert has_element?(view, "#import-item-open-#{ref}")
    assert length(Enum.filter(Characters.list_characters(scope), &(&1.name == "Bundled"))) == 2
  end

  defp item_ids(view) do
    ~r/id="import-item-form-([^"]+)"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> List.flatten()
  end

  # Inserts tEXt chunks just before the 1x1 PNG's IEND chunk.
  defp card_png(chunks) do
    iend_size = 12
    body = binary_part(@png, 0, byte_size(@png) - iend_size)
    iend = binary_part(@png, byte_size(@png) - iend_size, iend_size)

    text =
      for {keyword, value} <- chunks, into: <<>> do
        data = keyword <> <<0>> <> value
        <<byte_size(data)::32, "tEXt", data::binary, :erlang.crc32("tEXt" <> data)::32>>
      end

    body <> text <> iend
  end
end
