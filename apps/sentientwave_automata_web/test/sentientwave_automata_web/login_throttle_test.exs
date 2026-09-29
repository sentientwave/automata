defmodule SentientwaveAutomataWeb.LoginThrottleTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias SentientwaveAutomataWeb.LoginThrottle

  test "locks out only after max failed attempts, per IP" do
    max = LoginThrottle.max_attempts()

    for _ <- 1..(max - 1) do
      refute LoginThrottle.record("1.2.3.4", false)
    end

    assert LoginThrottle.record("1.2.3.4", false)
    # A different IP is unaffected.
    refute LoginThrottle.record("5.6.7.8", false)
  end

  test "a successful login clears the caller's counter" do
    for _ <- 1..(LoginThrottle.max_attempts() - 1) do
      refute LoginThrottle.record("9.9.9.9", false)
    end

    refute LoginThrottle.record("9.9.9.9", true)

    for _ <- 1..(LoginThrottle.max_attempts() - 1) do
      refute LoginThrottle.record("9.9.9.9", false)
    end
  end
end
