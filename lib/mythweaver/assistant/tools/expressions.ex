defmodule Mythweaver.Assistant.Tools.Expressions do
  @moduledoc """
  Assistant tools over `Mythweaver.Expressions`: rule profiles, a character's outfits and sprites,
  and its expression settings. Sprite images are uploaded in the app, never here.
  """

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Expressions
  alias Mythweaver.Expressions.Outfit
  alias Mythweaver.Expressions.Profile
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Ownership

  @profile_keys ~w(name rules)
  @settings_keys ~w(expression_labels fallback_expression expression_profile_id)

  @id %{"type" => "string", "description" => "Id."}

  @condition_item %{
    "type" => "object",
    "properties" => %{
      "label" => %{"type" => "string", "description" => "Emotion label, e.g. joy."},
      "min" => %{"type" => "integer", "minimum" => 0, "maximum" => 100, "description" => "Percent, inclusive."},
      "max" => %{"type" => "integer", "minimum" => 0, "maximum" => 100, "description" => "Percent, inclusive."}
    },
    "required" => ["label"]
  }

  @rule_item %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string", "description" => "The derived label this rule produces, e.g. smug."},
      "kind" => %{
        "type" => "string",
        "enum" => ~w(range combination),
        "description" =>
          "range: each condition's score is within min..max. combination: the listed emotions all score above " <>
            "zero and within max_difference of the strongest."
      },
      "max_difference" => %{
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 100,
        "description" => "Combination only: percent spread allowed from the strongest emotion."
      },
      "enabled" => %{"type" => "boolean", "description" => "Default true."},
      "conditions" => %{"type" => "array", "items" => @condition_item, "description" => "The rule's emotions."}
    },
    "required" => ["name", "kind"]
  }

  @profile_props %{
    "name" => %{"type" => "string", "description" => "Profile name."},
    "rules" => %{"type" => "array", "items" => @rule_item, "description" => "Replaces the whole rule list when given."}
  }

  def tools do
    profiles = {"expression profile", "expression profiles"}

    profile_label = fn scope, id ->
      with %Profile{name: name} <- Expressions.get_editable_profile(scope, id), do: name
    end

    outfit_label = fn scope, id -> with %Outfit{name: name} <- Expressions.get_editable_outfit(scope, id), do: name end

    sprite_label = fn scope, id ->
      with %Sprite{label: label} <- Expressions.get_editable_sprite(scope, id), do: label
    end

    character_label = fn scope, id ->
      with %Character{name: name} <- Characters.get_editable_character(scope, id), do: name
    end

    [
      %Tool{
        name: "list_expression_profiles",
        description: "List the expression rule profiles the user may use, optionally searched by name.",
        parameters: object(%{"query" => Args.query_property()}, []),
        kind: :read,
        summary: fn _ -> "List expression profiles" end,
        run: fn scope, args ->
          rows =
            for p <- Expressions.list_profiles(scope) do
              %{
                "id" => p.id,
                "name" => p.name,
                "rule_count" => length(p.rules),
                "owner" => Args.owner(p),
                "editable" => Ownership.authorize_edit(scope, p) == :ok,
                "path" => Paths.expression_profile(p.id)
              }
            end

          {:ok, Args.list("expression_profiles", Args.by_name(rows, args["query"]))}
        end
      },
      %Tool{
        name: "get_expression_profile",
        description: "An expression rule profile and its rules.",
        parameters: object(%{"id" => @id}, ["id"]),
        kind: :read,
        summary: fn _ -> "Read an expression profile" end,
        run: fn scope, args ->
          with {:ok, profile} <- fetch(&Expressions.get_profile/2, scope, args["id"]), do: {:ok, profile_map(profile)}
        end
      },
      Batch.items("create_expression_profiles",
        description:
          "Create expression rule profiles. Range rules need min or max per condition; combination rules need at " <>
            "least two different emotion labels.",
        verb: "Create",
        noun: profiles,
        item: object(@profile_props, ["name"]),
        run: fn scope, args ->
          scope |> Expressions.create_profile(Args.attrs(args, @profile_keys)) |> Args.wrap(&profile_map/1)
        end
      ),
      Batch.items("update_expression_profiles",
        description: "Change expression profiles' name or rules; rules given replace the whole list.",
        verb: "Update",
        noun: profiles,
        label: profile_label,
        item: object(Map.put(@profile_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, profile} <- fetch(&Expressions.get_editable_profile/2, scope, args["id"]) do
            scope |> Expressions.update_profile(profile, Args.attrs(args, @profile_keys)) |> Args.wrap(&profile_map/1)
          end
        end
      ),
      Batch.ids("delete_expression_profiles",
        description: "Delete expression rule profiles. Characters using one fall back to the default profile.",
        verb: "Delete",
        noun: profiles,
        label: profile_label,
        run: fn scope, args ->
          with {:ok, profile} <- fetch(&Expressions.get_editable_profile/2, scope, args["id"]) do
            scope |> Expressions.delete_profile(profile) |> Args.wrap(&deleted(&1, &1.name))
          end
        end
      ),
      %Tool{
        name: "list_character_outfits",
        description: "List a character's expression outfits (named sprite sets), in order.",
        parameters: object(%{"character_id" => @id}, ["character_id"]),
        kind: :read,
        summary: fn _ -> "List a character's outfits" end,
        run: fn scope, args ->
          with {:ok, character} <- fetch(&Characters.get_character/2, scope, args["character_id"], "character_id") do
            rows = for o <- Expressions.list_outfits(scope, character), do: outfit_map(o)
            {:ok, Args.list("outfits", rows)}
          end
        end
      },
      Batch.items("create_character_outfits",
        description: "Create named expression outfits (sets of sprites) on characters.",
        verb: "Create",
        noun: {"outfit", "outfits"},
        item:
          object(%{"character_id" => @id, "name" => %{"type" => "string", "description" => "Outfit name."}}, [
            "character_id",
            "name"
          ]),
        run: fn scope, args ->
          with {:ok, character} <-
                 fetch(&Characters.get_editable_character/2, scope, args["character_id"], "character_id") do
            scope |> Expressions.create_outfit(character, args["name"]) |> Args.wrap(&outfit_map/1)
          end
        end
      ),
      Batch.ids("delete_character_outfits",
        description: "Delete expression outfits with their sprites and files.",
        verb: "Delete",
        noun: {"outfit", "outfits"},
        label: outfit_label,
        run: fn scope, args ->
          with {:ok, outfit} <- fetch(&Expressions.get_editable_outfit/2, scope, args["id"]) do
            scope |> Expressions.delete_outfit(outfit) |> Args.wrap(&deleted(&1, &1.name))
          end
        end
      ),
      %Tool{
        name: "list_character_sprites",
        description:
          "List a character's expression sprites: label, outfit (null is the Default set) and thumbnail URL.",
        parameters: object(%{"character_id" => @id}, ["character_id"]),
        kind: :read,
        summary: fn _ -> "List a character's sprites" end,
        run: fn scope, args ->
          with {:ok, character} <- fetch(&Characters.get_character/2, scope, args["character_id"], "character_id") do
            rows =
              for s <- Expressions.list_sprites(scope, character) do
                %{
                  "id" => s.id,
                  "label" => s.label,
                  "outfit_id" => s.outfit_id,
                  "url" => Attachments.url(s.attachment, :thumb)
                }
              end

            {:ok, Args.list("sprites", rows)}
          end
        end
      },
      Batch.ids("delete_character_sprites",
        description: "Delete expression sprite images and their files.",
        verb: "Delete",
        noun: {"sprite", "sprites"},
        label: sprite_label,
        run: fn scope, args ->
          with {:ok, sprite} <- fetch(&Expressions.get_editable_sprite/2, scope, args["id"]) do
            scope
            |> Expressions.delete_sprite(sprite)
            |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "label" => &1.label})
          end
        end
      ),
      Batch.items("update_character_expression_settings",
        description:
          "Change characters' custom expression labels, fallback label or rule profile. Only given fields change.",
        verb: "Update",
        noun: {"character", "characters"},
        label: character_label,
        item:
          object(
            %{
              "id" => Map.put(@id, "description", "Character id."),
              "expression_labels" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Custom labels, lowercase a-z/0-9/_, 1-40 chars each, besides the 28 base emotions."
              },
              "fallback_expression" => %{"type" => "string", "description" => "Label shown when nothing else matches."},
              "expression_profile_id" => %{
                "type" => ["string", "null"],
                "description" => "Rule profile id, or null to fall back to the default profile."
              }
            },
            ["id"]
          ),
        run: fn scope, args ->
          with {:ok, character} <- fetch(&Characters.get_editable_character/2, scope, args["id"]) do
            scope
            |> Expressions.update_settings(character, Args.attrs(args, @settings_keys))
            |> Args.wrap(&settings_map/1)
          end
        end
      )
    ]
  end

  defp fetch(getter, scope, id, key \\ "id") do
    with {:ok, id} <- Args.uuid(%{key => id}, key) do
      case getter.(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        row -> {:ok, row}
      end
    end
  end

  defp object(props, required), do: %{"type" => "object", "properties" => props, "required" => required}

  defp deleted(row, name), do: %{"deleted" => true, "id" => row.id, "name" => name}

  defp profile_map(%Profile{} = p) do
    %{
      "id" => p.id,
      "name" => p.name,
      "owner" => Args.owner(p),
      "path" => Paths.expression_profile(p.id),
      "rules" =>
        for r <- p.rules do
          %{
            "name" => r.name,
            "kind" => to_string(r.kind),
            "max_difference" => r.max_difference,
            "enabled" => r.enabled,
            "conditions" => Enum.map(r.conditions, &%{"label" => &1.label, "min" => &1.min, "max" => &1.max})
          }
        end
    }
  end

  defp outfit_map(%Outfit{} = o),
    do: %{"id" => o.id, "name" => o.name, "position" => o.position, "character_id" => o.character_id}

  defp settings_map(%Character{} = c) do
    %{
      "id" => c.id,
      "expression_labels" => c.expression_labels,
      "fallback_expression" => c.fallback_expression,
      "expression_profile_id" => c.expression_profile_id,
      "path" => Paths.character(c.id)
    }
  end
end
