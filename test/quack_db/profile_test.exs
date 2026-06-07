defmodule QuackDB.ProfileTest do
  use ExUnit.Case, async: true

  alias QuackDB.Profile
  alias QuackDB.Profile.Operator

  test "loads decoded DuckDB profiles into structs" do
    decoded = %{
      "optimizer_filter_pushdown" => 0.0001,
      query_name: "SELECT * FROM range(10)",
      latency: 0.004,
      cpu_time: 0.002,
      rows_returned: 10,
      cumulative_rows_scanned: 10,
      system_peak_buffer_memory: 1024,
      children: [
        %{
          operator_name: "RANGE",
          operator_type: "TABLE_SCAN",
          operator_timing: 0.001,
          operator_cardinality: 10,
          operator_rows_scanned: 10,
          extra_info: %{"Function" => "RANGE"},
          children: []
        }
      ]
    }

    assert %Profile{} = profile = Profile.from_decoded(decoded)
    assert profile.query_name == "SELECT * FROM range(10)"
    assert profile.optimizers == %{"filter_pushdown" => 0.0001}

    assert [%Operator{operator_name: "RANGE", extra_info: %{"Function" => "RANGE"}}] =
             profile.children
  end

  test "flattens and reports slow operators" do
    profile =
      Profile.from_decoded(%{
        latency: 0.004,
        cpu_time: 0.002,
        rows_returned: 5,
        cumulative_rows_scanned: 1_000,
        system_peak_buffer_memory: 1_736_704,
        children: [
          %{
            operator_name: "TOP_N",
            operator_type: "TOP_N",
            operator_timing: 0.0005,
            operator_cardinality: 5,
            operator_rows_scanned: 0,
            children: [
              %{
                operator_name: "RANGE",
                operator_type: "TABLE_SCAN",
                operator_timing: 0.0015,
                operator_cardinality: 1_000,
                operator_rows_scanned: 1_000,
                children: []
              }
            ]
          }
        ]
      })

    assert [range, top_n] = Profile.slowest(profile, 2)
    assert range.name == "RANGE"
    assert range.path == [0, 0]
    assert top_n.name == "TOP_N"

    report = Profile.report(profile)
    assert report =~ "DuckDB query profile"
    assert report =~ "Rows scanned:"
    assert report =~ "RANGE"
  end
end
