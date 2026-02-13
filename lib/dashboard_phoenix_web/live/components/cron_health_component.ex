defmodule DashboardPhoenixWeb.Live.Components.CronHealthComponent do
  @moduledoc """
  LiveComponent for monitoring OpenClaw cron job health.

  Displays all cron jobs with:
  - Job name and schedule
  - Last run status (success/error/running/never)
  - Last run time (relative)
  - Next scheduled run
  - Enabled/disabled status
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    socket =
      assign(socket,
        cron_jobs: assigns[:cron_jobs] || [],
        cron_jobs_count: assigns[:cron_jobs_count] || 0,
        cron_loading: Map.get(assigns, :cron_loading, false),
        cron_collapsed: Map.get(assigns, :cron_collapsed, false),
        cron_error: assigns[:cron_error]
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_panel", _params, socket) do
    send(self(), {:cron_health_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    send(self(), {:cron_health_component, :refresh})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-status overflow-hidden" role="region" aria-label="Cron job health monitoring">
      <div
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
        role="button"
        tabindex="0"
        aria-expanded={if(@cron_collapsed, do: "false", else: "true")}
        aria-controls="cron-health-content"
        aria-label="Toggle cron health panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span
            class={"panel-chevron " <> if(@cron_collapsed, do: "collapsed", else: "")}
            aria-hidden="true"
          >
            ▼
          </span>
          <span class="panel-icon opacity-60" aria-hidden="true">⏰</span>
          <span class="text-panel-label text-base-content/60">Cron Jobs</span>
          <%= if @cron_loading do %>
            <span class="status-activity-ring text-accent" aria-hidden="true"></span>
            <span class="sr-only">Loading cron jobs</span>
          <% else %>
            <span class="text-xs font-mono text-base-content/50">{@cron_jobs_count}</span>
          <% end %>
        </div>
        
        <div class="flex items-center space-x-2">
          <%= if has_errors?(@cron_jobs) do %>
            <span class="text-error text-xs font-mono" role="status" aria-live="polite">
              ❌ {count_errors(@cron_jobs)} errors
            </span>
          <% end %>
          <button
            phx-click="refresh"
            phx-target={@myself}
            class="text-xs px-2 py-1 bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
            aria-label="Refresh cron jobs"
            title="Refresh"
          >
            🔄
          </button>
        </div>
      </div>

      <div
        id="cron-health-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@cron_collapsed, do: "max-h-0", else: "max-h-[500px] overflow-y-auto")}
      >
        <div class="px-4 pb-4">
          <%= if @cron_loading do %>
            <div class="flex items-center justify-center py-8 space-x-2">
              <span class="throbber-small"></span>
              <span class="text-ui-caption text-base-content/60">Loading cron jobs...</span>
            </div>
          <% else %>
            <%= if @cron_error do %>
              <div class="py-4 px-4 bg-error/10 border border-error/30 rounded">
                <div class="flex items-center space-x-2">
                  <span class="text-error">⚠️</span>
                  <span class="text-sm text-error">Error loading cron jobs:</span>
                </div>
                <pre class="text-xs text-error/70 mt-2 font-mono overflow-x-auto">{@cron_error}</pre>
              </div>
            <% else %>
              <%= if @cron_jobs_count == 0 do %>
                <div class="text-center py-8 text-base-content/40">
                  <div class="text-3xl mb-2">⏰</div>
                  <div class="text-sm">No cron jobs configured</div>
                </div>
              <% else %>
                <div class="space-y-2 mt-3">
                  <%= for job <- @cron_jobs do %>
                    <div class={[
                      "px-3 py-3 rounded border",
                      job_card_classes(job)
                    ]}>
                      <div class="flex items-start justify-between gap-3">
                        <div class="flex-1 min-w-0">
                          <!-- Job name and status -->
                          <div class="flex items-center gap-2 mb-1">
                            <span class="font-mono font-semibold text-sm text-white truncate">
                              {job.name}
                            </span>
                            <%= unless job.enabled do %>
                              <span class="text-xs px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/50">
                                disabled
                              </span>
                            <% end %>
                          </div>
                          
                          <!-- Schedule -->
                          <div class="text-xs font-mono text-base-content/50 mb-2">
                            {format_schedule(job.schedule)}
                          </div>
                          
                          <!-- Last run info -->
                          <div class="flex items-center gap-3 text-xs">
                            <div class="flex items-center gap-1.5">
                              <span class="text-base-content/40">Last run:</span>
                              <%= if job.state.lastRunAtMs do %>
                                <span class={status_text_class(job.state.lastStatus)}>
                                  {status_icon(job.state.lastStatus)}
                                </span>
                                <span class="text-base-content/60">
                                  {format_relative_time(job.state.lastRunAtMs)}
                                </span>
                                <span class="text-base-content/30">
                                  ({format_duration(job.state.lastDurationMs)})
                                </span>
                              <% else %>
                                <span class="text-base-content/40 italic">never</span>
                              <% end %>
                            </div>
                            
                            <!-- Consecutive errors -->
                            <%= if job.state.consecutiveErrors > 0 do %>
                              <div class="flex items-center gap-1.5 text-error">
                                <span>🔴</span>
                                <span class="font-semibold">{job.state.consecutiveErrors}</span>
                                <span>consecutive {if job.state.consecutiveErrors == 1, do: "error", else: "errors"}</span>
                              </div>
                            <% end %>
                          </div>
                          
                          <!-- Next run -->
                          <%= if job.enabled && job.state.nextRunAtMs do %>
                            <div class="text-xs text-base-content/40 mt-1">
                              Next: {format_relative_time(job.state.nextRunAtMs, :future)}
                            </div>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp has_errors?(jobs) do
    Enum.any?(jobs, fn job ->
      job.state[:lastStatus] == "error" || job.state[:consecutiveErrors] > 0
    end)
  end

  defp count_errors(jobs) do
    Enum.count(jobs, fn job ->
      job.state[:lastStatus] == "error" || job.state[:consecutiveErrors] > 0
    end)
  end

  defp job_card_classes(job) do
    cond do
      !job.enabled ->
        "bg-base-content/5 border-base-content/10"

      job.state[:lastStatus] == "error" || job.state[:consecutiveErrors] > 0 ->
        "bg-error/10 border-error/30"

      job.state[:lastStatus] == "running" ->
        "bg-warning/10 border-warning/30"

      job.state[:lastStatus] == "ok" ->
        "bg-white/5 border-white/10"

      true ->
        "bg-white/5 border-white/10"
    end
  end

  defp status_icon(status) do
    case status do
      "ok" -> "✅"
      "error" -> "❌"
      "running" -> "⏳"
      _ -> "⚪"
    end
  end

  defp status_text_class(status) do
    case status do
      "ok" -> "text-success"
      "error" -> "text-error"
      "running" -> "text-warning"
      _ -> "text-base-content/40"
    end
  end

  defp format_schedule(%{"kind" => "cron", "expr" => expr, "tz" => tz}) do
    "#{expr} (#{tz})"
  end

  defp format_schedule(%{"kind" => "every", "everyMs" => ms}) do
    minutes = div(ms, 60_000)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "Every #{days} #{if days == 1, do: "day", else: "days"}"
      hours > 0 -> "Every #{hours} #{if hours == 1, do: "hour", else: "hours"}"
      minutes > 0 -> "Every #{minutes} #{if minutes == 1, do: "minute", else: "minutes"}"
      true -> "Every #{ms}ms"
    end
  end

  defp format_schedule(%{"kind" => "at", "atMs" => at_ms}) do
    dt = DateTime.from_unix!(at_ms, :millisecond)
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_schedule(_), do: "Unknown schedule"

  defp format_relative_time(timestamp_ms, mode \\ :past)
  defp format_relative_time(nil, _mode), do: "never"

  defp format_relative_time(timestamp_ms, mode) when is_integer(timestamp_ms) do
    now_ms = System.system_time(:millisecond)
    diff_ms = abs(now_ms - timestamp_ms)
    diff_seconds = div(diff_ms, 1000)
    diff_minutes = div(diff_seconds, 60)
    diff_hours = div(diff_minutes, 60)
    diff_days = div(diff_hours, 24)

    prefix = if mode == :future, do: "in ", else: ""
    suffix = if mode == :past, do: " ago", else: ""

    time_str =
      cond do
        diff_days > 0 -> "#{diff_days} #{if diff_days == 1, do: "day", else: "days"}"
        diff_hours > 0 -> "#{diff_hours} #{if diff_hours == 1, do: "hour", else: "hours"}"
        diff_minutes > 0 -> "#{diff_minutes} #{if diff_minutes == 1, do: "min", else: "mins"}"
        true -> "#{diff_seconds} sec"
      end

    "#{prefix}#{time_str}#{suffix}"
  end

  defp format_duration(nil), do: "?"

  defp format_duration(ms) when is_integer(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)

    cond do
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end
end
