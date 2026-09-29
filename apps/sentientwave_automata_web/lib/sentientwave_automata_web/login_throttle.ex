defmodule SentientwaveAutomataWeb.LoginThrottle do
  @moduledoc """
  In-memory brute-force throttle for the admin login form.

  Counts failed attempts per client IP inside a rolling window and reports
  whether the caller is locked out once the threshold is reached. A successful
  login clears the caller's counter. The console is LAN/Tailscale-facing and
  the admin password is long and random, so this is defense-in-depth rather
  than the primary control.
  """

  use GenServer

  @window_ms 15 * 60 * 1000

  @spec max_attempts() :: pos_integer()
  def max_attempts do
    System.get_env("AUTOMATA_LOGIN_MAX_ATTEMPTS", "10")
    |> String.to_integer()
  rescue
    _ -> 10
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @doc """
  Records an attempt for `ip` and returns true when the caller is now locked
  out (at least `max_attempts()` failures inside the window).
  """
  def record(ip, success?) when is_binary(ip) do
    GenServer.call(__MODULE__, {:record, ip, success?})
  end

  @impl true
  def handle_call({:record, ip, success?}, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = purge(state, now)

    {state, locked?} =
      if success? do
        {Map.delete(state, ip), false}
      else
        case Map.get(state, ip) do
          nil ->
            {Map.put(state, ip, {1, now}), false}

          {_count, window_start} when now - window_start > @window_ms ->
            {Map.put(state, ip, {1, now}), false}

          {count, window_start} ->
            count = count + 1
            {Map.put(state, ip, {count, window_start}), count >= max_attempts()}
        end
      end

    {:reply, locked?, state}
  end

  defp purge(state, now) do
    state
    |> Enum.reject(fn {_ip, {_count, start}} -> now - start > @window_ms end)
    |> Map.new()
  end
end
