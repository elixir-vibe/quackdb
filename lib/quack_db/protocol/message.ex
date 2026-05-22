defmodule QuackDB.Protocol.Message do
  @moduledoc false

  defmodule Header do
    @moduledoc false

    @type t :: %__MODULE__{
            type: atom(),
            connection_id: String.t(),
            client_query_id: non_neg_integer() | nil
          }

    defstruct type: :invalid, connection_id: "", client_query_id: nil
  end

  defmodule ConnectionRequest do
    @moduledoc false

    @type t :: %__MODULE__{
            auth_string: String.t(),
            client_duckdb_version: String.t(),
            client_platform: String.t(),
            min_supported_quack_version: non_neg_integer(),
            max_supported_quack_version: non_neg_integer()
          }

    defstruct auth_string: "",
              client_duckdb_version: "",
              client_platform: "elixir",
              min_supported_quack_version: 1,
              max_supported_quack_version: 1
  end

  defmodule ConnectionResponse do
    @moduledoc false

    @type t :: %__MODULE__{
            server_duckdb_version: String.t(),
            server_platform: String.t(),
            quack_version: non_neg_integer()
          }

    defstruct server_duckdb_version: "", server_platform: "", quack_version: 0
  end

  defmodule PrepareRequest do
    @moduledoc false

    @type t :: %__MODULE__{sql_query: String.t()}

    defstruct sql_query: ""
  end

  defmodule PrepareResponse do
    @moduledoc false

    @type t :: %__MODULE__{
            result_types: [term()],
            result_names: [String.t()],
            needs_more_fetch: boolean(),
            results: [term() | nil],
            result_uuid: integer()
          }

    defstruct result_types: [],
              result_names: [],
              needs_more_fetch: false,
              results: [],
              result_uuid: 0
  end

  defmodule FetchRequest do
    @moduledoc false

    @type t :: %__MODULE__{uuid: integer()}

    defstruct uuid: 0
  end

  defmodule FetchResponse do
    @moduledoc false

    @type t :: %__MODULE__{results: [term()], batch_index: non_neg_integer() | nil}

    defstruct results: [], batch_index: nil
  end

  defmodule AppendRequest do
    @moduledoc false

    @type t :: %__MODULE__{
            schema_name: String.t(),
            table_name: String.t(),
            append_chunk: term() | nil
          }

    defstruct schema_name: "", table_name: "", append_chunk: nil
  end

  defmodule SuccessResponse do
    @moduledoc false

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule Disconnect do
    @moduledoc false

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule ErrorResponse do
    @moduledoc false

    @type t :: %__MODULE__{message: String.t()}

    defstruct message: ""
  end
end
