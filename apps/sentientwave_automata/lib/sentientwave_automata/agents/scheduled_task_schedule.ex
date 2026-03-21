defmodule SentientwaveAutomata.Agents.ScheduledTaskSchedule do
  @moduledoc """
  Computes next-run timestamps for agent scheduled tasks.
  """

  alias SentientwaveAutomata.Agents.ScheduledTask

  @spec initial_next_run(ScheduledTask.t() | map(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def initial_next_run(task, now \\ DateTime.utc_now()) do
    with {:ok, local_now} <- shift_zone(now, timezone(task)) do
      case schedule_type(task) do
        :hourly -> hourly_initial(task, local_now)
        :daily -> daily_initial(task, local_now)
        :weekly -> weekly_initial(task, local_now)
        other -> {:error, {:unsupported_schedule_type, other}}
      end
    end
  end

  @spec next_run_after(ScheduledTask.t() | map(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def next_run_after(task, from_utc) do
    with {:ok, local_from} <- shift_zone(from_utc, timezone(task)) do
      case schedule_type(task) do
        :hourly -> add_local_interval(local_from, timezone(task), :hourly, interval(task))
        :daily -> add_local_interval(local_from, timezone(task), :daily, interval(task))
        :weekly -> add_local_interval(local_from, timezone(task), :weekly, interval(task))
        other -> {:error, {:unsupported_schedule_type, other}}
      end
    end
  end

  defp hourly_initial(task, local_now) do
    candidate_hour = local_now.hour - rem(local_now.hour, interval(task))

    with {:ok, candidate} <-
           local_datetime(
             local_now.time_zone,
             DateTime.to_date(local_now),
             candidate_hour,
             minute(task)
           ) do
      if DateTime.compare(candidate, local_now) == :gt do
        {:ok, shift_to_utc!(candidate)}
      else
        candidate
        |> add_local_interval(local_now.time_zone, :hourly, interval(task))
      end
    end
  end

  defp daily_initial(task, local_now) do
    with {:ok, candidate} <-
           local_datetime(
             local_now.time_zone,
             DateTime.to_date(local_now),
             hour(task),
             minute(task)
           ) do
      if DateTime.compare(candidate, local_now) == :gt do
        {:ok, shift_to_utc!(candidate)}
      else
        candidate
        |> add_local_interval(local_now.time_zone, :daily, interval(task))
      end
    end
  end

  defp weekly_initial(task, local_now) do
    current_date = DateTime.to_date(local_now)
    current_weekday = Date.day_of_week(current_date)
    day_offset = weekday(task) - current_weekday
    candidate_date = Date.add(current_date, day_offset)

    with {:ok, candidate} <-
           local_datetime(local_now.time_zone, candidate_date, hour(task), minute(task)) do
      if DateTime.compare(candidate, local_now) == :gt do
        {:ok, shift_to_utc!(candidate)}
      else
        candidate
        |> add_local_interval(local_now.time_zone, :weekly, interval(task))
      end
    end
  end

  defp add_local_interval(local_dt, timezone, :hourly, step) do
    local_dt
    |> DateTime.to_naive()
    |> NaiveDateTime.add(step * 3600, :second)
    |> resolve_local_datetime(timezone)
    |> case do
      {:ok, shifted} -> {:ok, shift_to_utc!(shifted)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_local_interval(local_dt, timezone, :daily, step) do
    local_dt
    |> DateTime.to_naive()
    |> NaiveDateTime.add(step * 86_400, :second)
    |> resolve_local_datetime(timezone)
    |> case do
      {:ok, shifted} -> {:ok, shift_to_utc!(shifted)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_local_interval(local_dt, timezone, :weekly, step) do
    local_dt
    |> DateTime.to_naive()
    |> NaiveDateTime.add(step * 7 * 86_400, :second)
    |> resolve_local_datetime(timezone)
    |> case do
      {:ok, shifted} -> {:ok, shift_to_utc!(shifted)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_datetime(timezone, date, hour, minute) do
    with {:ok, time} <- Time.new(hour, minute, 0),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      resolve_local_datetime(naive, timezone)
    end
  end

  defp resolve_local_datetime(naive, timezone) do
    case DateTime.from_naive(naive, timezone) do
      {:ok, dt} -> {:ok, dt}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, after_dt} -> {:ok, after_dt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp shift_zone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> {:ok, shifted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp shift_to_utc!(datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")

  defp schedule_type(%ScheduledTask{schedule_type: value}), do: value
  defp schedule_type(task), do: Map.get(task, :schedule_type, Map.get(task, "schedule_type"))

  defp timezone(%ScheduledTask{timezone: value}), do: value || "Etc/UTC"
  defp timezone(task), do: Map.get(task, :timezone, Map.get(task, "timezone", "Etc/UTC"))

  defp interval(%ScheduledTask{schedule_interval: value}), do: max(value || 1, 1)

  defp interval(task) do
    task
    |> Map.get(:schedule_interval, Map.get(task, "schedule_interval", 1))
    |> max(1)
  end

  defp hour(%ScheduledTask{schedule_hour: value}), do: value || 0
  defp hour(task), do: Map.get(task, :schedule_hour, Map.get(task, "schedule_hour", 0)) || 0

  defp minute(%ScheduledTask{schedule_minute: value}), do: value || 0

  defp minute(task) do
    Map.get(task, :schedule_minute, Map.get(task, "schedule_minute", 0)) || 0
  end

  defp weekday(%ScheduledTask{schedule_weekday: value}), do: value || 1

  defp weekday(task) do
    Map.get(task, :schedule_weekday, Map.get(task, "schedule_weekday", 1)) || 1
  end
end
