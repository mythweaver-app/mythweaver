defmodule MythweaverWeb.Lore.InlineEntryForm do
  @moduledoc """
  The book table's open-row entry form (`MythweaverWeb.Lore.EntryForm.entry_form/1`), wrapped in a
  LiveComponent so it can change without re-inserting its stream row.

  A re-inserted stream item is rendered from scratch: its function-component roots get fresh
  `data-phx-id`s, so LiveView rebuilds them and moves the content editor, which drops its focus on
  every keystroke. A LiveComponent's render is diffed on its own, so `MythweaverWeb.LoreBookLive`
  updates this with `refresh/1` instead. Its events still go to the LiveView (no `phx-target`).
  """
  use MythweaverWeb, :live_component

  import MythweaverWeb.Lore.EntryForm, only: [entry_form: 1]

  @id "lore-entry-inline"

  @doc "The component's id; the open row renders it with this one."
  def id, do: @id

  @doc "Re-renders the open row's form from the LiveView's entry assigns."
  def refresh(assigns), do: send_update(__MODULE__, Map.put(form_assigns(assigns), :id, @id))

  @doc "The entry assigns the form reads, from the LiveView's assigns."
  def form_assigns(assigns) do
    %{
      form: assigns.entry_form,
      keywords: assigns.entry_keywords,
      secondary_keywords: assigns.entry_secondary_keywords,
      entry_books: assigns.entry_books,
      entry_pools: assigns.entry_pools,
      entry_pool_settings: assigns.entry_pool_settings,
      entry_filter_characters: assigns.entry_filter_characters,
      entry_filter_tags: assigns.entry_filter_tags,
      tag_field: assigns.tag_fields.entry,
      tag_vocabulary: assigns.tag_vocabulary,
      viewer_id: assigns.current_scope.user.id,
      tag_graph: assigns.tag_graph,
      character_options: assigns.character_options,
      books: assigns.books,
      owner: assigns.entry_owner,
      pools: assigns.pools,
      prompt_outlets: assigns.prompt_outlets,
      completions: assigns.template_completions,
      memory: assigns.entry_memory,
      compacting: assigns.entry_compaction != nil,
      diff: assigns.entry_diff,
      token_model: assigns.token_model,
      cancel: ~p"/lore/#{assigns.editing_book.id}/edit"
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.entry_form
        heading={false}
        form={@form}
        keywords={@keywords}
        secondary_keywords={@secondary_keywords}
        entry_books={@entry_books}
        entry_pools={@entry_pools}
        entry_pool_settings={@entry_pool_settings}
        entry_filter_characters={@entry_filter_characters}
        entry_filter_tags={@entry_filter_tags}
        tag_field={@tag_field}
        tag_vocabulary={@tag_vocabulary}
        viewer_id={@viewer_id}
        tag_graph={@tag_graph}
        character_options={@character_options}
        books={@books}
        owner={@owner}
        pools={@pools}
        prompt_outlets={@prompt_outlets}
        completions={@completions}
        memory={@memory}
        compacting={@compacting}
        diff={@diff}
        token_model={@token_model}
        cancel={@cancel}
      />
    </div>
    """
  end
end
