defmodule SentientwaveAutomata.Security.Passwords do
  @moduledoc false

  @charset ~c"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*()-_=+"

  @spec generate(pos_integer()) :: String.t()
  def generate(length \\ 20) when is_integer(length) and length > 0 do
    bytes = :crypto.strong_rand_bytes(length)
    charset_size = length(@charset)

    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn b ->
      idx = rem(b, charset_size)
      Enum.at(@charset, idx)
    end)
    |> to_string()
  end
end
