# `:integration` boots `raxol mcp` as an OS process; CI runs it in its own step
# (ci.yml, "Run raxol mcp subprocess tests").
ExUnit.start(exclude: [:integration])
