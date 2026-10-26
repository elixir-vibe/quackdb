defmodule QuackDB.Heartbeat do
  @moduledoc false

  # Keeps a Quack connection's heartbeat lease alive. DuckDB renews the lease
  # only when a message arrives, so a connection busy with a long query, or
  # checked out by a slow consumer, would otherwise expire mid-use. Like
  # DuckDB's own client, this beats every third of the lease, on an HTTP
  # connection of its own so a beat never waits behind a running query.
  #
  # The process is linked to the DBConnection process that owns the lease and
  # dies with it. It stops on its own once the server reports the lease gone,
  # leaving the owner to see the error on its next request and reconnect.

  use GenServer, restart: :temporary

  alias QuackDB.Error

  @spec start_link({(-> :ok | {:error, Error.t()}), pos_integer()}) :: GenServer.on_start()
  def start_link({beat, interval})
      when is_function(beat, 0) and is_integer(interval) and interval > 0,
      do: GenServer.start_link(__MODULE__, {beat, interval})

  # Exits without waiting for a beat in flight, as a supervisor shutdown would.
  @spec stop(pid()) :: :ok
  def stop(pid) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  @impl true
  def init({beat, interval}) do
    state = %{beat: beat, interval: interval}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:beat, state) do
    if lease_lost?(state.beat.()) do
      {:stop, :normal, state}
    else
      schedule(state)
      {:noreply, state}
    end
  end

  defp lease_lost?({:error, %Error{} = error}), do: Error.disconnect?(error)
  defp lease_lost?(_result), do: false

  defp schedule(state), do: Process.send_after(self(), :beat, state.interval)
end
