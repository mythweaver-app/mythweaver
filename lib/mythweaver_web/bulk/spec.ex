defmodule MythweaverWeb.Bulk.Spec do
  @moduledoc """
  How `MythweaverWeb.Bulk` reaches one selectable list.

  - `name`: the list key (an atom; the engine keys state by its string form).
  - `count_label`: `(pos_integer() -> String.t())`, the whole counted noun phrase in the caller's
    domain ("3 characters"), spliced into the engine's summaries.
  - `edit_label`/`tag_label`: whole button labels ("Edit entries…") for pages with more than one
    spec; nil falls back to the generic label.
  - `ids`: `(socket -> [id])`, the ids the list shows.
  - `get`: `(scope, id -> row | nil)`.
  - `update`: `(scope, row, attrs -> {:ok, _} | {:error, reason})`, or nil for a delete-only list.
  - `delete`: `(scope, row -> {:ok, _} | {:error, reason})`.
  - `title`: `(row -> String.t())`, names a row in a failure summary.
  - `refresh`: `(socket -> socket)`, re-renders the rows (stream rows render once).
  - `open_id`: `(socket -> id | nil)`, the row the editor shows.
  - `edit_path`: `(id -> String.t())`; `index_path`: where to go when the open row is deleted.
  - `fields`: the `MythweaverWeb.Bulk.Field`s the edit modal offers.
  - `tag_kind`: the rows' `Mythweaver.Tags.Tagging` kind, which offers the Tags action; nil for an
    untaggable list. `get` must return the taggable struct.
  """

  @enforce_keys [:name, :count_label, :ids, :get, :delete, :title, :index_path, :edit_path, :open_id]
  defstruct [
    :name,
    :count_label,
    :ids,
    :get,
    :delete,
    :title,
    :index_path,
    :edit_path,
    :open_id,
    edit_label: nil,
    tag_label: nil,
    fields: [],
    tag_kind: nil,
    update: nil,
    refresh: &Function.identity/1
  ]

  @type t :: %__MODULE__{}
end
