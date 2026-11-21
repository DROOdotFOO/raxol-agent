defmodule Raxol.AgentClientProtocol.Client.FsSandbox do
  @moduledoc """
  Confines `fs/read_text_file` and `fs/write_text_file` to a sandbox directory.
  Backs `use Raxol.AgentClientProtocol.Client, fs_sandbox: path`.

  ## Path checks

  Every request path is joined under the sandbox root and lexically
  normalized (`..` resolved via `Path.expand/1`), checked against the root,
  THEN fully symlink-resolved (`resolve/2`, a hand-rolled `realpath`) and
  checked against the root a second time -- so a `../` escape and a
  symlink planted inside the sandbox that points outside it are both
  caught, not just the lexical case. Every refusal is a `-32602 invalid
  params` `Error.t()`, safe to send straight to the peer: `data` carries a
  `"reason"` and the path the peer sent, never the resolved absolute path.

  ## Opening the file

  A path that is checked and then opened leaves a window in which a peer
  that can change the tree inside the root swaps the file for a symlink. So
  the file is opened first and the open handle verified afterwards: the
  device and inode of the handle (`:file.read_file_info/1` on it) must equal
  those of the path re-resolved with `resolve/2` and read with
  `File.lstat/1`, which does not follow a symlink at the leaf, and both
  must be a regular file. A mismatch is refused as `"path_changed"`; a leaf
  that is not a regular file (a directory, FIFO, device, or a symlink
  swapped in for one) as `"not_a_regular_file"`.

    * `read/3` checks the leaf with `File.lstat/1`, opens it read-only,
      verifies the handle, and reads at most `:max_read_bytes` (default
      16 MiB); a larger file is refused as `"file_too_large"`. `line` and
      `limit` slice what was read.
    * `write/2` creates missing parent directories one at a time, each
      checked to be a directory and not a symlink, and re-resolves the path
      afterwards. A new file is created with `O_EXCL`, which never follows
      a symlink at the leaf; an existing file is opened without truncating
      it. The handle is verified before it is truncated and written.

  ## What is and is not guaranteed

  Erlang's file API has no `openat` or `O_NOFOLLOW`, so checking a path and
  opening it are separate system calls. With the verification above:

    * Swapping the requested file itself (for a symlink, a FIFO, a device or
      another file) while a request runs cannot make the request read or
      write a file outside the root.
    * A peer that can also rename the DIRECTORIES a requested path goes
      through, and wins two races within one request (at the open and at
      the verifying `lstat`), can still redirect that request. A path whose
      only directory is the root itself is not exposed to this.
    * There is no open mode that writes an existing file without `O_CREAT`,
      so a leaf swapped for a dangling symlink at that instant, or a parent
      directory swapped as above, can create an EMPTY file or directory
      outside the root. Nothing is written into it: the handle check
      refuses first.
    * A leaf swapped for a FIFO between the `lstat` and the read-only open
      blocks that one request until the FIFO has a writer.
    * A hard link inside the root to a file outside it is that file; hard
      links are not detected.
    * On non-Unix file systems the inode is reported as zero, so the handle
      check compares only the device and the file type.

  `fs_sandbox` confines the paths the peer names. It is not a boundary
  against a peer that can also change the sandbox tree by other means
  while requests run: the checks above narrow those races but do not close
  them.
  """

  alias Raxol.AgentClientProtocol.Error

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.{
    ReadTextFileResponse,
    WriteTextFileResponse
  }

  @max_symlink_depth 40
  @default_max_read_bytes 16 * 1024 * 1024
  @read_chunk_bytes 1024 * 1024

  @doc """
  Handle `fs/read_text_file` (`req` is a `ClientTypes.ReadTextFileRequest.t()`)
  confined to `sandbox_root`.

  Options: `:max_read_bytes` (default 16 MiB), the largest file read; a
  larger one is refused as `"file_too_large"`.
  """
  @spec read(String.t(), struct(), keyword()) ::
          {:ok, ReadTextFileResponse.t()} | {:error, Error.t()}
  def read(sandbox_root, req, opts \\ []) do
    max = Keyword.get(opts, :max_read_bytes, @default_max_read_bytes)

    with {:ok, real} <- resolve(sandbox_root, req.path),
         :ok <- regular_leaf(real, req.path),
         {:ok, content} <- read_verified(sandbox_root, req.path, real, max) do
      {:ok, ReadTextFileResponse.new(slice(content, req.line, req.limit))}
    end
  end

  @doc """
  Handles `fs/write_text_file` (a `ClientTypes.WriteTextFileRequest`) confined
  to `sandbox_root`, creating parent directories as needed.
  """
  @spec write(String.t(), struct()) ::
          {:ok, WriteTextFileResponse.t()} | {:error, Error.t()}
  def write(sandbox_root, req) do
    result =
      with {:ok, real} <- resolve(sandbox_root, req.path),
           :ok <- make_parents(sandbox_root, req.path, real),
           {:ok, fd} <- open_for_write(real, req.path) do
        try do
          write_verified(fd, sandbox_root, req, real)
        after
          :file.close(fd)
        end
      end

    case result do
      {:error, %Error{}} = error -> error
      {:error, reason} -> {:error, Error.with_data(Error.internal_error(), inspect(reason))}
      ok -> ok
    end
  end

  defp write_verified(fd, root, req, real) do
    with :ok <- verify_handle(fd, root, req.path, real),
         {:ok, 0} <- :file.position(fd, :bof),
         :ok <- :file.truncate(fd),
         :ok <- :file.write(fd, req.content) do
      {:ok, WriteTextFileResponse.new()}
    end
  end

  defp regular_leaf(real, path) do
    case File.lstat(real) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, invalid_params(:not_a_regular_file, path)}

      {:error, reason} ->
        {:error, Error.with_data(Error.resource_not_found(path), inspect(reason))}
    end
  end

  defp read_verified(root, path, real, max) do
    case :file.open(real, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          with :ok <- verify_handle(fd, root, path, real) do
            read_capped(fd, path, max)
          end
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, Error.with_data(Error.resource_not_found(path), inspect(reason))}
    end
  end

  defp read_capped(fd, path, max), do: read_chunks(fd, path, max, [], 0)

  defp read_chunks(fd, path, max, acc, size) do
    case :file.read(fd, @read_chunk_bytes) do
      {:ok, data} when size + byte_size(data) > max ->
        {:error, file_too_large(path, max)}

      {:ok, data} ->
        read_chunks(fd, path, max, [acc, data], size + byte_size(data))

      :eof ->
        {:ok, IO.iodata_to_binary(acc)}

      {:error, reason} ->
        {:error, Error.with_data(Error.resource_not_found(path), inspect(reason))}
    end
  end

  defp file_too_large(path, max) do
    Error.with_data(Error.invalid_params(), %{
      "reason" => "file_too_large",
      "path" => path,
      "max_read_bytes" => max
    })
  end

  # Creates each missing directory between the real root and the leaf's
  # parent with `mkdir` (which never follows a symlink at the name it
  # creates), checks that each one is a directory and not a symlink, and then
  # requires the path to resolve exactly as it did before.
  defp make_parents(root, path, real) do
    {:ok, root_real} = real_path(Path.expand(root))
    parent = Path.dirname(real)

    with :ok <- create_dirs(root_real, parent, path) do
      case resolve(root, path) do
        {:ok, ^real} -> :ok
        {:ok, _moved} -> {:error, invalid_params(:path_changed, path)}
        {:error, _} = error -> error
      end
    end
  end

  # Nothing to create when the parent is the root, or when the leaf IS the
  # root (its parent lies above it; the open then refuses the directory).
  defp create_dirs(root_real, parent, path) do
    if within?(root_real, parent) and parent != root_real do
      parent
      |> Path.relative_to(root_real)
      |> Path.split()
      |> create_each(root_real, path)
    else
      :ok
    end
  end

  defp create_each([], _dir, _path), do: :ok

  defp create_each([comp | rest], dir, path) do
    dir = Path.join(dir, comp)

    with :ok <- make_dir(dir, path) do
      create_each(rest, dir, path)
    end
  end

  defp make_dir(dir, path) do
    with result when result in [:ok, {:error, :eexist}] <- :file.make_dir(dir) do
      case File.lstat(dir) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, %File.Stat{}} -> {:error, invalid_params(:path_changed, path)}
        {:error, _} = error -> error
      end
    end
  end

  # A missing leaf is created with O_EXCL, which fails on any existing name,
  # a symlink included, so it never follows one. An existing leaf must be a
  # regular file and is opened read-write, which does not truncate it.
  defp open_for_write(real, path) do
    case File.lstat(real) do
      {:error, :enoent} ->
        case :file.open(real, [:write, :exclusive, :binary, :raw]) do
          {:error, :eexist} -> open_existing(real, path)
          opened -> opened
        end

      {:ok, _stat} ->
        open_existing(real, path)

      {:error, _} = error ->
        error
    end
  end

  defp open_existing(real, path) do
    case File.lstat(real) do
      {:ok, %File.Stat{type: :regular}} -> :file.open(real, [:read, :write, :binary, :raw])
      {:ok, %File.Stat{}} -> {:error, invalid_params(:not_a_regular_file, path)}
      {:error, _} = error -> error
    end
  end

  # The open handle must be a regular file and the same file (device and
  # inode) as the path re-resolved now, with the leaf read by `lstat` so a
  # symlink swapped in at the leaf is seen as a symlink.
  defp verify_handle(fd, root, path, real) do
    with {:ok, record} <- :file.read_file_info(fd),
         %File.Stat{type: :regular} = opened <- File.Stat.from_record(record),
         {:ok, ^real} <- resolve(root, path),
         {:ok, %File.Stat{type: :regular} = named} <- File.lstat(real),
         true <- same_file?(opened, named) do
      :ok
    else
      %File.Stat{} -> {:error, invalid_params(:not_a_regular_file, path)}
      {:error, %Error{}} = error -> error
      _changed -> {:error, invalid_params(:path_changed, path)}
    end
  end

  defp same_file?(a, b), do: a.major_device == b.major_device and a.inode == b.inode

  @doc """
  Resolve `requested_path` against `sandbox_root`, rejecting any result
  that escapes the sandbox -- lexically (`../` traversal) or via a symlink
  (on the requested file itself or on any ancestor directory in its path).
  Returns `{:ok, real_absolute_path}` or `{:error, %Error{}}`
  (`-32602 invalid params`).
  """
  @spec resolve(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def resolve(sandbox_root, requested_path)
      when is_binary(sandbox_root) and is_binary(requested_path) do
    root = Path.expand(sandbox_root)
    lexical = Path.expand(Path.join(root, requested_path))

    with true <- within?(root, lexical) || {:error, :path_traversal},
         {:ok, root_real} <- real_path(root),
         {:ok, real} <- real_path(lexical),
         true <- within?(root_real, real) || {:error, :symlink_escape} do
      {:ok, real}
    else
      {:error, reason} -> {:error, invalid_params(reason, requested_path)}
    end
  end

  defp invalid_params(reason, path) do
    Error.with_data(Error.invalid_params(), %{
      "reason" => to_string(reason),
      "path" => path
    })
  end

  defp within?(root, path),
    do: path == root or String.starts_with?(path, root <> "/")

  # A hand-rolled `realpath`: walk components from the filesystem root with a
  # fully resolved `base`. Symlinks resolve against their real parent, so a link
  # under a symlinked ancestor cannot escape while looking interior. Missing
  # components (the write leaf) are taken literally. Only symlink hops count
  # toward the depth cap.
  defp real_path(path) do
    [root | rest] = Path.split(Path.expand(path))
    walk_real(root, rest, 0)
  end

  defp walk_real(_base, _components, depth) when depth > @max_symlink_depth,
    do: {:error, :too_many_symlinks}

  defp walk_real(base, [], _depth), do: {:ok, base}

  defp walk_real(base, ["." | rest], depth), do: walk_real(base, rest, depth)

  defp walk_real(base, [".." | rest], depth),
    do: walk_real(Path.dirname(base), rest, depth)

  defp walk_real(base, [comp | rest], depth) do
    candidate = Path.join(base, comp)

    case :file.read_link(candidate) do
      {:ok, target} ->
        {anchor, target_rest} = anchor_target(to_string(target), base)
        walk_real(anchor, target_rest ++ rest, depth + 1)

      {:error, _not_a_symlink_or_missing} ->
        walk_real(candidate, rest, depth)
    end
  end

  # Split a symlink target into the base it resolves against and the components
  # to walk from there.
  #
  # `Path.split/1` decides "absolute" per OS: `c:/tmp` has a drive anchor on
  # Windows and none on Unix. Treated as relative, a Windows-absolute target
  # would be spliced onto `base` and look interior, an escape the final
  # re-check cannot see. So drive and UNC anchors count as absolute on every
  # host; on Unix that refuses a legal-but-odd relative `c:` directory, which is
  # the safe direction.
  defp anchor_target(target, base) do
    case Path.split(target) do
      ["/" | rest] ->
        {"/", rest}

      [anchor | rest] = split ->
        case absolute_anchor(anchor) do
          nil -> {base, split}
          root -> {root, rest}
        end

      [] ->
        {base, []}
    end
  end

  # `"c:/"` (Windows split) or `"c:"` (Unix split); a bare drive is anchored at
  # its root, which refuses it.
  defp absolute_anchor(<<letter, ?:>>) when letter in ?A..?Z or letter in ?a..?z,
    do: <<letter, ?:, ?/>>

  defp absolute_anchor(<<letter, ?:, ?/>>)
       when letter in ?A..?Z or letter in ?a..?z,
       do: <<letter, ?:, ?/>>

  # UNC: two identical separators, as `:filename.win32_splitb/1` decides it. On
  # Unix a backslash UNC path never splits and arrives whole; it is refused too.
  defp absolute_anchor(<<sep, sep, _::binary>> = unc) when sep in [?/, ?\\],
    do: unc

  defp absolute_anchor(_), do: nil

  defp slice(content, nil, _limit), do: content

  defp slice(content, line, limit) when is_integer(line) do
    lines = content |> String.split("\n") |> Enum.drop(max(line - 1, 0))
    lines = if limit, do: Enum.take(lines, limit), else: lines
    Enum.join(lines, "\n")
  end
end
