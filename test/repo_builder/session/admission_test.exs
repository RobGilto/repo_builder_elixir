defmodule RepoBuilder.Session.AdmissionTest do
  # async: false — uses a fixed registered name for the isolated instance.
  use ExUnit.Case, async: false

  alias RepoBuilder.Session.Admission

  setup do
    start_supervised!({Admission, max: 2, name: :admission_test})
    %{server: :admission_test}
  end

  test "acquires up to max, then reports :at_capacity", %{server: server} do
    assert :ok = Admission.acquire(server)
    assert :ok = Admission.acquire(server)
    assert {:error, :at_capacity} = Admission.acquire(server)
    assert %{used: 2, max: 2} = Admission.count(server)
  end

  test "release frees a slot and is idempotent (clamps at zero)", %{server: server} do
    assert :ok = Admission.acquire(server)
    :ok = Admission.release(server)
    assert %{used: 0, max: 2} = Admission.count(server)

    # Extra releases never drive used below zero.
    :ok = Admission.release(server)
    :ok = Admission.release(server)
    assert %{used: 0} = Admission.count(server)

    # A freed slot is reusable.
    assert :ok = Admission.acquire(server)
  end
end
