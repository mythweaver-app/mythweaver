defmodule Mythweaver.Tags do
  @moduledoc """
  The Tags context: Hydrus-style namespaced tags, siblings and parents.

  A tag row belongs to one domain, like a Hydrus tag service: the site's (`user_id` nil, curated by
  `"site.content.manage"` holders, seen by everyone) or one user's own (only they see it). Identity
  is the canonical text across domains: the site and a user may both have a `lotr` row and every
  read treats them as one tag.

  A *viewer* is an owner id (`scope.user.id` in the UI, `chat.user_id` at runtime); it sees site rows
  plus its own (`Ownership.for_owner/2`). `graph/1` resolves the viewer's siblings (its own rules
  beat the site's for the same text) and parents (both domains union) into a `Tags.Graph`; items
  store only hard tags, and the graph expands them on read.

  Writes: site taggings only on site items, by a scope that edits the item and holds
  `"site.content.manage"`; personal taggings by their owner on any item it can see. Chats are never
  site items. Creating a missing personal tag row needs `"content.tags.create"`.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Changes
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Ownership
  alias Mythweaver.Repo
  alias Mythweaver.Tags.Graph
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Tags.Tagging
  alias Mythweaver.Tags.TagParent

  @type predicate :: Graph.predicate()

  ## Text

  @doc """
  Normalizes typed tag text: trims, downcases, collapses whitespace, and splits at the first `:`
  into namespace and name. Returns `{namespace, name, canonical_text}` or a human error.
  """
  @spec normalize(String.t()) :: {:ok, {String.t(), String.t(), String.t()}} | {:error, String.t()}
  def normalize(text) when is_binary(text) do
    text = text |> String.trim() |> String.downcase() |> String.replace(~r/\s+/u, " ")

    {namespace, name} =
      case String.split(text, ":", parts: 2) do
        [name] -> {"", name}
        [namespace, name] -> {String.trim(namespace), String.trim(name)}
      end

    cond do
      name == "" -> {:error, dgettext_noop("errors", "needs a name")}
      String.starts_with?(text, "-") -> {:error, dgettext_noop("errors", "can't start with -")}
      String.contains?(text, "*") -> {:error, dgettext_noop("errors", "can't contain *")}
      String.length(namespace) > 64 or String.length(name) > 200 -> {:error, dgettext_noop("errors", "is too long")}
      true -> {:ok, {namespace, name, Tag.text(%{namespace: namespace, name: name})}}
    end
  end

  @doc "The namespace of a canonical text (`\"\"` when it has none)."
  @spec namespace(String.t()) :: String.t()
  def namespace(text) do
    case String.split(text, ":", parts: 2) do
      [namespace, _name] -> namespace
      [_name] -> ""
    end
  end

  @doc "A stable hue for a namespace's chips."
  @spec namespace_hue(String.t()) :: 0..359
  def namespace_hue(namespace), do: :erlang.phash2(namespace, 360)

  @doc "Namespaced texts first, then plain ones; each group by text."
  @spec sort([String.t()]) :: [String.t()]
  def sort(texts), do: Enum.sort_by(texts, &{namespace(&1) == "", &1})

  @doc """
  Parses filter chips: a leading `-` excludes, `ns:*` matches any tag in namespace `ns`, anything
  else is a tag text. Valid chips come back as predicates, invalid ones as `{raw, message}`.
  """
  @spec parse_predicates([String.t()]) :: {[predicate()], [{String.t(), String.t()}]}
  def parse_predicates(raws) do
    {predicates, errors} =
      Enum.reduce(raws, {[], []}, fn raw, {predicates, errors} ->
        case parse_predicate(raw) do
          {:ok, predicate} -> {[predicate | predicates], errors}
          {:error, message} -> {predicates, [{raw, message} | errors]}
        end
      end)

    {Enum.reverse(predicates), Enum.reverse(errors)}
  end

  defp parse_predicate(raw) do
    trimmed = String.trim(raw)

    {direction, rest} =
      case trimmed do
        "-" <> rest -> {:exclude, String.trim(rest)}
        rest -> {:include, rest}
      end

    cond do
      rest == "" ->
        {:error, dgettext_noop("errors", "needs a tag")}

      String.ends_with?(rest, ":*") ->
        namespace = rest |> String.trim_trailing(":*") |> String.trim() |> String.downcase()
        namespace = String.replace(namespace, ~r/\s+/u, " ")

        if namespace == "" or String.contains?(namespace, ["*", ":"]),
          do: {:error, wildcard_error()},
          else: {:ok, {direction, {:namespace, namespace}}}

      String.contains?(rest, "*") ->
        {:error, wildcard_error()}

      true ->
        with {:ok, {_ns, _name, text}} <- normalize(rest), do: {:ok, {direction, {:tag, text}}}
    end
  end

  defp wildcard_error, do: dgettext_noop("errors", "* must be a namespace wildcard like series:*")

  @doc """
  The translated `"raw: message"` line for a chip that `normalize/1` or `parse_predicates/1`
  refused with `message`.
  """
  @spec problem_text(String.t(), String.t()) :: String.t()
  def problem_text(raw, "needs a name"),
    do: dpgettext("tags", "status: why a typed tag was refused", "%{tag_text}: needs a name", tag_text: raw)

  def problem_text(raw, "can't start with -"),
    do: dpgettext("tags", "status: why a typed tag was refused", "%{tag_text}: can't start with -", tag_text: raw)

  def problem_text(raw, "can't contain *"),
    do: dpgettext("tags", "status: why a typed tag was refused", "%{tag_text}: can't contain *", tag_text: raw)

  def problem_text(raw, "is too long"),
    do: dpgettext("tags", "status: why a typed tag was refused", "%{tag_text}: is too long", tag_text: raw)

  def problem_text(raw, "needs a tag"),
    do: dpgettext("tags", "status: why a typed tag was refused", "%{tag_text}: needs a tag", tag_text: raw)

  def problem_text(raw, "* must be a namespace wildcard like series:*"),
    do:
      dpgettext(
        "tags",
        "status: why a typed tag was refused",
        "%{tag_text}: * must be a namespace wildcard like series:*", tag_text: raw)

  @doc """
  Normalizes a form's tag chips (`""` dropped): `{values, invalid, errors}`, where `values` keeps
  each valid chip as canonical text and each invalid one as typed (deduplicated, in order),
  `invalid` lists the invalid ones and `errors` their `"raw: message"` lines.
  """
  @spec normalize_list([String.t()] | String.t() | nil) :: {[String.t()], [String.t()], [String.t()]}
  def normalize_list(raws) do
    {values, invalid, errors} =
      raws
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({[], [], []}, fn raw, {values, invalid, errors} ->
        case normalize(raw) do
          {:ok, {_namespace, _name, text}} -> {[text | values], invalid, errors}
          {:error, message} -> {[raw | values], [raw | invalid], [problem_text(raw, message) | errors]}
        end
      end)

    {values |> Enum.reverse() |> Enum.uniq(), Enum.reverse(invalid), errors |> Enum.reverse() |> Enum.uniq()}
  end

  ## Graph

  @doc "Viewer `owner_id`'s resolved siblings and parents (nil: the site's alone)."
  @spec graph(Ecto.UUID.t() | nil) :: Graph.t()
  def graph(owner_id) do
    siblings =
      from(t in Tag,
        join: i in Tag,
        on: i.id == t.ideal_id,
        select: {is_nil(t.user_id), t.namespace, t.name, i.namespace, i.name}
      )
      |> Ownership.for_owner(owner_id)
      |> Repo.all()
      |> Enum.map(fn {site?, ns, name, ins, iname} ->
        {domain(site?), Tag.text(%{namespace: ns, name: name}), Tag.text(%{namespace: ins, name: iname})}
      end)

    parents =
      from(p in TagParent,
        join: c in Tag,
        as: :tag,
        on: c.id == p.tag_id,
        join: pt in Tag,
        on: pt.id == p.parent_tag_id,
        where: ^visible(owner_id),
        select: {is_nil(c.user_id), c.namespace, c.name, pt.namespace, pt.name}
      )
      |> Repo.all()
      |> Enum.map(fn {site?, ns, name, pns, pname} ->
        {domain(site?), Tag.text(%{namespace: ns, name: name}), Tag.text(%{namespace: pns, name: pname})}
      end)

    Graph.new(siblings, parents)
  end

  defp domain(true), do: :site
  defp domain(false), do: :own

  # The `:tag` binding is a row viewer `owner_id` sees.
  defp visible(nil), do: dynamic([tag: t], is_nil(t.user_id))
  defp visible(owner_id), do: dynamic([tag: t], is_nil(t.user_id) or t.user_id == ^owner_id)

  # The `:tag` binding is a row of exactly `owner_id`'s domain.
  defp exactly(nil), do: dynamic([tag: t], is_nil(t.user_id))
  defp exactly(owner_id), do: dynamic([tag: t], t.user_id == ^owner_id)

  @doc """
  Every tag text viewer `owner_id` sees, with its ideal when that differs and `uses` (how many items
  carry it in the viewer's domains), sorted.
  """
  @spec vocabulary(Ecto.UUID.t() | nil, Graph.t()) ::
          [%{text: String.t(), ideal: String.t() | nil, uses: non_neg_integer()}]
  def vocabulary(owner_id, %Graph{} = graph) do
    counts =
      from(t in Tag,
        left_join: tg in Tagging,
        on: tg.tag_id == t.id,
        group_by: [t.namespace, t.name],
        select: {t.namespace, t.name, count(tg.id)}
      )
      |> Ownership.for_owner(owner_id)
      |> Repo.all()
      |> Map.new(fn {namespace, name, uses} -> {Tag.text(%{namespace: namespace, name: name}), uses} end)

    counts
    |> Map.keys()
    |> sort()
    |> Enum.map(fn text ->
      ideal = Graph.ideal(graph, text)
      %{text: text, ideal: if(ideal != text, do: ideal), uses: Map.fetch!(counts, text)}
    end)
  end

  ## Resolving texts to rows

  @doc """
  The rows of `owner_id`'s domain (nil: the site's) for `texts`, creating missing ones when `scope`
  may (site: `"site.content.manage"`; personal: the owner itself with `"content.tags.create"`).
  Rows come back deduplicated in the order first named.
  """
  @spec ensure_tags(Scope.t(), Ecto.UUID.t() | nil, [String.t()]) ::
          {:ok, [Tag.t()]} | {:error, :unauthorized | {:invalid, String.t(), String.t()}}
  def ensure_tags(%Scope{} = scope, owner_id, texts) do
    with {:ok, parsed} <- normalize_all(texts) do
      parsed = Enum.uniq_by(parsed, &elem(&1, 2))
      existing = load_tags(owner_id, parsed)
      missing = Enum.reject(parsed, &Map.has_key?(existing, elem(&1, 2)))

      cond do
        missing == [] ->
          {:ok, Enum.map(parsed, &Map.fetch!(existing, elem(&1, 2)))}

        not may_create?(scope, owner_id) ->
          {:error, :unauthorized}

        true ->
          Enum.each(missing, fn {namespace, name, _text} ->
            Repo.insert(%Tag{user_id: owner_id, namespace: namespace, name: name}, on_conflict: :nothing)
          end)

          existing = load_tags(owner_id, parsed)
          {:ok, Enum.map(parsed, &Map.fetch!(existing, elem(&1, 2)))}
      end
    end
  end

  defp normalize_all(texts) do
    Enum.reduce_while(texts, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize(raw) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, message} -> {:halt, {:error, {:invalid, raw, message}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp load_tags(_owner_id, []), do: %{}

  defp load_tags(owner_id, parsed) do
    match =
      Enum.reduce(parsed, dynamic(false), fn {namespace, name, _text}, acc ->
        dynamic([t], ^acc or (t.namespace == ^namespace and t.name == ^name))
      end)

    Tag
    |> Ownership.owned_exactly(owner_id)
    |> where(^match)
    |> Repo.all()
    |> Map.new(&{Tag.text(&1), &1})
  end

  defp may_create?(scope, nil), do: Scope.can?(scope, "site.content.manage")

  defp may_create?(%Scope{user: %{id: id}} = scope, id), do: Scope.can?(scope, "content.tags.create")
  defp may_create?(_scope, _owner_id), do: false

  ## Management (`/tags`)

  @doc "Tags `scope` may edit (its own, plus the site's for a content manager), each with `usage_count`."
  @spec list_editable_tags(Scope.t()) :: [Tag.t()]
  def list_editable_tags(%Scope{} = scope) do
    uses = from(tg in Tagging, where: tg.tag_id == parent_as(:tag).id, select: count())

    from(t in Tag,
      as: :tag,
      order_by: [asc: fragment("? = ''", t.namespace), asc: t.namespace, asc: t.name, asc: t.id],
      select_merge: %{usage_count: subquery(uses)},
      preload: [:ideal, :parents]
    )
    |> Ownership.editable(scope)
    |> Repo.all()
  end

  @doc "A tag `scope` may edit, with its ideal and parents, or nil."
  @spec get_editable_tag(Scope.t(), Ecto.UUID.t()) :: Tag.t() | nil
  def get_editable_tag(%Scope{} = scope, id) do
    Tag |> Ownership.editable(scope) |> preload([:ideal, :parents]) |> Repo.get(id)
  end

  @doc "A changeset for the `/tags` form; fills the virtual fields from a row loaded with `[:ideal, :parents]`."
  @spec change_tag(Tag.t(), map()) :: Ecto.Changeset.t()
  def change_tag(%Tag{} = tag, attrs \\ %{}), do: tag |> fill_virtuals() |> Tag.changeset(attrs)

  defp fill_virtuals(%Tag{} = tag) do
    text = tag.text || (tag.name && Tag.text(tag))

    ideal_text =
      tag.ideal_text || (match?(%Tag{}, tag.ideal) && Tag.text(tag.ideal)) || nil

    parent_texts =
      if tag.parent_texts == [] and is_list(tag.parents),
        do: tag.parents |> Enum.map(&Tag.text/1) |> sort(),
        else: tag.parent_texts

    %{tag | text: text, ideal_text: ideal_text, parent_texts: parent_texts}
  end

  @doc """
  Creates a tag with its sibling and parents, `scope`'s own by default (`Ownership.new_owner/3`);
  `site: true` makes it a site tag, which needs `"site.content.manage"`.
  """
  @spec create_tag(Scope.t(), map(), keyword()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_tag(%Scope{} = scope, attrs, opts \\ []) do
    with {:ok, owner} <- Ownership.new_owner(scope, Tag, opts) do
      changeset = change_tag(%Tag{user_id: owner, parents: []}, attrs)
      scope |> save_tag(changeset, :insert) |> Changes.notify(:tags)
    end
  end

  @doc "Updates a tag's text, sibling and parents."
  @spec update_tag(Scope.t(), Tag.t(), map()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_tag(%Scope{} = scope, %Tag{} = tag, attrs) do
    with :ok <- Ownership.authorize_edit(scope, tag) do
      tag = Repo.preload(tag, [:ideal, :parents])
      scope |> save_tag(change_tag(tag, attrs), :update) |> Changes.notify(:tags)
    end
  end

  defp save_tag(scope, changeset, action) do
    old_text = changeset.data.name && Tag.text(changeset.data)

    Repo.transact(fn ->
      with {:ok, saved} <- Repo.insert_or_update(changeset),
           {:ok, ideal} <- resolve_ideal(scope, saved, Ecto.Changeset.get_field(changeset, :ideal_text)),
           {:ok, parents} <- resolve_parents(scope, saved, Ecto.Changeset.get_field(changeset, :parent_texts)),
           :ok <- check_cycles(saved, old_text, ideal, parents) do
        {:ok, saved} = saved |> Ecto.Changeset.change(ideal_id: ideal && ideal.id) |> Repo.update()
        existing = Repo.all(from(p in TagParent, where: p.tag_id == ^saved.id))

        Repo.sync_rows!(
          existing,
          :parent_tag_id,
          MapSet.new(parents, & &1.id),
          &%TagParent{tag_id: saved.id, parent_tag_id: &1}
        )

        {:ok,
         saved
         |> Repo.preload([:ideal, :parents], force: true)
         |> Map.merge(%{text: nil, ideal_text: nil, parent_texts: []})}
      else
        {:error, %Ecto.Changeset{} = invalid} ->
          {:error, invalid}

        {:error, field, {message, bindings}} ->
          changeset |> Ecto.Changeset.add_error(field, message, bindings) |> Ecto.Changeset.apply_action(action)
      end
    end)
  end

  defp resolve_ideal(_scope, _saved, nil), do: {:ok, nil}

  defp resolve_ideal(scope, saved, text) do
    case ensure_tags(scope, saved.user_id, [text]) do
      {:ok, [ideal]} -> {:ok, ideal}
      {:error, reason} -> {:error, :ideal_text, ensure_message(reason)}
    end
  end

  defp resolve_parents(scope, saved, texts) do
    case ensure_tags(scope, saved.user_id, texts) do
      {:ok, parents} -> {:ok, parents}
      {:error, reason} -> {:error, :parent_texts, ensure_message(reason)}
    end
  end

  # Already a whole translated line; `translate_error/1` finds no msgid for it and shows it as is.
  defp ensure_message({:invalid, raw, message}), do: {problem_text(raw, message), []}

  defp ensure_message(:unauthorized), do: {dgettext_noop("errors", "you may not create tags here"), []}

  # Checked in the writing domain's own view (site rows: the site's rules; a user's rows: theirs over
  # the site's), with the change applied in memory.
  defp check_cycles(saved, old_text, ideal, parents) do
    text = Tag.text(saved)
    graph = graph(saved.user_id)
    graph = if old_text && old_text != text, do: Graph.put_ideal(graph, old_text, nil), else: graph
    ideal_text = ideal && Tag.text(ideal)

    if ideal_text && Graph.sibling_cycle?(graph, text, ideal_text) do
      {:error, :ideal_text, {dgettext_noop("errors", "would loop back to this tag"), []}}
    else
      graph = Graph.put_ideal(graph, text, ideal_text)

      parents
      |> Enum.map(&Tag.text/1)
      |> Enum.reduce_while(graph, fn parent, acc ->
        if Graph.parent_cycle?(acc, text, parent),
          do:
            {:halt,
             {:error, :parent_texts,
              {dgettext_noop("errors", "%{tag_text} would loop back to this tag"), tag_text: parent}}},
          else: {:cont, Graph.put_parent(acc, text, parent)}
      end)
      |> case do
        %Graph{} -> :ok
        error -> error
      end
    end
  end

  @doc "Deletes a tag; it leaves every item, filter, sibling and parent rule with it."
  @spec delete_tag(Scope.t(), Tag.t()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_tag(%Scope{} = scope, %Tag{} = tag) do
    with :ok <- Ownership.authorize_edit(scope, tag) do
      tag |> Repo.delete() |> Changes.notify(:tags)
    end
  end

  @doc """
  One tag's bulk edit (`/tags` select mode): `"ideal_text"`, when present, replaces its sibling (nil
  or `""` clears it); `"add_parents"` and `"remove_parents"` add to and remove from its parents,
  keeping the rest. Removal matches parent text exactly. Same rules as `update_tag/3`.
  """
  @spec edit_tag(Scope.t(), Tag.t(), map()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def edit_tag(%Scope{} = scope, %Tag{} = tag, attrs) do
    tag = Repo.preload(tag, [:ideal, :parents])
    {add, _invalid, _errors} = normalize_list(attrs["add_parents"])
    {remove, _invalid, _errors} = normalize_list(attrs["remove_parents"])
    remove = MapSet.new(remove)

    parents =
      tag.parents
      |> Enum.map(&Tag.text/1)
      |> Enum.concat(add)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(remove, &1))

    changes = Map.merge(%{"parent_texts" => parents}, Map.take(attrs, ["ideal_text"]))
    update_tag(scope, tag, changes)
  end

  @doc """
  The items carrying the tag row itself (not its siblings or children), as `{kind, item}` in
  `Tagging.kinds/0` order, each kind by name; `[]` unless `scope` may edit the tag.
  """
  @spec tagged_items(Scope.t(), Tag.t()) :: [{Tagging.kind(), struct()}]
  def tagged_items(%Scope{} = scope, %Tag{} = tag) do
    if Ownership.authorize_edit(scope, tag) == :ok do
      taggings = Repo.all(from(tg in Tagging, where: tg.tag_id == ^tag.id))

      Enum.flat_map(Tagging.kinds(), fn kind ->
        column = Tagging.column(kind)

        taggings
        |> Enum.map(&Map.fetch!(&1, column))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] ->
            []

          ids ->
            kind
            |> Tagging.schema()
            |> where([item], item.id in ^ids)
            |> Repo.all()
            |> Enum.sort_by(&{&1.name || "", &1.id})
            |> Enum.map(&{kind, &1})
        end
      end)
    else
      []
    end
  end

  ## Items

  @doc "An item's hard tags: the site's and `scope`'s own, each sorted."
  @spec item_tags(Scope.t(), struct()) :: %{site: [String.t()], mine: [String.t()]}
  def item_tags(%Scope{} = scope, item) do
    uid = scope.user && scope.user.id
    column = item |> Tagging.kind_of() |> Tagging.column()

    rows =
      from(tg in Tagging,
        join: t in Tag,
        as: :tag,
        on: t.id == tg.tag_id,
        where: field(tg, ^column) == ^item.id,
        where: ^visible(uid),
        select: {is_nil(t.user_id), t.namespace, t.name}
      )
      |> Repo.all()

    {site, mine} = Enum.split_with(rows, &elem(&1, 0))
    %{site: texts(site), mine: texts(mine)}
  end

  defp texts(rows), do: rows |> Enum.map(fn {_, ns, name} -> Tag.text(%{namespace: ns, name: name}) end) |> sort()

  @doc """
  Replaces an item's hard tags of one domain: `:site` (a site item, by a content manager who may
  edit it) or `:mine` (`scope`'s own, on any item it can see).
  """
  @spec set_item_tags(Scope.t(), struct(), :site | :mine, [String.t()]) ::
          :ok | {:error, :unauthorized | {:invalid, String.t(), String.t()}}
  def set_item_tags(%Scope{} = scope, item, domain, texts) when domain in [:site, :mine] do
    with :ok <- authorize_tagging(scope, item, domain),
         owner = if(domain != :site, do: scope.user.id),
         {:ok, tags} <- ensure_tags(scope, owner, texts) do
      column = item |> Tagging.kind_of() |> Tagging.column()

      {:ok, :ok} =
        Repo.transact(fn ->
          existing =
            Repo.all(
              from(tg in Tagging,
                join: t in Tag,
                as: :tag,
                on: t.id == tg.tag_id,
                where: field(tg, ^column) == ^item.id,
                where: ^exactly(owner)
              )
            )

          build = &Map.put(%Tagging{tag_id: &1}, column, item.id)
          {:ok, Repo.sync_rows!(existing, :tag_id, MapSet.new(tags, & &1.id), build)}
        end)

      Changes.notify(:ok, :tags, owner)
    end
  end

  @doc """
  Adds `add` to and removes `remove` from an item's hard tags of one domain, keeping the rest
  (bulk tagging). Removal matches hard tag text exactly. Same rules as `set_item_tags/4`.
  """
  @spec edit_item_tags(Scope.t(), struct(), :site | :mine, [String.t()], [String.t()]) ::
          :ok | {:error, :unauthorized | {:invalid, String.t(), String.t()}}
  def edit_item_tags(%Scope{} = scope, item, domain, add, remove) when domain in [:site, :mine] do
    with {:ok, add} <- normalize_all(add),
         {:ok, remove} <- normalize_all(remove) do
      remove = MapSet.new(remove, &elem(&1, 2))

      wanted =
        scope
        |> item_tags(item)
        |> Map.fetch!(domain)
        |> Enum.concat(Enum.map(add, &elem(&1, 2)))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(remove, &1))

      set_item_tags(scope, item, domain, wanted)
    end
  end

  # `site_permission(Chat)` raises, so the chat clause comes before any `Ownership` call.
  defp authorize_tagging(_scope, %Chat{}, :site), do: {:error, :unauthorized}

  defp authorize_tagging(scope, %{user_id: nil} = item, :site) do
    with :ok <- Ownership.authorize_edit(scope, item), do: Scope.authorize(scope, "site.content.manage")
  end

  defp authorize_tagging(_scope, _item, :site), do: {:error, :unauthorized}

  defp authorize_tagging(%Scope{user: %{}} = scope, item, :mine) do
    if sees?(scope, item), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_tagging(_scope, _item, :mine), do: {:error, :unauthorized}

  defp sees?(scope, %Chat{} = chat), do: Chats.authorize(scope, chat, :read) == :ok
  defp sees?(scope, %AI.Model{} = model), do: Ownership.authorize_edit(scope, model) == :ok or AI.usable?(scope, model)
  defp sees?(scope, item), do: Ownership.usable?(scope, item)

  ## Reads

  @doc "Hard tag texts viewer `owner_id` sees on `kind` items `ids`, by item id."
  @spec tags_by_item(Ecto.UUID.t() | nil, Tagging.kind(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [String.t()]}
  def tags_by_item(_owner_id, _kind, []), do: %{}

  def tags_by_item(owner_id, kind, ids) do
    column = Tagging.column(kind)

    from(tg in Tagging,
      join: t in Tag,
      as: :tag,
      on: t.id == tg.tag_id,
      where: field(tg, ^column) in ^ids,
      where: ^visible(owner_id),
      select: {field(tg, ^column), t.namespace, t.name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, ns, name} -> Tag.text(%{namespace: ns, name: name}) end)
    |> Map.new(fn {id, texts} -> {id, Enum.uniq(texts)} end)
  end

  @doc "The `items` whose expanded tags satisfy every predicate; no predicates keeps them all."
  @spec filter_items([struct()], Tagging.kind(), Ecto.UUID.t() | nil, Graph.t(), [predicate()]) :: [struct()]
  def filter_items(items, _kind, _owner_id, _graph, []), do: items

  def filter_items(items, kind, owner_id, %Graph{} = graph, predicates) do
    tags = tags_by_item(owner_id, kind, Enum.map(items, & &1.id))
    Enum.filter(items, &Graph.matches?(graph, Graph.expand(graph, Map.get(tags, &1.id, [])), predicates))
  end

  ## Runtime

  @doc """
  The expanded, sorted tags for a prompt's anchors, under `graph` (the chat owner's `graph/1`): each
  participant's character and every `extra` character by id, and the chat's own (`[]` for an unsaved
  chat).
  """
  @spec anchor_tags(Chat.t(), [Character.t() | nil | term()], Graph.t()) ::
          %{characters: %{Ecto.UUID.t() => [String.t()]}, chat: [String.t()]}
  def anchor_tags(%Chat{} = chat, extra, %Graph{} = graph) do
    characters =
      (Chat.characters(chat) ++ List.wrap(extra))
      |> Enum.filter(&match?(%Character{}, &1))
      |> Enum.uniq_by(& &1.id)

    by_character = tags_by_item(chat.user_id, :character, Enum.map(characters, & &1.id))
    expanded = &(graph |> Graph.expand(&1) |> MapSet.to_list() |> sort())

    chat_tags =
      if chat.id,
        do: expanded.(Map.get(tags_by_item(chat.user_id, :chat, [chat.id]), chat.id, [])),
        else: []

    %{
      characters: Map.new(characters, &{&1.id, expanded.(Map.get(by_character, &1.id, []))}),
      chat: chat_tags
    }
  end

  @doc """
  The union of the expanded tags (`Graph.expand/2` through `graph`) of the `kind` items `ids`, read in
  `owner_id`'s domain.
  """
  @spec expanded_tags(Ecto.UUID.t() | nil, Graph.t(), Tagging.kind(), [Ecto.UUID.t()]) :: MapSet.t()
  def expanded_tags(owner_id, graph, kind, ids) do
    owner_id
    |> tags_by_item(kind, ids)
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, Graph.expand(graph, &1)))
  end

  @doc """
  `graph` (the chat owner's `graph/1`) and the union of every participant's expanded tags under it
  (lore tag filters).
  """
  @spec participant_tags(Chat.t(), Graph.t()) :: {Graph.t(), MapSet.t()}
  def participant_tags(%Chat{} = chat, %Graph{} = graph) do
    ids =
      chat.participants
      |> List.wrap()
      |> Enum.map(& &1.character_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {graph, expanded_tags(chat.user_id, graph, :character, ids)}
  end
end
