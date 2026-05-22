defmodule QuackDB.Cursor do
  @moduledoc false

  defstruct [:ref, :result_uuid, :columns, :result_types]
end
