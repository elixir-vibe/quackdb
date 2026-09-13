defmodule QuackDB.ServerFixture do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  # All waits except Server's explicitly tested deadline are deadlock safeguards.
  @guard_timeout 5_000

  def start!(output, options \\ []) do
    ref = make_ref()
    # Fixed byte length also makes Unicode truncation boundaries reproducible.
    marker = "quackdb-output-complete-" <> Base.encode16(:crypto.strong_rand_bytes(16))
    dir = Path.join(System.tmp_dir!(), marker)
    File.mkdir!(dir)
    output_path = Path.join(dir, "output")
    control_path = Path.join(dir, "control")
    payload = output <> "\n" <> marker <> "\n"
    File.write!(output_path, payload)
    {"", 0} = System.cmd("mkfifo", [control_path])
    # Opening both ends avoids blocking the test on FIFO open, including teardown.
    control = File.open!(control_path, [:read, :write])
    name = {:global, {__MODULE__, ref}}
    parent = self()

    daemon_options =
      observe_output(Keyword.get(options, :daemon_options, []), parent, ref, marker)

    options =
      [uri: "http://127.0.0.1:1", token: "secret", wait_timeout: 30_000]
      |> Keyword.merge(options)
      |> Keyword.put(:name, name)
      |> Keyword.put(:daemon_options, daemon_options)
      |> Keyword.put(
        :daemon_command,
        {"sh",
         [
           "-c",
           ~S(cat "$1"; IFS= read -r status < "$2"; exit "$status"),
           "sh",
           output_path,
           control_path
         ]}
      )

    startup =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        QuackDB.Server.start_link(options)
      end)

    on_exit(fn ->
      if server = GenServer.whereis(name), do: Process.exit(server, :kill)
      Process.exit(startup.pid, :kill)
      File.close(control)
      File.rm_rf!(dir)
    end)

    assert_receive {:output_complete, ^ref, daemon}, @guard_timeout
    # The sentinel callback runs inside handle_info. This call cannot complete
    # until MuonTrap has also acknowledged those output bytes to its port.
    assert %{output_byte_count: count} = MuonTrap.Daemon.statistics(daemon)
    assert count == byte_size(payload)

    %{
      startup: startup,
      daemon: daemon,
      name: name,
      control: control,
      marker: marker,
      output: payload
    }
  end

  def finish!(fixture, status \\ 1) do
    :ok = IO.puts(fixture.control, status)
    await_error!(fixture)
  end

  def await_error!(fixture) do
    assert {:error, {%QuackDB.Error{} = error, _stack}} =
             Task.await(fixture.startup, @guard_timeout + 5_000)

    error
  end

  def suspend_probe!(fixture) do
    server = GenServer.whereis(fixture.name)
    {:links, links} = Process.info(server, :links)
    # This lifecycle test deliberately identifies the separate probe task:
    # the other links are the startup caller and the acknowledged daemon.
    assert [probe] =
             Enum.filter(links, &(is_pid(&1) and &1 not in [fixture.startup.pid, fixture.daemon]))

    monitor = Process.monitor(probe)
    true = :erlang.suspend_process(probe)
    {probe, monitor}
  end

  defp observe_output(options, parent, ref, marker) do
    key = if Keyword.has_key?(options, :log_output), do: :log_transform, else: :logger_fun
    callback = Keyword.get(options, key, &Function.identity/1)

    Keyword.put(options, key, fn line ->
      result = callback.(line)
      if line == marker, do: send(parent, {:output_complete, ref, self()})
      result
    end)
  end
end
