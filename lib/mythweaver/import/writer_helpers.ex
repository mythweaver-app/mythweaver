defmodule Mythweaver.Import.WriterHelpers do
  @moduledoc false
  # Shared by `Mythweaver.Import.Writer` and `Mythweaver.Import.BundleWriter`.

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Mythweaver.Attachments
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Tags

  @doc ~s{`base`, or the first of "base (2)", "base (3)", … not in `taken`.}
  def unique_name(base, taken) do
    taken = MapSet.new(taken)

    [base]
    |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base} (#{&1})"))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc """
  The outlet `key` names for rows owned by `owner_id`: the existing one, else a new outlet from
  `spec` (`key`, `name`, optional `description`). Returns the outlet.
  """
  def ensure_outlet(scope, owner_id, %{key: key} = spec) do
    case Prompts.get_outlet_by_key(owner_id, key) do
      nil -> ok!(Prompts.create_outlet(scope, Map.take(spec, [:key, :name, :description])))
      outlet -> outlet
    end
  end

  @doc """
  The pool named `name` owned by `owner_id`, else a new one admitting one entry: a SillyTavern
  inclusion group matches by name across books, so imports reuse a same-name pool.
  """
  def ensure_pool(scope, owner_id, name) do
    query = from(p in Ownership.owned_exactly(LorePool, owner_id), where: p.name == ^name, limit: 1)

    case Repo.one(query) do
      nil -> ok!(Lore.create_pool(scope, %{name: name, max_activations: 1}, site: is_nil(owner_id)))
      pool -> pool
    end
  end

  @doc """
  Tags `character` with a card's `tags`, in the site's domain for a site character, else the
  user's own; warnings. A tag the domain refuses is dropped and the rest retried. Call after the
  commit.
  """
  def store_tags(_scope, _character, []), do: []

  def store_tags(scope, character, tags) do
    domain = if is_nil(character.user_id), do: :site, else: :mine

    case Tags.set_item_tags(scope, character, domain, tags) do
      :ok ->
        []

      {:error, {:invalid, text, reason}} ->
        rest = List.delete(tags, text)

        warning =
          dgettext("import_export", "Tag '%{tag_text}' wasn't imported: %{reason}.", tag_text: text, reason: reason)

        if rest == tags,
          do: [warning, tags_failed()],
          else: [warning | store_tags(scope, character, rest)]

      {:error, _reason} ->
        [tags_failed()]
    end
  end

  @doc "Stores `bytes` as `character`'s avatar; warnings. Call after the commit (caption jobs)."
  def store_avatar(_scope, _character, nil), do: []

  def store_avatar(scope, character, bytes) when is_binary(bytes) do
    with {:ok, attachment} <- Attachments.store_upload(scope, bytes),
         :ok <- Attachments.set_avatar(scope, character, attachment) do
      []
    else
      _error -> [dgettext("import_export", "The avatar couldn't be saved.")]
    end
  end

  def store_avatar(_scope, _character, _bytes), do: []

  def transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def ok!({:ok, value}), do: value
  def ok!({:error, reason}), do: Repo.rollback(reason)

  def message(message) when is_binary(message), do: message
  def message(:unauthorized), do: dgettext("import_export", "You're not allowed to create that here.")
  def message(:quota_exceeded), do: dgettext("import_export", "That would go over your quota.")

  def message(%Changeset{} = changeset) do
    case first_error(changeset) do
      {field, error} ->
        gettext_comment("Import error; the placeholders are a field name and its validation error.")

        dpgettext(
          "import_export",
          "status: an import failed on an invalid field",
          "Couldn't import: %{field_name} %{field_error}",
          field_name: field,
          field_error: error
        )

      nil ->
        failed()
    end
  end

  def message(_reason), do: failed()

  defp failed, do: dpgettext("import_export", "status: an import failed for an unknown reason", "Couldn't import.")
  defp tags_failed, do: dgettext("import_export", "The card's tags couldn't be imported.")

  def first_error(changeset) do
    changeset
    |> traverse()
    |> Enum.find_value(fn {field, [error | _]} -> {field, error} end)
  end

  def errors(changeset) do
    changeset
    |> traverse()
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  # Changeset messages are `errors` msgids, translated as `MythweaverWeb.CoreComponents.translate_error/1` does.
  defp traverse(changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      if count = opts[:count],
        do: Gettext.dngettext(Mythweaver.Gettext, "errors", msg, msg, count, opts),
        else: Gettext.dgettext(Mythweaver.Gettext, "errors", msg, opts)
    end)
    |> flatten()
  end

  # Nested (embed/assoc) errors become `parent.child` fields with string messages.
  defp flatten(errors) do
    Enum.flat_map(errors, fn
      {field, [message | _] = messages} when is_binary(message) ->
        [{to_string(field), messages}]

      {field, nested} when is_map(nested) ->
        for {child, messages} <- flatten(nested), do: {"#{field}.#{child}", messages}

      {field, nested} when is_list(nested) ->
        nested
        |> Enum.filter(&is_map/1)
        |> Enum.flat_map(&flatten/1)
        |> Enum.map(fn {child, messages} -> {"#{field}.#{child}", messages} end)

      _empty ->
        []
    end)
  end
end
