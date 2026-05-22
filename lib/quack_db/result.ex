defmodule QuackDB.Result do
  @moduledoc """
  Normalized query result.

  The shape mirrors what `Ecto.Adapters.SQL` expects from DBConnection-backed
  drivers: `rows` and `num_rows` are always present, while `columns` and
  `metadata` keep Quack-specific result information available.
  """

  @type command :: :select | :insert | :update | :delete | :begin | :commit | :rollback | atom()

  @type t :: %__MODULE__{
          command: command() | nil,
          columns: [String.t()] | nil,
          rows: [[term()]] | nil,
          num_rows: non_neg_integer(),
          metadata: map()
        }

  defstruct command: nil,
            columns: nil,
            rows: nil,
            num_rows: 0,
            metadata: %{}
end
