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

            {:error, reason} ->
              Logger.warning("Failed to decode state from #{path}: #{inspect(reason)}")
              default_state
          end

        {:error, reason} ->
          Logger.warning("Failed to read state from #{path}: #{inspect(reason)}")
          default_state
      end
    else
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
      content = Jason.encode!(state)
      File.write!(tmp_path, content)
      File.rename!(tmp_path, path)
      :ok
    rescue
      e ->
        Logger.error("Failed to save state to #{path}: #{inspect(e)}")
        # Clean up tmp file if it exists
        File.rm(tmp_path)
        {:error, e}
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
