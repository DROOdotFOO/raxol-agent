# The suite passes real messages between processes; a 1s assert_receive
# default keeps a slow CI host from reading late as missing.
ExUnit.configure(assert_receive_timeout: 1_000)
ExUnit.start()
