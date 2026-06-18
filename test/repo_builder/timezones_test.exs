defmodule RepoBuilder.TimezonesTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Timezones

  describe "list/0 and default/0" do
    test "lists curated zones with UTC first" do
      list = Timezones.list()
      assert hd(list) == "UTC"
      assert "Australia/Sydney" in list
      assert "America/New_York" in list
    end

    test "default is UTC" do
      assert Timezones.default() == "UTC"
    end
  end

  describe "valid?/1" do
    test "true for a curated zone" do
      assert Timezones.valid?("Australia/Sydney")
      assert Timezones.valid?("UTC")
    end

    test "false for an unknown or non-binary zone" do
      refute Timezones.valid?("Mars/Olympus")
      refute Timezones.valid?(nil)
      refute Timezones.valid?(:utc)
    end
  end

  describe "to_local/2" do
    test "shifts a UTC instant into a positive-offset southern zone (no DST in June)" do
      # 2026-06-18 00:00:00Z -> Sydney is UTC+10 in June (no DST) -> 10:00 same day.
      utc = ~U[2026-06-18 00:00:00Z]
      local = Timezones.to_local(utc, "Australia/Sydney")
      assert local.hour == 10
      assert local.day == 18
    end

    test "shifts a UTC instant into a negative-offset zone (DST in June)" do
      # 2026-06-18 00:00:00Z -> New York is UTC-4 in June (EDT) -> 20:00 previous day.
      utc = ~U[2026-06-18 00:00:00Z]
      local = Timezones.to_local(utc, "America/New_York")
      assert local.hour == 20
      assert local.day == 17
    end

    test "DST vs non-DST for the same zone yields different offsets" do
      summer = Timezones.to_local(~U[2026-07-01 12:00:00Z], "America/New_York")
      winter = Timezones.to_local(~U[2026-01-01 12:00:00Z], "America/New_York")
      # EDT (UTC-4) in July => 08:00; EST (UTC-5) in January => 07:00.
      assert summer.hour == 8
      assert winter.hour == 7
    end

    test "returns the original datetime (no raise) for an invalid zone" do
      utc = ~U[2026-06-18 00:00:00Z]
      assert Timezones.to_local(utc, "Mars/Olympus") == utc
    end

    test "UTC preserves the instant and wall clock" do
      utc = ~U[2026-06-18 00:30:00Z]
      local = Timezones.to_local(utc, "UTC")
      assert DateTime.compare(local, utc) == :eq
      assert {local.hour, local.minute} == {0, 30}
    end
  end

  describe "format_datetime/2 and format_time/2" do
    test "format_datetime renders YYYY-MM-DD HH:MM:SS in the local zone" do
      assert Timezones.format_datetime(~U[2026-06-18 00:30:00Z], "Australia/Sydney") ==
               "2026-06-18 10:30:00"

      assert Timezones.format_datetime(~U[2026-06-18 00:30:00Z], "UTC") ==
               "2026-06-18 00:30:00"
    end

    test "format_time renders HH:MM:SS in the local zone" do
      assert Timezones.format_time(~U[2026-06-18 00:30:00Z], "Australia/Sydney") == "10:30:00"
      assert Timezones.format_time(~U[2026-06-18 00:30:00Z], "UTC") == "00:30:00"
    end
  end
end
