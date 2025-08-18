defmodule Sifter.Utils do
  @moduledoc """
  Utilities shared by the Sifter lexer/parser.

  Snakecase rules per **segment** (segments are dot-separated):
  * Insert `_` only at `lower|digit → UPPER` boundaries (e.g. `firstName` → `first_name`, `id2X` → `id2_x`)
  * **No acronym splitting** (e.g. `APIKey` → `apikey`, *not* `api_key`)
  * Map `-` and space to `_`, collapse consecutive `_`, lowercase everything
  * Apply independently to each dot-separated segment (dots preserved)
  """

  @compile {:inline,
            [
              to_snake_case: 1,
              segment_snake: 1,
              do_seg: 4,
              uppercase?: 1,
              lowercase?: 1,
              digit?: 1,
              to_lower: 1
            ]}

  @spec to_snake_case(binary) :: binary
  def to_snake_case(str) when is_binary(str) do
    parts =
      :binary.split(str, ".", [:global])
      |> Enum.map(&segment_snake/1)

    :erlang.iolist_to_binary(:lists.join(".", parts))
  end

  @spec segment_snake(binary) :: binary
  def segment_snake(<<>>), do: <<>>

  def segment_snake("NOT"), do: "not"
  def segment_snake("OR"), do: "or"
  def segment_snake("AND"), do: "and"

  def segment_snake(<<"NOT", rest::binary>>) do
    :erlang.iolist_to_binary(["not", do_seg(rest, [], :upper, false)])
  end

  def segment_snake(<<"OR", rest::binary>>) do
    :erlang.iolist_to_binary(["or", do_seg(rest, [], :upper, false)])
  end

  def segment_snake(<<"AND", rest::binary>>) do
    :erlang.iolist_to_binary(["and", do_seg(rest, [], :upper, false)])
  end

  def segment_snake(seg) when is_binary(seg) do
    do_seg(seg, [], :start, false) |> :erlang.iolist_to_binary()
  end

  defp do_seg(<<>>, acc, _prev, _us?), do: :lists.reverse(acc)

  defp do_seg(<<c, rest::binary>>, acc, prev, us?) do
    cond do
      c == ?_ or c == ?- or c == ?\s ->
        acc = if us? or prev == :start, do: acc, else: [?_ | acc]
        do_seg(rest, acc, :underscore, true)

      lowercase?(c) ->
        do_seg(rest, [c | acc], :lower, false)

      uppercase?(c) ->
        need_us? = prev in [:lower, :digit]
        acc = if need_us? and not us? and prev != :start, do: [?_ | acc], else: acc
        do_seg(rest, [to_lower(c) | acc], :upper, false)

      digit?(c) ->
        do_seg(rest, [c | acc], :digit, false)

      true ->
        lc = if uppercase?(c), do: to_lower(c), else: c
        do_seg(rest, [lc | acc], :other, false)
    end
  end

  defp uppercase?(c) when c >= ?A and c <= ?Z, do: true
  defp uppercase?(_), do: false

  defp lowercase?(c) when c >= ?a and c <= ?z, do: true
  defp lowercase?(_), do: false

  defp digit?(c) when c >= ?0 and c <= ?9, do: true
  defp digit?(_), do: false

  defp to_lower(c) when c >= ?A and c <= ?Z, do: c + 32
  defp to_lower(c), do: c
end
