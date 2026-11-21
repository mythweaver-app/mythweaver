defmodule MythweaverWeb.ExportController do
  @moduledoc """
  The `/export` download: `ExportLive` posts its form here (`phx-trigger-action`), since a
  LiveView can't send a file. Any failure goes back to the page with the error flashed.
  """
  use MythweaverWeb, :controller

  alias Mythweaver.Export

  def create(conn, %{"export" => params}) do
    with {:ok, request} <- Export.request(params),
         {:ok, file} <- Export.build(conn.assigns.current_scope, request) do
      send_download(conn, {:binary, file.bytes}, filename: file.filename, content_type: file.content_type)
    else
      {:error, message} -> conn |> put_flash(:error, message) |> redirect(to: ~p"/export")
    end
  end

  def create(conn, _params) do
    conn |> put_flash(:error, nothing_chosen()) |> redirect(to: ~p"/export")
  end

  defp nothing_chosen do
    gettext_comment("Flash when the export form is submitted without choosing anything.")

    dpgettext(
      "import_export",
      "status: flash when an export is submitted with nothing chosen",
      "Choose something to export."
    )
  end
end
