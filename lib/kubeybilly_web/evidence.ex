defmodule KubeybillyWeb.Evidence do
  @moduledoc """
  Read-only access to an incident's evidence bundle for the dashboard.

  The file list comes from `manifest.json`, never from a directory walk,
  because the manifest is the sealed account of what the collector
  captured. Reads are strictly confined to the bundle directory: any
  path containing `..`, and any path that resolves outside the bundle,
  is rejected before touching the filesystem. Content is capped at
  100KB and must be valid UTF-8 text; the dashboard shows evidence, it
  does not stream blobs.
  """

  @max_bytes 100 * 1024
  @log_file "log.md"

  @typedoc "One evidence file as the manifest records it."
  @type file :: %{path: String.t(), bytes: non_neg_integer()}

  @doc "List the bundle's files (name and size) from its manifest."
  @spec files(Path.t()) :: {:ok, [file()]} | {:error, :no_manifest | :invalid_manifest}
  def files(bundle_dir) do
    case File.read(Path.join(bundle_dir, "manifest.json")) do
      {:error, _reason} ->
        {:error, :no_manifest}

      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, %{"files" => files}} when is_list(files) -> {:ok, Enum.map(files, &entry/1)}
          _other -> {:error, :invalid_manifest}
        end
    end
  end

  defp entry(file) do
    %{path: to_string(file["path"]), bytes: file["bytes"] || 0}
  end

  @doc """
  Read one text file from inside the bundle.

  `{:error, :traversal}` for any path that is not strictly within the
  bundle directory, `:too_large` past 100KB, `:binary` for content that
  is not valid text, `:not_found` otherwise.
  """
  @spec read(Path.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :traversal | :not_found | :too_large | :binary}
  def read(bundle_dir, relative_path) do
    with :ok <- confine(bundle_dir, relative_path) do
      read_confined(Path.expand(relative_path, bundle_dir))
    end
  end

  @doc "Whether the incident's logbook report exists in the bundle."
  @spec log_present?(Path.t()) :: boolean()
  def log_present?(bundle_dir), do: File.regular?(Path.join(bundle_dir, @log_file))

  @doc "The logbook report's bundle-relative name."
  @spec log_file() :: String.t()
  def log_file, do: @log_file

  # Belt and braces: the literal ".." check catches crafted names even
  # on filesystems with exotic normalization, and the expand check
  # catches absolute paths and anything else escaping the bundle.
  defp confine(bundle_dir, relative_path) do
    root = Path.expand(bundle_dir)
    resolved = Path.expand(relative_path, bundle_dir)

    cond do
      String.contains?(relative_path, "..") -> {:error, :traversal}
      not String.starts_with?(resolved, root <> "/") -> {:error, :traversal}
      true -> :ok
    end
  end

  defp read_confined(absolute) do
    case File.stat(absolute) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_bytes ->
        {:error, :too_large}

      {:ok, %File.Stat{type: :regular}} ->
        read_text(absolute)

      _missing_or_directory ->
        {:error, :not_found}
    end
  end

  defp read_text(absolute) do
    case File.read(absolute) do
      {:ok, content} ->
        if String.valid?(content), do: {:ok, content}, else: {:error, :binary}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end
end
