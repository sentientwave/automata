defmodule SentientwaveAutomata.Licensing.SeatManager do
  @moduledoc """
  Minimal in-memory seat allocator for on-prem and cloud licensing experiments.
  """

  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{limit: 25, users: MapSet.new()} end, name: __MODULE__)

  @spec limit() :: non_neg_integer()
  def limit, do: Agent.get(__MODULE__, & &1.limit)

  @spec allocate(String.t()) :: :ok | {:error, :seat_limit_reached}
  def allocate(user_id) do
    Agent.get_and_update(__MODULE__, fn %{limit: limit, users: users} = state ->
      cond do
        MapSet.member?(users, user_id) ->
          {:ok, state}

        MapSet.size(users) < limit ->
          {:ok, %{state | users: MapSet.put(users, user_id)}}

        true ->
          {{:error, :seat_limit_reached}, state}
      end
    end)
  end

  @spec assigned() :: [String.t()]
  def assigned, do: Agent.get(__MODULE__, &MapSet.to_list(&1.users))
end
