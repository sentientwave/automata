defmodule SentientwaveAutomataWeb.API.OnboardingController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Matrix.Onboarding

  def validate(conn, params) do
    case Onboarding.validate_payload(params) do
      {:ok, config} ->
        conn
        |> put_status(:ok)
        |> json(%{data: config})

      {:error, errors} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end
end
