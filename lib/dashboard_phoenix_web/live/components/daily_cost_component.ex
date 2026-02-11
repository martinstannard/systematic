defmodule DashboardPhoenixWeb.Live.Components.DailyCostComponent do
  @moduledoc """
  Displays daily aggregate spend from all agent sessions.
  Shows total cost for today as a compact banner at the top of the overview tab.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    sessions = Map.get(assigns, :agent_sessions, [])
    today_start = today_start_unix_ms()

    # Filter to today's sessions and sum costs
    {today_cost, today_count, total_tokens_in, total_tokens_out} =
      sessions
      |> Enum.filter(fn s ->
        updated = Map.get(s, :updated_at, 0)
        updated >= today_start
      end)
      |> Enum.reduce({0.0, 0, 0, 0}, fn s, {cost_acc, count_acc, in_acc, out_acc} ->
        cost = Map.get(s, :cost, 0) || 0
        tokens_in = Map.get(s, :tokens_in, 0) || 0
        tokens_out = Map.get(s, :tokens_out, 0) || 0
        {cost_acc + cost, count_acc + 1, in_acc + tokens_in, out_acc + tokens_out}
      end)

    socket =
      socket
      |> assign(:today_cost, today_cost)
      |> assign(:today_session_count, today_count)
      |> assign(:today_tokens_in, total_tokens_in)
      |> assign(:today_tokens_out, total_tokens_out)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-content-compact p-3 mb-4" role="region" aria-label="Daily cost summary">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <span class="text-lg" aria-hidden="true">💰</span>
          <div>
            <span class="text-ui-label text-base-content/60">Today's Spend</span>
            <div class="flex items-center gap-3 mt-0.5">
              <span class={[
                "text-xl font-semibold",
                cost_color(@today_cost)
              ]}>
                {format_cost(@today_cost)}
              </span>
              <span class="text-ui-caption text-base-content/40">
                {pluralize(@today_session_count, "session")}
              </span>
            </div>
          </div>
        </div>
        <div class="flex items-center gap-4 text-ui-caption text-base-content/40">
          <span title="Input tokens today">
            ↓ {format_tokens(@today_tokens_in)}
          </span>
          <span title="Output tokens today">
            ↑ {format_tokens(@today_tokens_out)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp today_start_unix_ms do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp format_cost(cost) when cost >= 1.0, do: "$#{Float.round(cost, 2)}"
  defp format_cost(cost) when cost >= 0.01, do: "$#{Float.round(cost, 2)}"
  defp format_cost(cost) when cost > 0, do: "$#{Float.round(cost, 4)}"
  defp format_cost(_), do: "$0.00"

  defp cost_color(cost) when cost >= 10.0, do: "text-error"
  defp cost_color(cost) when cost >= 5.0, do: "text-warning"
  defp cost_color(_), do: "text-success"

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n) when is_number(n), do: "#{n}"
  defp format_tokens(_), do: "0"

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(n, word), do: "#{n} #{word}s"
end
