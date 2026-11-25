defmodule Raxol.CLI.Updater.State do
  @moduledoc """
  The updater's persisted settings: a struct, pure transitions over it, and
  `load/1` and `save/2` as the only functions that touch the file.

  The file is `~/.raxol/update_settings.json` unless the caller passes
  `:settings_path` (see `path/1`). A missing, unreadable or malformed file
  loads as the defaults, and a key that is unknown or holds the wrong type
  keeps its default: nothing read from the file becomes an atom.
  """

  alias Raxol.CLI.Updater.Validation

  @default_check_interval 86_400

  @enforce_keys [:download_path, :backup_path]
  defstruct [
    :download_path,
    :backup_path,
    auto_check: true,
    check_interval: @default_check_interval,
    last_check: nil
  ]

  @typedoc """
    * `:auto_check` - whether interval-gated checks run at all
    * `:check_interval` - seconds between automatic checks
    * `:last_check` - Unix seconds of the last automatic check, if any
    * `:download_path` - where `download_update/2` stores a verified asset
    * `:backup_path` - where an install keeps the executable it replaced
  """
  @type t :: %__MODULE__{
          auto_check: boolean(),
          check_interval: pos_integer(),
          last_check: non_neg_integer() | nil,
          download_path: Path.t(),
          backup_path: Path.t()
        }

  @doc "The default settings, with paths under `home`'s `.raxol` directory."
  @spec new(Path.t()) :: t()
  def new(home \\ System.user_home!()) do
    root = Path.expand(Path.join(home, ".raxol"))

    %__MODULE__{
      download_path: Path.join(root, "downloads"),
      backup_path: Path.join(root, "backups")
    }
  end

  @spec set_auto_check(t(), boolean()) :: t()
  def set_auto_check(%__MODULE__{} = state, enabled) when is_boolean(enabled),
    do: %{state | auto_check: enabled}

  @doc "Whether an automatic check is due at `now` (Unix seconds)."
  @spec check_due?(t(), integer()) :: boolean()
  def check_due?(%__MODULE__{} = state, now),
    do: Validation.should_check_for_update?(Map.from_struct(state), now)

  @doc "Records an automatic check made at `now` (Unix seconds)."
  @spec checked(t(), non_neg_integer()) :: t()
  def checked(%__MODULE__{} = state, now) when is_integer(now) and now >= 0,
    do: %{state | last_check: now}

  @doc "Settings decoded from `json`, each missing or invalid field taken from `defaults`."
  @spec decode(binary(), t()) :: t()
  def decode(json, %__MODULE__{} = defaults) do
    case Jason.decode(json) do
      {:ok, %{} = fields} -> Enum.reduce(fields, defaults, &put_field/2)
      _malformed -> defaults
    end
  end

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = state), do: state |> Map.from_struct() |> Jason.encode!()

  @doc "The settings file: `opts[:settings_path]`, else `~/.raxol/update_settings.json`."
  @spec path(keyword()) :: Path.t()
  def path(opts) do
    Keyword.get_lazy(opts, :settings_path, fn ->
      Path.join([System.user_home!(), ".raxol", "update_settings.json"])
    end)
  end

  @doc "Reads the settings at `path`; the defaults when there are none to read."
  @spec load(Path.t()) :: t()
  def load(path) do
    case File.read(path) do
      {:ok, json} -> decode(json, new())
      {:error, _reason} -> new()
    end
  end

  @doc """
  Writes `state` to `path`. The file is replaced by a rename, so a reader
  never sees half of it.
  """
  @spec save(t(), Path.t()) :: :ok | {:error, File.posix()}
  def save(%__MODULE__{} = state, path) do
    staged = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(staged, encode(state)),
         :ok <- File.rename(staged, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(staged)
        error
    end
  end

  defp put_field({"auto_check", value}, state) when is_boolean(value),
    do: %{state | auto_check: value}

  defp put_field({"check_interval", value}, state) when is_integer(value) and value > 0,
    do: %{state | check_interval: value}

  defp put_field({"last_check", value}, state) when is_integer(value) and value >= 0,
    do: %{state | last_check: value}

  defp put_field({"download_path", value}, state) when is_binary(value) and value != "",
    do: %{state | download_path: value}

  defp put_field({"backup_path", value}, state) when is_binary(value) and value != "",
    do: %{state | backup_path: value}

  defp put_field(_unknown_or_invalid, state), do: state
end
