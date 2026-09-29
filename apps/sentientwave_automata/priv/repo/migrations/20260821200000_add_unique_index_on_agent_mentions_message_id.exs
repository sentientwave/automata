defmodule SentientwaveAutomata.Repo.Migrations.AddUniqueIndexOnAgentMentionsMessageId do
  use Ecto.Migration

  # Mention dedupe was previously enforced only by the composite index
  # (message_id, mentioned_agent_id), but nothing ever writes
  # mentioned_agent_id - so it is NULL everywhere and Postgres NULLs-distinct
  # allowed unlimited duplicate rows per message (=> duplicate runs / replies).
  def up do
    # Drop duplicates, keeping the earliest row per message_id.
    execute """
    DELETE FROM agent_mentions m
    USING agent_mentions k
    WHERE k.message_id = m.message_id
      AND (k.inserted_at, k.id) < (m.inserted_at, m.id)
    """

    create unique_index(:agent_mentions, [:message_id],
             name: :agent_mentions_message_id_unique_index
           )
  end

  def down do
    drop index(:agent_mentions, [:message_id], name: :agent_mentions_message_id_unique_index)
  end
end
