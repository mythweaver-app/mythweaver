defmodule MythweaverWeb.Lore.BookSections do
  @moduledoc """
  The open book's sections in `MythweaverWeb.LoreBookLive`'s editor pane, below the book form:
  its bindings to chats and characters (`book_bindings/1`), its activation rules (`book_rules/1`)
  and its entries table (`book_entries/1`), with the table's template helpers.

  Function components, not LiveComponents: every event they send (`"save_bindings"`,
  `"validate_rules"`, `"sort_entries"`, …) goes to the LiveView, which owns the assigns they read.
  Their styles stay in the LiveView's colocated `<style>`, which has no lower bound and so reaches
  this markup.
  """

  use MythweaverWeb, :html

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Lore.EntryForm, only: [entry_form: 1]
  import MythweaverWeb.Pane

  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory.Tiers
  alias MythweaverWeb.Bulk.Selection
  alias MythweaverWeb.EnumLabels
  alias MythweaverWeb.Lore.EntryForm
  alias MythweaverWeb.Lore.InlineEntryForm
  alias MythweaverWeb.LoreBookLive
  alias Phoenix.HTML.Form

  @doc "The book's chat and character bindings: two pickers, then each binding with its pause switch."
  attr :editing_book, :map,
    required: true,
    doc: "the open book, with `book_chats` and `book_characters` (and their chat/character) preloaded"

  attr :chat_options, :list, required: true
  attr :character_options, :list, required: true
  attr :current_scope, :map, required: true
  attr :tag_graph, :any, required: true, doc: "the viewer's tag graph (`MythweaverWeb.TagFilter`)"
  attr :tag_vocabulary, :list, required: true

  def book_bindings(assigns) do
    ~H"""
    <.pane_section id="lore-book-bindings">
      <.section_header>
        {dpgettext(
          "lore",
          "heading: chats and characters a lore book is bound to",
          "Bindings"
        )}
      </.section_header>

      <.form for={%{}} id="lore-book-bindings-form" phx-change="save_bindings">
        <.field_row id="lore-book-bindings-form-row" align="stretch">
          <:field>
            <.live_component
              module={MythweaverWeb.MultiSelect}
              id="lore-book-bindings-form-chats"
              name="chats[]"
              label={dpgettext("lore", "field label: chats a lore book is bound to", "Chats")}
              options={@chat_options}
              selected={Enum.map(@editing_book.book_chats, & &1.chat_id)}
              empty={
                dpgettext(
                  "lore",
                  "empty state: no chats to bind a lore book to",
                  "No chats yet"
                )
              }
              tag_kind={:chat}
              viewer_id={@current_scope.user.id}
              tag_graph={@tag_graph}
              tag_vocabulary={@tag_vocabulary}
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The book applies in every chat selected here, for every reply. Bindings add up: a book bound to a chat and to a character applies in that chat and wherever that character appears. Activation rules below can narrow them. Uncheck a binding in the list below to pause it without removing it."
                )}
              </:hint>
            </.live_component>
          </:field>
          <:field>
            <.live_component
              module={MythweaverWeb.MultiSelect}
              id="lore-book-bindings-form-characters"
              name="characters[]"
              label={
                dpgettext(
                  "lore",
                  "field label: characters a lore book is bound to",
                  "Characters"
                )
              }
              options={@character_options}
              selected={Enum.map(@editing_book.book_characters, & &1.character_id)}
              empty={
                dpgettext(
                  "lore",
                  "empty state: no characters to bind a lore book to",
                  "No characters yet"
                )
              }
              tag_kind={:character}
              viewer_id={@current_scope.user.id}
              tag_graph={@tag_graph}
              tag_vocabulary={@tag_vocabulary}
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "The book applies in any chat where a selected character's card is part of the reply. That is the responder only, unless the chat's %{group_cards_setting} setting joins other members' cards. Uncheck a binding in the list below to pause it without removing it.",
                    group_cards_setting:
                      em(
                        dpgettext(
                          "lore",
                          "field label: chat setting that joins members' cards",
                          "Group cards"
                        )
                      )
                  )
                )}
              </:hint>
            </.live_component>
          </:field>
        </.field_row>
      </.form>

      <p
        :if={@editing_book.book_chats == [] and @editing_book.book_characters == []}
        class="lore-binding-empty"
      >
        {dpgettext(
          "lore",
          "empty state: lore book has no bindings",
          "Not bound to anything yet"
        )}
      </p>

      <ul
        :if={@editing_book.book_chats != [] or @editing_book.book_characters != []}
        class="lore-bindings-list"
      >
        <li
          :for={binding <- @editing_book.book_chats}
          id={"lore-binding-chat-#{binding.id}"}
          class="lore-binding"
        >
          <input
            type="checkbox"
            checked={binding.enabled}
            phx-click="toggle_binding"
            phx-value-id={binding.id}
            phx-value-kind="chat"
            aria-label={
              dpgettext(
                "lore",
                "aria label: pause or resume a lore book's chat binding",
                "Toggle chat binding %{chat_title}",
                chat_title: binding.chat.name || untitled_chat()
              )
            }
          />
          <span>
            {dpgettext("lore", "badge: lore book binding to a chat", "Chat: %{chat_title}",
              chat_title: binding.chat.name || untitled_chat()
            )}
          </span>
        </li>
        <li
          :for={binding <- @editing_book.book_characters}
          id={"lore-binding-character-#{binding.id}"}
          class="lore-binding"
        >
          <input
            type="checkbox"
            checked={binding.enabled}
            phx-click="toggle_binding"
            phx-value-id={binding.id}
            phx-value-kind="character"
            aria-label={
              dpgettext(
                "lore",
                "aria label: pause or resume a lore book's character binding",
                "Toggle character binding %{character_name}",
                character_name: binding.character.name
              )
            }
          />
          <span>
            {dpgettext(
              "lore",
              "badge: lore book binding to a character",
              "Character: %{character_name}",
              character_name: binding.character.name
            )}
          </span>
        </li>
      </ul>
    </.pane_section>
    """
  end

  @doc "The book's activation rules form (`rules_form`), with each rule's conditions."
  attr :editing_book, :map, required: true
  attr :rules_form, Form, required: true
  attr :rule_chat_options, :list, required: true
  attr :rule_character_options, :list, required: true
  attr :tag_vocabulary, :list, required: true

  def book_rules(assigns) do
    ~H"""
    <.pane_section id="lore-book-rules">
      <.section_header>
        {dpgettext("lore", "heading: activation rules of a lore book", "Activation rules")}
      </.section_header>
      <p class="lore-rules-hint">
        {dgettext(
          "lore",
          "Rules only narrow where this book applies: with any enabled rule, its entries activate only where Global, Forced or a binding already puts the book, and at least one enabled rule matches. A rule matches when all its conditions hold; Not inverts one. Template conditions read the chat's stored variables (vars, globals) as lore resolves."
        )}
      </p>

      <.form
        for={@rules_form}
        id="lore-book-rules-form"
        class="lore-rules-form"
        phx-hook="UnsavedChanges"
        data-saved={is_nil(@rules_form.action)}
        phx-change="validate_rules"
        phx-submit="save_rules"
      >
        <p :for={msg <- EntryForm.field_errors(@rules_form[:rules])} class="lore-rule-errors">
          {msg}
        </p>
        <.inputs_for :let={rule} field={@rules_form[:rules]}>
          <div class="lore-rule" id={"lore-book-rule-#{rule.index}"}>
            <input type="hidden" name="lore_book_rules[rules_sort][]" value={rule.index} />
            <div class="lore-rule-row">
              <.input
                field={rule[:enabled]}
                type="checkbox"
                label={dpgettext("lore", "field label: lore book activation rule is on", "Enabled")}
                id={"lore-book-rule-#{rule.index}-enabled"}
              />
              <.button
                size="sm"
                danger
                type="button"
                name="lore_book_rules[rules_drop][]"
                value={rule.index}
                phx-click={Phoenix.LiveView.JS.dispatch("change")}
                id={"lore-book-rule-#{rule.index}-remove"}
              >
                <.lucide name="trash" /> {dpgettext(
                  "lore",
                  "button: remove an activation rule from a lore book",
                  "Remove rule"
                )}
              </.button>
            </div>
            <p
              :for={msg <- EntryForm.field_errors(rule[:conditions])}
              class="lore-rule-errors"
            >
              {msg}
            </p>
            <.inputs_for :let={c} field={rule[:conditions]}>
              <div
                class="lore-rule-condition"
                id={"lore-book-rule-#{rule.index}-condition-#{c.index}"}
              >
                <input
                  type="hidden"
                  name={rule.name <> "[conditions_sort][]"}
                  value={c.index}
                />
                <.input
                  field={c[:kind]}
                  type="select"
                  label={
                    dpgettext(
                      "lore",
                      "field label: kind of condition in a lore activation rule",
                      "Condition"
                    )
                  }
                  options={[
                    {dpgettext("lore", "option: lore rule condition kind", "Chat is"), "chat"},
                    {dpgettext(
                       "lore",
                       "option: lore rule condition kind",
                       "Character present"
                     ), "character_present"},
                    {dpgettext("lore", "option: lore rule condition kind", "Responder is"),
                     "responder"},
                    {dpgettext("lore", "option: lore rule condition kind", "Chat has tag"),
                     "chat_tag"},
                    {dpgettext(
                       "lore",
                       "option: lore rule condition kind",
                       "Present character has tag"
                     ), "character_tag"},
                    {dpgettext("lore", "option: lore rule condition kind", "Template"), "template"}
                  ]}
                  id={"lore-book-rule-#{rule.index}-condition-#{c.index}-kind"}
                />
                <.input
                  field={c[:negate]}
                  type="checkbox"
                  label={dpgettext("lore", "field label: invert a lore rule condition", "Not")}
                  id={"lore-book-rule-#{rule.index}-condition-#{c.index}-negate"}
                />
                <%= case condition_kind(c) do %>
                  <% "chat" -> %>
                    <.input
                      field={c[:chat_id]}
                      type="select"
                      label={
                        dpgettext(
                          "lore",
                          "field label: chat a lore rule condition names",
                          "Chat"
                        )
                      }
                      prompt={
                        dpgettext(
                          "lore",
                          "option: no chat picked for a lore rule condition",
                          "Pick a chat"
                        )
                      }
                      options={
                        target_options(
                          @rule_chat_options,
                          c[:chat_id].value,
                          dpgettext(
                            "lore",
                            "option: a chat the viewer can no longer pick",
                            "Unavailable chat"
                          )
                        )
                      }
                      id={"lore-book-rule-#{rule.index}-condition-#{c.index}-chat_id"}
                    />
                  <% kind when kind in ["character_present", "responder"] -> %>
                    <.input
                      field={c[:character_id]}
                      type="select"
                      label={
                        dpgettext(
                          "lore",
                          "field label: character a lore rule condition names",
                          "Character"
                        )
                      }
                      prompt={
                        dpgettext(
                          "lore",
                          "option: no character picked for a lore rule condition",
                          "Pick a character"
                        )
                      }
                      options={
                        target_options(
                          @rule_character_options,
                          c[:character_id].value,
                          dpgettext(
                            "lore",
                            "option: a character the viewer can no longer pick",
                            "Unavailable character"
                          )
                        )
                      }
                      id={"lore-book-rule-#{rule.index}-condition-#{c.index}-character_id"}
                    />
                  <% kind when kind in ["chat_tag", "character_tag"] -> %>
                    <.tag_input
                      id={"lore-book-rule-#{rule.index}-condition-#{c.index}-tags"}
                      name={c.name <> "[tags][]"}
                      label={
                        dpgettext(
                          "lore",
                          "field label: tags a lore rule condition checks",
                          "Any of these tags"
                        )
                      }
                      values={c[:tags].value || []}
                      vocabulary={@tag_vocabulary}
                      errors={EntryForm.field_errors(c[:tags])}
                    />
                  <% _template -> %>
                    <.input
                      field={c[:template]}
                      type="text"
                      label={
                        dpgettext(
                          "lore",
                          "field label: Liquid template a lore rule condition evaluates",
                          "Liquid condition"
                        )
                      }
                      placeholder={~s(vars.mood == "tense")}
                      id={"lore-book-rule-#{rule.index}-condition-#{c.index}-template"}
                    />
                <% end %>
                <.button
                  size="sm"
                  icon
                  type="button"
                  name={rule.name <> "[conditions_drop][]"}
                  value={c.index}
                  phx-click={Phoenix.LiveView.JS.dispatch("change")}
                  id={"lore-book-rule-#{rule.index}-condition-#{c.index}-remove"}
                  aria-label={
                    dpgettext(
                      "lore",
                      "aria label: remove a condition from a lore rule",
                      "Remove condition"
                    )
                  }
                >
                  <.lucide name="x" />
                </.button>
              </div>
            </.inputs_for>
            <input type="hidden" name={rule.name <> "[conditions_drop][]"} />
            <.button
              size="sm"
              type="button"
              name={rule.name <> "[conditions_sort][]"}
              value="new"
              phx-click={Phoenix.LiveView.JS.dispatch("change")}
              id={"lore-book-rule-#{rule.index}-add-condition"}
            >
              <.lucide name="plus" /> {dpgettext(
                "lore",
                "button: add a condition to a lore rule",
                "Add condition"
              )}
            </.button>
          </div>
        </.inputs_for>
        <input type="hidden" name="lore_book_rules[rules_drop][]" />

        <.form_actions>
          <:start>
            <.button
              size="sm"
              type="button"
              id="lore-book-add-rule"
              name="lore_book_rules[rules_sort][]"
              value="new"
              phx-click={Phoenix.LiveView.JS.dispatch("change")}
            >
              <.lucide name="plus" /> {dpgettext(
                "lore",
                "button: add an activation rule to a lore book",
                "Add rule"
              )}
            </.button>
          </:start>
          <.button patch={~p"/lore/#{@editing_book.id}/edit"}>
            {dpgettext("lore", "button: discard edits to the open form", "Cancel")}
          </.button>
          <.button type="submit" variant="primary">{dpgettext(
            "lore",
            "button: save the open form",
            "Save"
          )}</.button>
        </.form_actions>
      </.form>
    </.pane_section>
    """
  end

  @doc """
  The book's entries: the new entry's form, the hide-disabled-memories filter, the selection bar and
  the sortable table of rows, the open one holding `MythweaverWeb.Lore.InlineEntryForm`.
  """
  attr :editing_book, :map, required: true
  attr :entries, :any, required: true, doc: "the `entries` stream"
  attr :entries_empty?, :boolean, required: true
  attr :hidden_entry_count, :integer, required: true
  attr :hide_disabled_memories, :boolean, required: true
  attr :selected_entry_ids, :any, required: true, doc: "a `MapSet` of the selected entries' ids"
  attr :entry_ids, :list, required: true
  attr :entry_sort, :any, required: true, doc: "the view-only sort: `{column, direction}` or nil"
  attr :memory_kinds, :map, required: true
  attr :editing_entry, :any, required: true
  attr :open_row, :any, required: true
  attr :entry_form, :any, required: true
  attr :entry_keywords, :list, required: true
  attr :entry_secondary_keywords, :list, required: true
  attr :entry_books, :list, required: true
  attr :entry_pools, :list, required: true
  attr :entry_pool_settings, :map, required: true
  attr :entry_filter_characters, :list, required: true
  attr :entry_filter_tags, :list, required: true
  attr :entry_owner, :any, required: true
  attr :entry_memory, :any, required: true
  attr :entry_compaction, :any, required: true
  attr :entry_diff, :boolean, required: true
  attr :character_options, :list, required: true
  attr :books, :list, required: true
  attr :pools, :list, required: true
  attr :prompt_outlets, :list, required: true
  attr :template_completions, :map, required: true
  attr :token_model, :any, required: true
  attr :tag_fields, :map, required: true
  attr :tag_vocabulary, :list, required: true
  attr :tag_graph, :any, required: true
  attr :current_scope, :map, required: true

  def book_entries(assigns) do
    # Computed icon names; the Iconex compiler only sees literals.
    Iconex.hint(:lucide, ~w[chevron-up chevron-down circle-dot key waypoints])

    ~H"""
    <.pane_section id="lore-book-entries">
      <.section_header>
        {dpgettext(
          "lore",
          "heading: entries in a lore book, with their number",
          "Entries (%{entry_count})",
          entry_count: Mythweaver.Format.number(length(@editing_book.book_entries))
        )}
        <:actions>
          <.button
            patch={~p"/lore/#{@editing_book.id}/entries/new"}
            id="new-lore-entry"
            variant="primary"
          >
            <.lucide name="plus" /> {dpgettext(
              "lore",
              "button: create a lore entry",
              "New entry"
            )}
          </.button>
        </:actions>
      </.section_header>

      <%!-- A new entry (or one no longer in this book) has no row to open, so its form sits above the list. --%>
      <.entry_form
        :if={@entry_form && !@open_row}
        inset
        form={@entry_form}
        keywords={@entry_keywords}
        secondary_keywords={@entry_secondary_keywords}
        entry_books={@entry_books}
        entry_pools={@entry_pools}
        entry_pool_settings={@entry_pool_settings}
        entry_filter_characters={@entry_filter_characters}
        character_options={@character_options}
        books={@books}
        entry_filter_tags={@entry_filter_tags}
        tag_field={@tag_fields.entry}
        tag_vocabulary={@tag_vocabulary}
        viewer_id={@current_scope.user.id}
        tag_graph={@tag_graph}
        owner={@entry_owner}
        pools={@pools}
        prompt_outlets={@prompt_outlets}
        completions={@template_completions}
        memory={@entry_memory}
        compacting={@entry_compaction != nil}
        diff={@entry_diff}
        token_model={@token_model}
        cancel={~p"/lore/#{@editing_book.id}/edit"}
      />

      <div class="lore-entries-filters">
        <.button
          size="sm"
          id="lore-entries-hide-disabled-memories"
          phx-click="toggle_hide_disabled_memories"
          aria-pressed={to_string(@hide_disabled_memories)}
          title={
            dgettext(
              "lore",
              "Hide memory entries switched off in this book, such as consolidated sources"
            )
          }
        >
          {dpgettext(
            "lore",
            "toggle: hide switched-off memory entries in a lore book",
            "Hide disabled memories"
          )}
        </.button>
      </div>

      <p :if={@entries_empty? and @hidden_entry_count == 0} class="lore-entries-empty">
        {dpgettext(
          "lore",
          "empty state: lore book has no entries",
          "No entries in this book yet"
        )}
      </p>
      <p :if={@entries_empty? and @hidden_entry_count > 0} class="lore-entries-empty">
        {dgettext("lore", "Every entry in this book is a disabled memory, hidden")}
      </p>

      <.selection_bar
        :if={MapSet.size(@selected_entry_ids) > 0}
        id="lore-entries-selection"
        count={MapSet.size(@selected_entry_ids)}
        clear="clear_entry_selection"
        label={
          dpgettext(
            "lore",
            "aria label: bulk actions for the selected lore entries",
            "Selected entries"
          )
        }
      >
        <:action>
          <.button
            size="sm"
            id="lore-entries-mark-memories"
            phx-click="mark_entries_as_memories"
            title={
              dgettext(
                "lore",
                "Make the selected entries memories of this book (no chat or message range)"
              )
            }
          >
            <.lucide name="bookmark-plus" /> {dpgettext(
              "lore",
              "button: mark the selected lore entries as memories",
              "Mark as memories"
            )}
          </.button>
        </:action>
        <:action>
          <.button
            size="sm"
            id="lore-entries-unmark-memories"
            phx-click="unmark_entry_memories"
            title={
              dgettext(
                "lore",
                "Stop treating the selected entries as memories; the entries stay"
              )
            }
          >
            <.lucide name="bookmark-minus" /> {dpgettext(
              "lore",
              "button: unmark the selected lore entries as memories",
              "Unmark memories"
            )}
          </.button>
        </:action>
      </.selection_bar>

      <%!-- `RangeSelect`: shift-click on a row's select box selects a range (`select_entry_range`). --%>
      <div
        id="lore-entries-table"
        phx-hook="RangeSelect"
        data-range-event="select_entry_range"
      >
        <div
          :if={!@entries_empty?}
          id="lore-entries-columns"
          class="lore-entries-columns"
          role="row"
        >
          <span role="columnheader">
            <input
              type="checkbox"
              id="lore-entries-select-all"
              class="lore-entry-select"
              checked={Selection.all_selected?(@selected_entry_ids, @entry_ids)}
              phx-click="toggle_all_entries"
              aria-label={
                dpgettext(
                  "lore",
                  "aria label: select every lore entry in the table",
                  "Select all entries"
                )
              }
              title={
                dpgettext(
                  "lore",
                  "tooltip: select every lore entry in the table",
                  "Select all entries"
                )
              }
            />
          </span>
          <span></span>
          <span></span>
          <.sort_header
            column="on"
            sort={@entry_sort}
            label={dpgettext("lore", "column header: lore entry is on in this book", "On")}
          />
          <.sort_header
            column="name"
            sort={@entry_sort}
            label={dpgettext("lore", "column header: lore entry name", "Name")}
          />
          <.sort_header
            column="activation"
            sort={@entry_sort}
            label={dpgettext("lore", "column header: lore entry activation", "Activation")}
            compact
          />
          <.sort_header column="position" sort={@entry_sort} label={position_column()} />
          <.sort_header column="order" sort={@entry_sort} label={order_column()} />
          <.sort_header column="trigger" sort={@entry_sort} label={trigger_column()} />
          <span></span>
        </div>
        <ul
          id="lore-entries"
          class="lore-entries-list"
          phx-update="stream"
          phx-hook="SortableList"
          data-sortable-event="reorder_entries"
          data-sortable-disabled={to_string(@entry_sort != nil or @hide_disabled_memories)}
          hidden={@entries_empty?}
        >
          <li
            :for={{dom_id, entry} <- @entries}
            id={dom_id}
            data-id={entry.id}
            class={[
              "lore-entry-row",
              !LoreBookLive.enabled_in_book?(entry, @editing_book) && "lore-entry-row--off"
            ]}
          >
            <div class="lore-entry-summary">
              <input
                type="checkbox"
                id={"lore-entries-#{entry.id}-select"}
                class="lore-entry-select"
                checked={MapSet.member?(@selected_entry_ids, entry.id)}
                phx-click="toggle_entry_selection"
                phx-value-id={entry.id}
                data-range-id={entry.id}
                aria-label={
                  dpgettext(
                    "lore",
                    "aria label: select this lore entry for bulk actions",
                    "Select %{entry_name}",
                    entry_name: entry.name
                  )
                }
                title={
                  dpgettext(
                    "lore",
                    "tooltip: select this lore entry for bulk actions",
                    "Select for bulk actions"
                  )
                }
              />
              <.drag_handle />
              <.link
                patch={entry_toggle_path(@editing_book, entry, @editing_entry)}
                id={"lore-entries-#{entry.id}-expand"}
                class="lore-entry-expand"
                aria-expanded={to_string(expanded?(entry, @editing_entry))}
                aria-label={
                  if expanded?(entry, @editing_entry),
                    do:
                      dpgettext(
                        "lore",
                        "aria label: collapse this lore entry's row",
                        "Collapse %{entry_name}",
                        entry_name: entry.name
                      ),
                    else:
                      dpgettext(
                        "lore",
                        "aria label: expand this lore entry's row",
                        "Expand %{entry_name}",
                        entry_name: entry.name
                      )
                }
              >
                <.lucide name={
                  if expanded?(entry, @editing_entry), do: "chevron-up", else: "chevron-down"
                } />
              </.link>
              <input
                type="checkbox"
                id={"lore-entries-#{entry.id}-in-book"}
                class="lore-entry-in-book"
                checked={LoreBookLive.enabled_in_book?(entry, @editing_book)}
                phx-click="toggle_in_book"
                phx-value-id={entry.id}
                aria-label={
                  dpgettext(
                    "lore",
                    "aria label: switch this lore entry on in the book",
                    "Active in %{book_name}",
                    book_name: @editing_book.name
                  )
                }
                title={
                  dgettext("lore", "Active in %{book_name} (this book only)",
                    book_name: @editing_book.name
                  )
                }
              />
              <span class="lore-entry-title">
                <.link
                  patch={entry_toggle_path(@editing_book, entry, @editing_entry)}
                  class="lore-entry-name"
                >
                  {entry.name}
                </.link>
                <span
                  :if={@memory_kinds[entry.id]}
                  id={"lore-entries-#{entry.id}-memory"}
                  class="lore-entry-memory-badge"
                >
                  {memory_badge(@memory_kinds[entry.id])}
                </span>
                <span :if={length(entry.books) > 1} class="lore-entry-shared">
                  {other_books_label(length(entry.books) - 1)}
                </span>
              </span>
              <span
                class="lore-entry-activation"
                data-activation={entry.activation}
                title={activation_title(entry.activation)}
              >
                <.lucide name={activation_icon(entry.activation)} />
              </span>
              <span
                class="lore-entry-cell"
                title={position_title(entry)}
                data-label={position_column()}
              >
                {position_label(entry)}
              </span>
              <form
                id={"lore-entries-#{entry.id}-order-form"}
                class="lore-entry-order-form"
                data-label={order_column()}
                phx-change="set_entry_order"
                phx-submit="set_entry_order"
              >
                <input type="hidden" name="entry_id" value={entry.id} />
                <input
                  type="number"
                  name="order"
                  min="0"
                  id={"lore-entries-#{entry.id}-order"}
                  value={LoreBookLive.membership_order(entry, @editing_book)}
                  phx-debounce="blur"
                  class="lore-entry-cell lore-entry-order"
                  aria-label={
                    dgettext("lore", "Order of %{entry_name} in %{book_name}",
                      entry_name: entry.name,
                      book_name: @editing_book.name
                    )
                  }
                  title={
                    dgettext(
                      "lore",
                      "Order in this book (higher renders later in a slot, earlier in an outlet)"
                    )
                  }
                />
              </form>
              <span
                class="lore-entry-cell"
                title={
                  dpgettext(
                    "lore",
                    "tooltip: chance that a lore entry is used",
                    "Trigger probability"
                  )
                }
                data-label={trigger_column()}
              >
                {Mythweaver.Format.percent(entry.probability / 100)}
              </span>
              <span class="lore-entry-actions">
                <.button
                  size="sm"
                  icon
                  danger
                  phx-click="remove_from_book"
                  phx-value-id={entry.id}
                  aria-label={
                    dpgettext(
                      "lore",
                      "aria label: icon button that removes a lore entry from this book",
                      "Remove %{entry_name} from %{book_name}",
                      entry_name: entry.name,
                      book_name: @editing_book.name
                    )
                  }
                  title={
                    dpgettext(
                      "lore",
                      "tooltip: remove a lore entry from this book only",
                      "Remove from this book"
                    )
                  }
                >
                  <.lucide name="unlink" />
                </.button>
                <.button
                  size="sm"
                  icon
                  danger
                  phx-click="delete_entry"
                  phx-value-id={entry.id}
                  data-confirm={LoreBookLive.delete_confirm(entry.name)}
                  aria-label={
                    dpgettext(
                      "lore",
                      "aria label: icon button that deletes this lore entry",
                      "Delete %{entry_name}",
                      entry_name: entry.name
                    )
                  }
                  title={
                    dpgettext(
                      "lore",
                      "tooltip: delete a lore entry from every book",
                      "Delete the entry everywhere"
                    )
                  }
                >
                  <.lucide name="trash" />
                </.button>
              </span>
            </div>

            <div :if={expanded?(entry, @editing_entry)} class="lore-entry-detail">
              <.live_component
                module={InlineEntryForm}
                id={InlineEntryForm.id()}
                {InlineEntryForm.form_assigns(assigns)}
              />
            </div>
          </li>
        </ul>
      </div>

      <p :if={@entry_sort} id="lore-entries-sorted" class="lore-entries-sorted">
        {dgettext("lore", "Sorted for viewing only, so drag to reorder is off.")}
        <.button size="sm" id="lore-entries-clear-sort" phx-click="clear_entry_sort">
          {dpgettext(
            "lore",
            "button: undo the view-only sort of lore entries",
            "Back to book order"
          )}
        </.button>
      </p>
    </.pane_section>
    """
  end

  # The badge of an entry that is a memory: the tier name ("Memory", "Arc", …) or the kind.
  defp memory_badge(:memory), do: Tiers.label(0)
  defp memory_badge({:consolidation, tier}), do: Tiers.label(tier)

  defp memory_badge(kind) when kind in [:clip, :topical_clip],
    do: dpgettext("lore", "badge: lore entry is a memory clip", "Clip")

  defp memory_badge(:side_prompt), do: dpgettext("lore", "badge: lore entry is written by a side prompt", "Side prompt")

  defp other_books_label(book_count),
    do:
      dpngettext(
        "lore",
        "unit: other books a lore entry also sits in",
        "also in %{book_count} other book",
        "also in %{book_count} other books",
        book_count, book_count: Mythweaver.Format.number(book_count))

  defp untitled_chat, do: dpgettext("lore", "status: chat without a title", "Untitled")
  defp position_column, do: dpgettext("lore", "column header: where a lore entry is inserted", "Position")
  defp order_column, do: dpgettext("lore", "column header: lore entry order in this book", "Order")
  defp trigger_column, do: dpgettext("lore", "column header: lore entry trigger chance", "Trigger")

  # A condition's kind as posted (a string) or loaded (an atom).
  defp condition_kind(condition), do: to_string(condition[:kind].value)

  # A target the viewer may not pick, or one gone stale, still shows so it can be replaced.
  defp target_options(options, id, _label) when id in [nil, ""], do: options

  defp target_options(options, id, label) do
    if Enum.any?(options, fn {_text, value} -> value == id end), do: options, else: options ++ [{label, id}]
  end

  # One row is open at a time: it is the entry the shared form is editing.
  defp expanded?(entry, editing_entry), do: match?(%{id: id} when id == entry.id, editing_entry)

  defp entry_toggle_path(book, entry, editing_entry) do
    if expanded?(entry, editing_entry),
      do: ~p"/lore/#{book.id}/edit",
      else: ~p"/lore/#{book.id}/entries/#{entry.id}/edit"
  end

  # SillyTavern's compact position column: an arrow for before/after, then the outlet.
  defp position_label(%{outlet: :at_depth, depth: depth}),
    do:
      dpgettext("lore", "badge: short form of the at-depth lore outlet with its depth", "@D%{insertion_depth}",
        insertion_depth: Mythweaver.Format.number(depth || 0)
      )

  defp position_label(%{outlet: :custom, custom_outlet: key}), do: key || EnumLabels.label(LoreEntry, :outlet, :custom)
  defp position_label(%{outlet: outlet, placement: placement}), do: arrow(placement) <> outlet_short(outlet)

  defp position_title(%{outlet: :at_depth, depth: depth}),
    do:
      dpgettext("lore", "tooltip: lore entry is inserted at a depth in the chat history", "At depth %{insertion_depth}",
        insertion_depth: Mythweaver.Format.number(depth || 0)
      )

  defp position_title(%{outlet: :custom, custom_outlet: key}),
    do:
      dpgettext("lore", "tooltip: lore entry goes into a custom prompt outlet", "Custom outlet %{outlet_name}",
        outlet_name: key
      )

  defp position_title(%{outlet: :character, placement: :before}),
    do: dpgettext("lore", "tooltip: lore entry position", "Before character")

  defp position_title(%{outlet: :character, placement: :after}),
    do: dpgettext("lore", "tooltip: lore entry position", "After character")

  defp position_title(%{outlet: :examples, placement: :before}),
    do: dpgettext("lore", "tooltip: lore entry position", "Before examples")

  defp position_title(%{outlet: :examples, placement: :after}),
    do: dpgettext("lore", "tooltip: lore entry position", "After examples")

  defp position_title(%{outlet: :author_note, placement: :before}),
    do: dpgettext("lore", "tooltip: lore entry position", "Before author note")

  defp position_title(%{outlet: :author_note, placement: :after}),
    do: dpgettext("lore", "tooltip: lore entry position", "After author note")

  defp arrow(:before), do: "↑"
  defp arrow(:after), do: "↓"

  defp outlet_short(:character),
    do: dpgettext("lore", "badge: short form of the lore outlet by the character description", "Char")

  defp outlet_short(:examples),
    do: dpgettext("lore", "badge: short form of the lore outlet by the example messages", "EM")

  defp outlet_short(:author_note),
    do: dpgettext("lore", "badge: short form of the lore outlet by the author's note", "AN")

  defp activation_title(activation) when activation in [:constant, :vector],
    do: EnumLabels.label(LoreEntry, :activation, activation)

  defp activation_title(_), do: EnumLabels.label(LoreEntry, :activation, :keyword)

  defp activation_icon(:constant), do: "circle-dot"
  defp activation_icon(:vector), do: "waypoints"
  defp activation_icon(_), do: "key"

  attr :column, :string, required: true
  attr :sort, :any, required: true
  attr :label, :string, required: true
  attr :compact, :boolean, default: false, doc: "only the sort arrow shows; the label is its name"

  # A column header that sorts the rows for viewing (`sort_entries`): ascending, descending, off.
  defp sort_header(assigns) do
    ~H"""
    <span role="columnheader" aria-sort={aria_sort(@sort, @column)}>
      <button
        type="button"
        id={"lore-entries-sort-#{@column}"}
        class="lore-entries-sort"
        phx-click="sort_entries"
        phx-value-by={@column}
        aria-pressed={to_string(match?({column, _} when column == @column, @sort))}
        aria-label={sort_aria_label(@column)}
        title={sort_title(@column)}
      >
        <span :if={!@compact}>{@label}</span>
        <.lucide :if={aria_sort(@sort, @column) == "ascending"} name="arrow-up" />
        <.lucide :if={aria_sort(@sort, @column) == "descending"} name="arrow-down" />
        <.lucide :if={@compact and aria_sort(@sort, @column) == "none"} name="arrow-up-down" />
      </button>
    </span>
    """
  end

  defp sort_aria_label("on"),
    do: dpgettext("lore", "aria label: sort lore entries by on/off in this book", "Sort by On")

  defp sort_aria_label("name"), do: dpgettext("lore", "aria label: sort lore entries by name", "Sort by Name")

  defp sort_aria_label("activation"),
    do: dpgettext("lore", "aria label: sort lore entries by activation", "Sort by Activation")

  defp sort_aria_label("position"),
    do: dpgettext("lore", "aria label: sort lore entries by position", "Sort by Position")

  defp sort_aria_label("order"), do: dpgettext("lore", "aria label: sort lore entries by order", "Sort by Order")

  defp sort_aria_label("trigger"),
    do: dpgettext("lore", "aria label: sort lore entries by trigger chance", "Sort by Trigger")

  defp sort_title("on"), do: dgettext("lore", "Sort by On (view only)")
  defp sort_title("name"), do: dgettext("lore", "Sort by Name (view only)")
  defp sort_title("activation"), do: dgettext("lore", "Sort by Activation (view only)")
  defp sort_title("position"), do: dgettext("lore", "Sort by Position (view only)")
  defp sort_title("order"), do: dgettext("lore", "Sort by Order (view only)")
  defp sort_title("trigger"), do: dgettext("lore", "Sort by Trigger (view only)")

  defp aria_sort({column, :asc}, column), do: "ascending"
  defp aria_sort({column, :desc}, column), do: "descending"
  defp aria_sort(_sort, _column), do: "none"
end
