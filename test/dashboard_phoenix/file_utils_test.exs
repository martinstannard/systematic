defmodule DashboardPhoenix.FileUtilsTest do
  use ExUnit.Case, async: true
  
  alias DashboardPhoenix.FileUtils
  
  @moduletag :tmp_dir
  
  setup %{tmp_dir: tmp_dir} do
    {:ok, tmp_dir: tmp_dir}
  end

  describe "atomic_write/2" do
    test "writes content atomically", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      
      assert :ok = FileUtils.atomic_write(path, "hello world")
      assert File.read!(path) == "hello world"
    end

    test "creates parent directories if needed", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "deeply", "test.txt"])
      
      assert :ok = FileUtils.atomic_write(path, "nested content")
      assert File.read!(path) == "nested content"
    end

    test "overwrites existing file atomically", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "overwrite.txt")
      
      File.write!(path, "original")
      assert :ok = FileUtils.atomic_write(path, "updated")
      assert File.read!(path) == "updated"
    end

    test "cleans up temp files on write failure", %{tmp_dir: tmp_dir} do
      # Try to write to a directory (will fail)
      dir_path = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(dir_path)
      
      result = FileUtils.atomic_write(dir_path, "content")
      assert {:error, _} = result
      
      # No temp files should remain
      {:ok, files} = File.ls(tmp_dir)
      temp_files = Enum.filter(files, &String.contains?(&1, ".tmp."))
      assert temp_files == []
    end

    test "concurrent writes don't corrupt file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "concurrent.txt")
      
      # Spawn many concurrent writers
      tasks = for i <- 1..50 do
        Task.async(fn ->
          content = String.duplicate("line #{i}\n", 100)
          FileUtils.atomic_write(path, content)
          i
        end)
      end
      
      # Wait for all to complete
      results = Task.await_many(tasks, 5000)
      assert length(results) == 50
      
      # File should contain complete content from one of the writers
      content = File.read!(path)
      # Content should not be corrupted (should match pattern "line N\n" repeated)
      assert Regex.match?(~r/^(line \d+\n)+$/, content)
      
      # All lines should be from the same writer (same number)
      lines = String.split(content, "\n", trim: true)
      numbers = Enum.map(lines, fn line ->
        [_, num] = Regex.run(~r/line (\d+)/, line)
        String.to_integer(num)
      end)
      assert Enum.uniq(numbers) |> length() == 1
    end

    test "readers never see partial content during concurrent writes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "read_write.txt")
      
      # Write initial content
      FileUtils.atomic_write(path, "initial")
      
      # Start a continuous writer
      writer = Task.async(fn ->
        for i <- 1..100 do
          content = String.duplicate("write#{i}", 1000)
          FileUtils.atomic_write(path, content)
          Process.sleep(1)
        end
      end)
      
      # Start multiple concurrent readers
      readers = for _i <- 1..10 do
        Task.async(fn ->
          for _j <- 1..50 do
            content = File.read!(path)
            # Content should always be complete - either "initial" or "writeN" repeated
            cond do
              content == "initial" ->
                :ok
              Regex.match?(~r/^(write\d+)+$/, content) ->
                # Verify all repetitions are the same
                [first | rest] = Regex.scan(~r/write\d+/, content) |> Enum.map(&hd/1)
                if Enum.all?(rest, &(&1 == first)) do
                  :ok
                else
                  {:error, :mixed_content, content}
                end
              true ->
                {:error, :invalid_content, content}
            end
          end
        end)
      end
      
      # Wait for writer
      Task.await(writer, 10_000)
      
      # Check reader results
      reader_results = Task.await_many(readers, 10_000)
      
      # Flatten and check for errors
      all_results = List.flatten(reader_results)
      errors = Enum.filter(all_results, fn
        :ok -> false
        _ -> true
      end)
      
      assert errors == [], "Found read errors: #{inspect(Enum.take(errors, 5))}"
    end
  end

  describe "atomic_write!/2" do
    test "raises on error", %{tmp_dir: tmp_dir} do
      # Try to write to a directory (will fail)
      dir_path = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(dir_path)
      
      assert_raise File.Error, fn ->
        FileUtils.atomic_write!(dir_path, "content")
      end
    end
  end

  describe "atomic_write_json/2" do
    test "writes JSON content atomically", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.json")
      
      assert :ok = FileUtils.atomic_write_json(path, %{"foo" => "bar"})
      
      content = File.read!(path)
      assert {:ok, %{"foo" => "bar"}} = Jason.decode(content)
    end

    test "handles encoding errors", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid.json")
      
      # Self-referential structures can't be encoded - use a function which is not JSON-encodable
      result = FileUtils.atomic_write_json(path, fn -> :not_encodable end)
      assert {:error, {:json_encode, _}} = result
    end
  end

  describe "read_json/2" do
    test "reads and parses JSON file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "read.json")
      File.write!(path, ~s({"key": "value"}))
      
      assert {:ok, %{"key" => "value"}} = FileUtils.read_json(path)
    end

    test "returns error for missing file without default", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.json")
      
      assert {:error, :enoent} = FileUtils.read_json(path)
    end

    test "returns default for missing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.json")
      
      assert {:ok, %{}} = FileUtils.read_json(path, default: %{})
    end

    test "returns error for invalid JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid.json")
      File.write!(path, "not json")
      
      assert {:error, {:json_decode, _}} = FileUtils.read_json(path)
    end
  end

  describe "update_json/3" do
    test "updates existing JSON file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "update.json")
      FileUtils.atomic_write_json(path, %{"count" => 0})
      
      assert :ok = FileUtils.update_json(path, %{}, fn data ->
        Map.update(data, "count", 1, &(&1 + 1))
      end)
      
      assert {:ok, %{"count" => 1}} = FileUtils.read_json(path)
    end

    test "creates file with default if missing", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new.json")
      
      assert :ok = FileUtils.update_json(path, %{"count" => 0}, fn data ->
        Map.update(data, "count", 1, &(&1 + 1))
      end)
      
      assert {:ok, %{"count" => 1}} = FileUtils.read_json(path)
    end
  end

  describe "ensure_exists/2" do
    test "creates file if it doesn't exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ensure.txt")
      
      refute File.exists?(path)
      assert :ok = FileUtils.ensure_exists(path)
      assert File.exists?(path)
      assert File.read!(path) == ""
    end

    test "creates file with default content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ensure_default.txt")
      
      assert :ok = FileUtils.ensure_exists(path, "default content")
      assert File.read!(path) == "default content"
    end

    test "doesn't overwrite existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "existing.txt")
      File.write!(path, "existing content")
      
      assert :ok = FileUtils.ensure_exists(path, "new content")
      assert File.read!(path) == "existing content"
    end
  end
end
