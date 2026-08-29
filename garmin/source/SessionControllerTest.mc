import Toybox.Application;
import Toybox.Lang;
import Toybox.Test;

//! The one runnable check on the session state machine: idle -> recording -> laps -> idle,
//! and the queue the sync button drains.
//! Build and run it with:
//!   monkeyc -f monkey.jungle -o bin/test.prg -y developer_key.der -d fenix847mm -t
//!   monkeydo bin/test.prg fenix847mm -t
(:test)
function sessionStateMachine(logger as Test.Logger) as Boolean {
    Application.Storage.clearValues();
    var controller = new $.SessionController();

    Test.assertEqualMessage(controller.isRecording(), false, "should start idle");
    Test.assertEqualMessage(controller.getWaveCount(), 0, "idle wave count should be 0");
    Test.assertEqualMessage(controller.getPendingCount(), 0, "nothing to sync yet");

    // A wave logged while idle must not be counted — DOWN only fires during a session.
    controller.logWave();
    Test.assertEqualMessage(controller.getWaveCount(), 0, "idle logWave must be a no-op");

    controller.start();
    Test.assertEqualMessage(controller.isRecording(), true, "start() should be recording");

    controller.logWave();
    controller.logWave();
    controller.logWave();
    Test.assertEqualMessage(controller.getWaveCount(), 3, "three DOWN presses = three laps");

    // A second start() while already recording must not reset the count.
    controller.start();
    Test.assertEqualMessage(controller.getWaveCount(), 3, "re-start must not clear waves");

    controller.end();
    Test.assertEqualMessage(controller.isRecording(), false, "end() should return to idle");
    Test.assertEqualMessage(controller.getPendingCount(), 1, "finished session queued for sync");

    // end() is called unconditionally from AppBase.onStop(), so it has to be safe when idle.
    controller.end();
    Test.assertEqualMessage(controller.isRecording(), false, "end() when idle is a no-op");
    Test.assertEqualMessage(controller.getPendingCount(), 1, "idle end() must not queue again");

    // A second session queues alongside the first instead of clobbering it.
    controller.start();
    controller.logWave();
    controller.end();
    Test.assertEqualMessage(controller.getPendingCount(), 2, "sessions accumulate until synced");

    // A session with no waves has nothing to send — the FIT file already holds the track.
    controller.start();
    controller.end();
    Test.assertEqualMessage(controller.getPendingCount(), 2, "empty session is not queued");

    Application.Storage.clearValues();
    return true;
}
