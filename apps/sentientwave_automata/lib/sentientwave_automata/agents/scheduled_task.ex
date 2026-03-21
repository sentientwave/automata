defmodule SentientwaveAutomata.Agents.ScheduledTask do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @task_types [:run_agent_prompt, :post_room_message]
  @schedule_types [:hourly, :daily, :weekly]

  @type task_type :: :run_agent_prompt | :post_room_message
  @type schedule_type :: :hourly | :daily | :weekly

  @type t :: %__MODULE__{
          id: binary() | nil,
          agent_id: binary() | nil,
          agent: struct() | Ecto.Association.NotLoaded.t(),
          name: String.t() | nil,
          enabled: boolean(),
          task_type: task_type() | nil,
          schedule_type: schedule_type() | nil,
          schedule_interval: integer(),
          schedule_hour: integer() | nil,
          schedule_minute: integer(),
          schedule_weekday: integer() | nil,
          timezone: String.t() | nil,
          room_id: String.t() | nil,
          prompt_body: String.t() | nil,
          message_body: String.t() | nil,
          next_run_at: DateTime.t() | nil,
          last_run_at: DateTime.t() | nil,
          last_outcome: map(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agent_scheduled_tasks" do
    field :name, :string
    field :enabled, :boolean, default: true
    field :task_type, Ecto.Enum, values: @task_types
    field :schedule_type, Ecto.Enum, values: @schedule_types
    field :schedule_interval, :integer, default: 1
    field :schedule_hour, :integer
    field :schedule_minute, :integer, default: 0
    field :schedule_weekday, :integer
    field :timezone, :string, default: "Etc/UTC"
    field :room_id, :string
    field :prompt_body, :string
    field :message_body, :string
    field :next_run_at, :utc_datetime_usec
    field :last_run_at, :utc_datetime_usec
    field :last_outcome, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :agent, SentientwaveAutomata.Agents.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def task_types, do: @task_types
  def schedule_types, do: @schedule_types

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :agent_id,
      :name,
      :enabled,
      :task_type,
      :schedule_type,
      :schedule_interval,
      :schedule_hour,
      :schedule_minute,
      :schedule_weekday,
      :timezone,
      :room_id,
      :prompt_body,
      :message_body,
      :next_run_at,
      :last_run_at,
      :last_outcome,
      :metadata
    ])
    |> update_change(:name, &normalize_string/1)
    |> update_change(:timezone, &normalize_timezone/1)
    |> update_change(:room_id, &normalize_string/1)
    |> update_change(:prompt_body, &normalize_text/1)
    |> update_change(:message_body, &normalize_text/1)
    |> validate_required([
      :agent_id,
      :name,
      :task_type,
      :schedule_type,
      :schedule_interval,
      :schedule_minute,
      :timezone
    ])
    |> assoc_constraint(:agent)
    |> validate_number(:schedule_interval, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    |> validate_number(:schedule_minute, greater_than_or_equal_to: 0, less_than_or_equal_to: 59)
    |> validate_hour()
    |> validate_weekday()
    |> validate_timezone()
    |> validate_payload()
  end

  defp validate_hour(changeset) do
    case get_field(changeset, :schedule_type) do
      schedule_type when schedule_type in [:daily, :weekly] ->
        changeset
        |> validate_required([:schedule_hour])
        |> validate_number(:schedule_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)

      _ ->
        changeset
    end
  end

  defp validate_weekday(changeset) do
    case get_field(changeset, :schedule_type) do
      :weekly ->
        changeset
        |> validate_required([:schedule_weekday])
        |> validate_number(:schedule_weekday,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: 7
        )

      _ ->
        changeset
    end
  end

  defp validate_payload(changeset) do
    case get_field(changeset, :task_type) do
      :run_agent_prompt ->
        changeset
        |> validate_required([:prompt_body])
        |> validate_length(:prompt_body, min: 2)

      :post_room_message ->
        changeset
        |> validate_required([:room_id, :message_body])
        |> validate_length(:message_body, min: 1)

      _ ->
        changeset
    end
  end

  defp validate_timezone(changeset) do
    case get_field(changeset, :timezone) do
      value when is_binary(value) and value != "" ->
        case DateTime.now(value) do
          {:ok, _datetime} -> changeset
          {:error, _reason} -> add_error(changeset, :timezone, "is invalid")
        end

      _ ->
        add_error(changeset, :timezone, "is invalid")
    end
  end

  defp normalize_string(value), do: value |> to_string() |> String.trim()
  defp normalize_timezone(value), do: value |> to_string() |> String.trim() |> default_timezone()
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp default_timezone(""), do: "Etc/UTC"
  defp default_timezone(value), do: value
end
