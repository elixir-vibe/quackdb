defmodule QuackDB.Cursor do
  @moduledoc """
  Cursor metadata used by `DBConnection` streaming.

  A cursor tracks the remote Quack result UUID plus column/type metadata needed
  to fetch and materialize subsequent result chunks.
  """

  defstruct [:ref, :result_uuid, :columns, :result_types, :connection_id, :statement]
end

defimpl Inspect, for: QuackDB.Cursor do
  import Inspect.Algebra

  alias QuackDB.Inspect, as: QuackInspect

  def inspect(cursor, opts) do
    fields = [
      result_uuid: cursor.result_uuid,
      columns: cursor.columns,
      connection_id: QuackInspect.short_id(cursor.connection_id),
      statement: QuackInspect.truncate(cursor.statement)
    ]

    concat(QuackInspect.container("QuackDB.Cursor", fields, opts))
  end
end
