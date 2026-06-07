defmodule QuackDB.ProfileTest do
  use ExUnit.Case, async: true

  alias QuackDB.Profile
  alias QuackDB.Profile.Operator

  test "flattens and reports slow operators" do
    profile = %Profile{
      latency: 0.004,
      cpu_time: 0.002,
      rows_returned: 5,
      cumulative_rows_scanned: 1_000,
      system_peak_buffer_memory: 1_736_704,
      children: [
        %Operator{
          operator_name: "TOP_N",
          operator_type: "TOP_N",
          operator_timing: 0.0005,
          operator_cardinality: 5,
          operator_rows_scanned: 0,
          children: [
            %Operator{
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
    }

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
