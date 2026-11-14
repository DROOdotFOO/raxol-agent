# A peer that can create entries inside the sandbox swaps the requested file
# between a regular file and a symlink to a file outside the root while
# reads and writes of that path run. Nothing outside the root may change, and
# no read may return its content. Bounded by iteration count, not by time.
defmodule Raxol.AgentClientProtocol.Client.FsSandboxRaceTest do
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Client.FsSandbox
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.{ReadTextFileRequest, WriteTextFileRequest}

  @iterations 2_000
  @secret "OUTSIDE-SECRET"

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "acp_fs_sandbox_race_#{System.unique_integer([:positive, :monotonic])}"
      )

    root = Path.join(base, "root")
    outside = Path.join(base, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    victim = Path.join(outside, "victim.txt")
    File.write!(victim, @secret)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, root: root, victim: victim}
  end

  describe "a leaf swapped between a regular file and a symlink out of the root" do
    test "never writes outside the root and never reads from outside it", ctx do
      leaf = Path.join(ctx.root, "f.txt")
      File.write!(leaf, "inside")
      swapper = start_swapper(leaf, ctx.victim)

      writer =
        Task.async(fn ->
          for i <- 1..@iterations do
            FsSandbox.write(ctx.root, WriteTextFileRequest.new("s", "f.txt", "PWNED-#{i}"))
          end
        end)

      reader =
        Task.async(fn ->
          for _ <- 1..@iterations,
              do: FsSandbox.read(ctx.root, ReadTextFileRequest.new("s", "f.txt"))
        end)

      writes = Task.await(writer, 120_000)
      reads = Task.await(reader, 120_000)
      stop_swapper(swapper)

      assert File.read!(ctx.victim) == @secret

      leaked = for {:ok, resp} <- reads, resp.content =~ @secret, do: resp.content
      assert leaked == []

      # Every outcome is a success or a wire error; nothing raised or hung.
      assert Enum.all?(writes ++ reads, &match?({tag, _} when tag in [:ok, :error], &1))
    end
  end

  describe "the leaf must be a regular file" do
    test "a directory is refused for read and write", ctx do
      File.mkdir_p!(Path.join(ctx.root, "dir"))

      assert {:error, read_err} = FsSandbox.read(ctx.root, ReadTextFileRequest.new("s", "dir"))
      assert read_err.data["reason"] == "not_a_regular_file"

      assert {:error, write_err} =
               FsSandbox.write(ctx.root, WriteTextFileRequest.new("s", "dir", "x"))

      assert write_err.data["reason"] == "not_a_regular_file"
    end

    @tag skip: if(match?({:win32, _}, :os.type()), do: "no mkfifo on Windows", else: false)
    test "a FIFO is refused without blocking", ctx do
      fifo = Path.join(ctx.root, "pipe")
      {_, 0} = System.cmd("mkfifo", [fifo])

      assert {:error, read_err} = FsSandbox.read(ctx.root, ReadTextFileRequest.new("s", "pipe"))
      assert read_err.data["reason"] == "not_a_regular_file"

      assert {:error, write_err} =
               FsSandbox.write(ctx.root, WriteTextFileRequest.new("s", "pipe", "x"))

      assert write_err.data["reason"] == "not_a_regular_file"
    end

    test "a symlink to a regular file inside the root is followed", ctx do
      File.write!(Path.join(ctx.root, "target.txt"), "real")
      File.ln_s!("target.txt", Path.join(ctx.root, "link.txt"))

      assert {:ok, resp} = FsSandbox.read(ctx.root, ReadTextFileRequest.new("s", "link.txt"))
      assert resp.content == "real"
    end
  end

  describe "writes" do
    test "replace a longer file completely and create missing directories", ctx do
      File.write!(Path.join(ctx.root, "f.txt"), "a much longer original content")

      assert {:ok, _} = FsSandbox.write(ctx.root, WriteTextFileRequest.new("s", "f.txt", "short"))
      assert File.read!(Path.join(ctx.root, "f.txt")) == "short"

      assert {:ok, _} =
               FsSandbox.write(ctx.root, WriteTextFileRequest.new("s", "a/b/c.txt", "nested"))

      assert File.read!(Path.join(ctx.root, "a/b/c.txt")) == "nested"
    end

    test "do not create a directory through a symlinked parent", ctx do
      File.ln_s!(Path.dirname(ctx.victim), Path.join(ctx.root, "out"))

      assert {:error, err} =
               FsSandbox.write(ctx.root, WriteTextFileRequest.new("s", "out/new/x.txt", "x"))

      assert err.data["reason"] == "symlink_escape"
      refute File.exists?(Path.join(Path.dirname(ctx.victim), "new"))
    end
  end

  describe "the read cap" do
    test "a file over :max_read_bytes is refused", ctx do
      File.write!(Path.join(ctx.root, "big.txt"), String.duplicate("x", 2_000))

      assert {:error, err} =
               FsSandbox.read(ctx.root, ReadTextFileRequest.new("s", "big.txt"),
                 max_read_bytes: 1_000
               )

      assert err.data["reason"] == "file_too_large"
      assert err.data["max_read_bytes"] == 1_000

      assert {:ok, resp} =
               FsSandbox.read(ctx.root, ReadTextFileRequest.new("s", "big.txt"),
                 max_read_bytes: 2_000
               )

      assert byte_size(resp.content) == 2_000
    end

    test "fs_max_read_bytes sets the cap of the generated callback", ctx do
      root = ctx.root
      File.write!(Path.join(root, "big.txt"), String.duplicate("x", 64))
      name = Raxol.AgentClientProtocol.Client.FsSandboxRaceTest.CappedClient

      Code.compile_quoted(
        quote do
          defmodule unquote(name) do
            use Raxol.AgentClientProtocol.Client,
              fs_sandbox: unquote(root),
              fs_max_read_bytes: 10
          end
        end
      )

      assert {:error, err} = name.read_text_file(ReadTextFileRequest.new("s", "big.txt"), %{})
      assert err.data["reason"] == "file_too_large"
    end
  end

  # Flips `leaf` between a regular file and a symlink to `victim` until told
  # to stop, both by renaming each state into place (the name always exists)
  # and by removing and recreating it.
  defp start_swapper(leaf, victim) do
    tmp_file = leaf <> ".swap-file"
    tmp_link = leaf <> ".swap-link"
    parent = self()

    pid =
      spawn_link(fn ->
        send(parent, {:swapper, :started})
        swap_loop(leaf, victim, tmp_file, tmp_link)
      end)

    assert_receive {:swapper, :started}
    pid
  end

  defp swap_loop(leaf, victim, tmp_file, tmp_link) do
    receive do
      {:stop, from} ->
        send(from, {:swapper, :stopped})
    after
      0 ->
        File.rm(tmp_link)
        File.ln_s(victim, tmp_link)
        File.rename(tmp_link, leaf)
        File.write(tmp_file, "inside")
        File.rename(tmp_file, leaf)
        File.rm(leaf)
        File.ln_s(victim, leaf)
        File.rm(leaf)
        File.write(leaf, "inside")
        swap_loop(leaf, victim, tmp_file, tmp_link)
    end
  end

  defp stop_swapper(pid) do
    send(pid, {:stop, self()})
    assert_receive {:swapper, :stopped}, 5_000
  end
end
