if System.get_env("QUACKDB_TEST_URI") do
  ExUnit.start()
else
  ExUnit.start(exclude: [integration: true])
end
