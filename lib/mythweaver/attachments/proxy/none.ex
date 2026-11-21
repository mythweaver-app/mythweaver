defmodule Mythweaver.Attachments.Proxy.None do
  @moduledoc "No proxy: the original object, scaled by the browser."

  @behaviour Mythweaver.Attachments.Proxy

  @impl true
  def url(source, _key, _size, _expires_at, _config), do: source

  @impl true
  def original_url(source, _key, _expires_at, _config), do: source

  @impl true
  def stills?, do: false

  @impl true
  def png_url(_source, _key, _expires_at, _config), do: nil
end
