defmodule RepoBuilder.Timezones do
  @moduledoc """
  Display-zone helper: the single seam for converting the canonical UTC `DateTime`
  timestamps into the operator's chosen local timezone and formatting them for the
  console (issue-a timezone). No `Repo`/`Ecto` access — this is a pure display
  concern. LiveView/components call only this module; there is no ad-hoc
  `Calendar.strftime`/`DateTime` math elsewhere.

  Zone conversion relies on Elixir's configured `:time_zone_database` (the `tz`
  package, wired in `config/config.exs`). The render path never raises on a bad or
  unknown zone — `to_local/2` falls back to the original UTC datetime.
  """

  # Curated list of common operator zones (UTC first). The full IANA set is ~600
  # zones — unusable in a dropdown — so this is intentionally a short list; extending
  # it is a one-line edit (see the plan's Notes).
  @timezones [
    "UTC",
    "America/Los_Angeles",
    "America/Denver",
    "America/Chicago",
    "America/New_York",
    "America/Sao_Paulo",
    "Europe/London",
    "Europe/Berlin",
    "Asia/Kolkata",
    "Asia/Singapore",
    "Asia/Tokyo",
    "Australia/Sydney",
    "Pacific/Auckland"
  ]

  @default "UTC"

  @doc "The curated IANA zone names offered in the settings dropdown (UTC first)."
  @spec list() :: [String.t(), ...]
  def list, do: @timezones

  @doc "The default timezone when none is set (`\"UTC\"`)."
  @spec default() :: String.t()
  def default, do: @default

  @doc "Whether `zone` is one of the curated, selectable zones."
  @spec valid?(term()) :: boolean()
  def valid?(zone) when is_binary(zone), do: zone in @timezones
  def valid?(_zone), do: false

  @doc """
  Shift a UTC `DateTime` into `zone`. On any conversion error (unknown zone, missing
  tz data) returns the original datetime unchanged — the render path must never raise.
  """
  @spec to_local(DateTime.t(), String.t()) :: DateTime.t()
  def to_local(%DateTime{} = datetime, zone) when is_binary(zone) do
    case DateTime.shift_zone(datetime, zone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  @doc "Format a UTC `DateTime` as `YYYY-MM-DD HH:MM:SS` in `zone`."
  @spec format_datetime(DateTime.t(), String.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime, zone) when is_binary(zone) do
    datetime
    |> to_local(zone)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  @doc "Format a UTC `DateTime` as a compact `HH:MM:SS` in `zone`."
  @spec format_time(DateTime.t(), String.t()) :: String.t()
  def format_time(%DateTime{} = datetime, zone) when is_binary(zone) do
    datetime
    |> to_local(zone)
    |> Calendar.strftime("%H:%M:%S")
  end

  @doc """
  Resolve the UTC start instants for the **today**, **this week**, and **this month**
  accounting windows, computed in `zone` relative to `now` (issue-cost-adw-periods).

  Boundaries are taken at local midnight: today = local midnight of `now`'s date; week =
  local midnight of the most recent Monday (ISO-8601 week, Monday start); month = local
  midnight of the 1st. Each local midnight is converted back to UTC for the `inserted_at`
  filter (rows store UTC). DST edge cases at midnight are handled without raising — a
  spring-forward gap snaps forward to the next valid instant, a fall-back ambiguity takes
  the first occurrence, and an unknown zone falls back to a UTC boundary.
  """
  @spec period_starts(DateTime.t(), String.t()) :: %{
          today: DateTime.t(),
          week: DateTime.t(),
          month: DateTime.t()
        }
  def period_starts(%DateTime{} = now, zone) when is_binary(zone) do
    date = now |> to_local(zone) |> DateTime.to_date()

    %{
      today: local_midnight_to_utc(date, zone),
      week: local_midnight_to_utc(Date.beginning_of_week(date, :monday), zone),
      month: local_midnight_to_utc(Date.beginning_of_month(date), zone)
    }
  end

  # Convert local midnight on `date` in `zone` to the corresponding UTC instant.
  @spec local_midnight_to_utc(Date.t(), String.t()) :: DateTime.t()
  defp local_midnight_to_utc(date, zone) do
    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, datetime} -> shift_to_utc(datetime, date)
      {:gap, _just_before, just_after} -> shift_to_utc(just_after, date)
      {:ambiguous, first, _second} -> shift_to_utc(first, date)
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  @spec shift_to_utc(DateTime.t(), Date.t()) :: DateTime.t()
  defp shift_to_utc(datetime, date) do
    case DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, utc} -> utc
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end
end
