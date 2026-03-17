defmodule SentientwaveAutomata.Policy.Entitlements do
  @moduledoc """
  Runtime entitlement checks backed by edition defaults.

  This module is intentionally pure so it can be reused in API and worker paths.
  """

  alias SentientwaveAutomata.Edition

  @spec allowed?(atom(), map()) :: boolean()
  def allowed?(feature, context \\ %{}) do
    edition = Map.get(context, :edition, Edition.current())
    Edition.has_feature?(feature, edition)
  end
end
