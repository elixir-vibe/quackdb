defmodule QuackDB.Cursor do
  @moduledoc """
  Cursor metadata used by `DBConnection` streaming.

  A cursor tracks the remote Quack result UUID plus column/type metadata needed
  to fetch and materialize subsequent result chunks.
  """

  defstruct [:ref, :result_uuid, :columns, :result_types, :connection_id]
end
