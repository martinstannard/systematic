defmodule DashboardPhoenix.ActivityLogTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.ActivityLog

  setup do
    # Clear events before each test
    ActivityLog.clear()
    :ok
  end

  describe "log_event/3" do
    test "logs a valid event and returns it" do
      {:ok, event} = ActivityLog.log_event(:task_started, "Starting feature work")

      assert event.type == :task_started
      assert event.message == "Starting feature work"
      assert event.details == %{}
      assert is_binary(event.id)
      assert %DateTime{} = event.timestamp
    end

    test "logs event with details" do
      details = %{branch: "feature-x", ticket: "PROJ-123"}
      {:ok, event} = ActivityLog.log_event(:code_complete, "Feature done", details)

      assert event.details == details
    end

    test "returns error for invalid event type" do
      {:error, :invalid_type} = ActivityLog.log_event(:invalid_type, "Nope")
    end

    test "accepts all valid event types" do
      for type <- ActivityLog.valid_event_types() do
        {:ok, event} = ActivityLog.log_event(type, "Test #{type}")
        assert event.type == type
      end
    end
  end

  describe "get_events/1" do
    test "returns empty list when no events" do
      assert ActivityLog.get_events() == []
    end

    test "returns events in most-recent-first order" do
      ActivityLog.log_event(:task_started, "First")
      ActivityLog.log_event(:code_complete, "Second")
      ActivityLog.log_event(:test_passed, "Third")

      events = ActivityLog.get_events()

      assert length(events) == 3
      assert hd(events).message == "Third"
      assert List.last(events).message == "First"
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        ActivityLog.log_event(:task_started, "Event #{i}")
      end

      assert length(ActivityLog.get_events(5)) == 5
      assert length(ActivityLog.get_events(3)) == 3
    end

    test "returns all events if limit exceeds count" do
      ActivityLog.log_event(:task_started, "Only one")

      assert length(ActivityLog.get_events(100)) == 1
    end
  end

  describe "event limit (max 50)" do
    test "keeps only the last 50 events" do
      # Log 60 events
      for i <- 1..60 do
        ActivityLog.log_event(:task_started, "Event #{i}")
      end

      events = ActivityLog.get_events(100)
      assert length(events) == 50

      # Most recent should be Event 60
      assert hd(events).message == "Event 60"
      # Oldest should be Event 11 (1-10 were dropped)
      assert List.last(events).message == "Event 11"
    end
  end

  describe "clear/0" do
    test "removes all events" do
      ActivityLog.log_event(:task_started, "Will be cleared")
      ActivityLog.log_event(:code_complete, "Also cleared")

      assert length(ActivityLog.get_events()) == 2

      :ok = ActivityLog.clear()

      assert ActivityLog.get_events() == []
    end
  end

  describe "PubSub integration" do
    test "broadcasts new events to subscribers" do
      ActivityLog.subscribe()

      {:ok, event} = ActivityLog.log_event(:merge_complete, "Branch merged")

      assert_receive {:activity_log_event, ^event}
    end

    test "unsubscribe stops receiving events" do
      ActivityLog.subscribe()
      ActivityLog.unsubscribe()

      ActivityLog.log_event(:task_started, "No notification")

      refute_receive {:activity_log_event, _}, 100
    end
  end

  describe "valid_event_types/0" do
    test "returns all expected event types" do
      types = ActivityLog.valid_event_types()

      assert :code_complete in types
      assert :merge_started in types
      assert :merge_complete in types
      assert :restart_triggered in types
      assert :restart_complete in types
      assert :test_passed in types
      assert :test_failed in types
      assert :task_started in types
    end
  end

  describe "pubsub_topic/0" do
    test "returns the topic string" do
      assert ActivityLog.pubsub_topic() == "activity_log:events"
    end
  end

  describe "event structure" do
    test "events have required fields" do
      {:ok, event} = ActivityLog.log_event(:task_started, "Test", %{foo: "bar"})

      assert Map.has_key?(event, :id)
      assert Map.has_key?(event, :type)
      assert Map.has_key?(event, :message)
      assert Map.has_key?(event, :details)
      assert Map.has_key?(event, :timestamp)
    end

    test "event IDs are unique" do
      {:ok, e1} = ActivityLog.log_event(:task_started, "One")
      {:ok, e2} = ActivityLog.log_event(:task_started, "Two")

      assert e1.id != e2.id
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(ActivityLog, :start_link, 1)
      assert function_exported?(ActivityLog, :log_event, 2)
      assert function_exported?(ActivityLog, :log_event, 3)
      assert function_exported?(ActivityLog, :get_events, 0)
      assert function_exported?(ActivityLog, :get_events, 1)
      assert function_exported?(ActivityLog, :subscribe, 0)
      assert function_exported?(ActivityLog, :unsubscribe, 0)
      assert function_exported?(ActivityLog, :clear, 0)
      assert function_exported?(ActivityLog, :valid_event_types, 0)
      assert function_exported?(ActivityLog, :pubsub_topic, 0)
    end
  end
end
