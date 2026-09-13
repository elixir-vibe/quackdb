defmodule QuackDB.Error.ServerException do
  @moduledoc false
  use JSONCodec

  defstruct [:exception_type, :exception_message]

  @type t :: %__MODULE__{
          exception_type: String.t(),
          exception_message: String.t()
        }
end
