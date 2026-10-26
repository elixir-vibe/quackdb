defmodule QuackDB.HeartbeatTest do
  use ExUnit.Case, async: true

  alias QuackDB.Error
  alias QuackDB.Heartbeat

  test "beats on its interval until stopped" do
    pid = start_heartbeat(fn -> :ok end, 10)

    assert_receive :beat
    assert_receive :beat

    assert :ok = Heartbeat.stop(pid)
    refute Process.alive?(pid)
  end

  test "keeps beating through transient errors" do
    pid = start_heartbeat(fn -> {:error, Error.new(:transport_error, "connection reset")} end, 10)

    assert_receive :beat
    assert_receive :beat
    assert Process.alive?(pid)
  end

  test "stops once the server reports the lease gone" do
    pid =
      start_heartbeat(fn -> {:error, Error.server("Connection heartbeat lease expired")} end, 10)

    ref = Process.monitor(pid)

    assert_receive :beat
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "dies with its owner" do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:heartbeat, start_heartbeat(fn -> :ok end, 60_000)})
        Process.sleep(:infinity)
      end)

    assert_receive {:heartbeat, pid}
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp start_heartbeat(result, interval) do
    test = self()

    beat = fn ->
      send(test, :beat)
      result.()
    end

    {:ok, pid} = Heartbeat.start_link({beat, interval})
    pid
  end
end
