defmodule DashboardPhoenix.StatePersistence do
  @moduledoc """
  Handles persisting and loading monitor state to/from JSON files in the priv/ directory.
  Uses atomic writes to prevent corruption.
  """
  require Logger

  @doc """
  Loads state from a JSON file in the priv/ directory.
  Returns default_state if the file doesn't exist or is invalid.
  """
  def load(filename, default_state) do
    path = get_path(filename)

    try do
      if File.exists?(path) do
        case File.read(path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, data} ->
                # Merge with default state to ensure all keys exist if structure changed
                # This is simple for maps, but might need more care for nested structures
                if is_map(data) and is_map(default_state) do
                  # Convert string keys to atoms if default_state uses atoms
                  data = sanitize_keys(data, default_state)
                  Map.merge(default_state, data)
                else
                  data
                end

              {:error, %Jason.DecodeError{} = e} ->
                Logger.warning("StatePersistence: Failed to decode JSON from #{path}: #{Exception.message(e)}")
                default_state
              {:error, reason} ->
                Logger.warning("StatePersistence: JSON decode error from #{path}: #{inspect(reason)}")
                default_state
            end

          {:error, :enoent} ->
            Logger.debug("StatePersistence: State file #{path} does not exist, using default state")
            default_state
          {:error, :eacces} ->
            Logger.warning("StatePersistence: Permission denied reading state file #{path}")
            default_state
          {:error, reason} ->
            Logger.warning("StatePersistence: Failed to read state from #{path}: #{inspect(reason)}")
            default_state
        end
      else
        Logger.debug("StatePersistence: State file #{path} does not exist, using default state")
        default_state
      end
    rescue
      e ->
        Logger.error("StatePersistence: Exception loading state from #{filename}: #{inspect(e)}")
        default_state
    end
  end

  @doc """
  Saves state to a JSON file in the priv/ directory using atomic write.
  """
  def save(filename, state) do
    path = get_path(filename)
    tmp_path = path <> ".tmp"

    try do
      with :ok <- ensure_directory(path),
           {:ok, content} <- encode_json(filename, state),
           :ok <- write_atomic(path, tmp_path, content, filename) do
        :ok
      end
    rescue
      e ->
        Logger.error("StatePersistence: Exception saving state to #{filename}: #{inspect(e)}")
        File.rm(tmp_path)
        {:error, {:exception, e}}
    end
  end

  defp ensure_directory(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("StatePersistence: Failed to create directory for #{path}: #{inspect(reason)}")
        {:error, {:mkdir, reason}}
    end
  end

  defp encode_json(filename, state) do
    case Jason.encode(state) do
      {:ok, content} ->
        {:ok, content}
      {:error, %Jason.EncodeError{} = e} ->
        Logger.error("StatePersistence: Failed to encode state as JSON for #{filename}: #{Exception.message(e)}")
        {:error, {:json_encode, e}}
      {:error, reason} ->
        Logger.error("StatePersistence: JSON encode error for #{filename}: #{inspect(reason)}")
        {:error, {:json_encode, reason}}
    end
  end

  defp write_atomic(path, tmp_path, content, filename) do
    case File.write(tmp_path, content) do
      :ok ->
        case File.rename(tmp_path, path) do
          :ok ->
            Logger.debug("StatePersistence: Successfully saved state to #{filename}")
            :ok
          {:error, reason} ->
            Logger.error("StatePersistence: Failed to rename #{tmp_path} to #{path}: #{inspect(reason)}")
            File.rm(tmp_path)
            {:error, {:rename, reason}}
        end
      {:error, reason} ->
        Logger.error("StatePersistence: Failed to write to #{tmp_path}: #{inspect(reason)}")
        {:error, {:write, reason}}
    end
  end

  defp get_path(filename) do
    Path.join(:code.priv_dir(:dashboard_phoenix), filename)
  end

  # Convert string keys to atoms if they exist in the default_state
  defp sanitize_keys(data, default_state) when is_map(data) and is_map(default_state) do
    for {k, v} <- data, into: %{} do
      key =
        if is_binary(k) do
          # Try to find a matching atom key in default_state
          atom_key =
            try do
              String.to_existing_atom(k)
            rescue
              _ -> k
            end

          if Map.has_key?(default_state, atom_key), do: atom_key, else: k
        else
          k
        end

      # Recursively sanitize nested structures
      val = sanitize_value(v, Map.get(default_state, key))

      {key, val}
    end
  end

  defp sanitize_keys(data, _), do: data

  defp sanitize_value(v, default_v) when is_map(v) and is_map(default_v) do
    if Map.has_key?(default_v, :__template__) do
      # All values in this map should follow the template
      template = Map.get(default_v, :__template__)

      for {k, val} <- v, into: %{} do
        {k, sanitize_keys(val, template)}
      end
    else
      sanitize_keys(v, default_v)
    end
  end

  defp sanitize_value(v, [default_item | _]) when is_list(v) and is_map(default_item) do
    Enum.map(v, fn item -> sanitize_keys(item, default_item) end)
  end

  defp sanitize_value(v, _), do: v
end
