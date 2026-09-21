defmodule PhoenixKitStaff.ActivityLogRescueTest do
  @moduledoc """
  `PhoenixKitStaff.Activity.log/2` never crashes the caller: it delegates
  to core's `PhoenixKit.Activity.log/3`, which returns a database error as
  `{:error, _}` with one log line instead of raising it into the
  LiveView. (Core's own suite covers an exit and a throw.)

  Runs `async: false` because it DROPs `phoenix_kit_activities` inside
  the sandboxed transaction; sandbox rolls the DROP back at test exit
  but parallel async tests against the same table would deadlock.
  """

  use PhoenixKitStaff.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitStaff.Activity
  alias PhoenixKitStaff.Test.Repo, as: TestRepo

  test "a Postgrex.Error from a missing table is returned, not raised" do
    # Drop inside the sandbox transaction; rolls back on test exit.
    TestRepo.query!("DROP TABLE phoenix_kit_activities CASCADE")

    log =
      capture_log([level: :warning], fn ->
        assert {:error, %Postgrex.Error{}} =
                 Activity.log("staff.test_action",
                   actor_uuid: Ecto.UUID.generate(),
                   resource_type: "staff_person",
                   resource_uuid: Ecto.UUID.generate(),
                   metadata: %{}
                 )
      end)

    assert log =~ "Activity logging error"
  end

  test "Activity.log/2 with a valid table writes a row under the staff module key" do
    actor_uuid = Ecto.UUID.generate()
    resource_uuid = Ecto.UUID.generate()

    assert {:ok, %PhoenixKit.Activity.Entry{module: "staff"}} =
             Activity.log("staff.test_happy_path",
               actor_uuid: actor_uuid,
               resource_type: "staff_person",
               resource_uuid: resource_uuid,
               metadata: %{"k" => "v"}
             )

    assert_activity_logged("staff.test_happy_path",
      actor_uuid: actor_uuid,
      resource_uuid: resource_uuid,
      metadata_has: %{"k" => "v"}
    )
  end
end
