defmodule Mythweaver.UnauthorizedError do
  @moduledoc "Raised when a scope may not perform an action whose return type has no refusal value."
  defexception message: "not allowed", plug_status: 403
end
