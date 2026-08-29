import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Application;
import Toybox.Attention;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//! Owns the whole surf-session state machine. Every ActivityRecording call lives here.
//!
//! Storage model: a wave is a FIT lap, and the FIT file carries the lap timestamps, the GPS
//! track and HR to Garmin Connect on its own. The wave times are *also* kept as a small
//! pending-sessions list so they can be pushed straight to the Tidal Labs iPhone app —
//! see sync().
class SessionController {

    //! Application.Storage key holding the list of finished sessions not yet synced.
    private const PENDING_KEY = "pendingSessions";

    private var _session as ActivityRecording.Session?;
    private var _waveTimes as Array<Number> = [] as Array<Number>;
    private var _startTime as Number = 0;
    private var _syncing as Boolean = false;
    private var _syncStatus as String? = null;

    public function initialize() {
    }

    public function isRecording() as Boolean {
        var session = _session;
        return (session != null) && session.isRecording();
    }

    public function getWaveCount() as Number {
        return _waveTimes.size();
    }

    //! Elapsed session time in seconds, straight off the recording timer.
    public function getElapsedSeconds() as Number {
        var timerTime = Activity.getActivityInfo().timerTime;
        if (timerTime == null) {
            return 0;
        }
        return timerTime / 1000;
    }

    public function start() as Void {
        if (isRecording()) {
            return;
        }
        var session = ActivityRecording.createSession({
            :sport => Activity.SPORT_SURFING,
            :name => "Tidal Labs"
        });
        session.start();
        _session = session;
        _waveTimes = [] as Array<Number>;
        _startTime = Time.now().value();
        _syncStatus = null;
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        setTouchEnabled(false);
        buzz(60);
        WatchUi.requestUpdate();
    }

    public function logWave() as Void {
        var session = _session;
        if ((session == null) || !session.isRecording()) {
            return;
        }
        session.addLap();
        _waveTimes.add(Time.now().value());
        buzz(60);
        WatchUi.requestUpdate();
    }

    //! Stop, save and release. Safe to call when idle — that is what makes it usable
    //! straight from AppBase.onStop(), so a system-level kill saves instead of losing.
    public function end() as Void {
        var session = _session;
        if (session == null) {
            return;
        }
        if (session.isRecording()) {
            session.stop();
        }
        session.save();
        _session = null;
        queueForSync();
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        setTouchEnabled(true);
        buzz(600);
        WatchUi.requestUpdate();
    }

    //! Number of finished sessions waiting to be pushed to the phone.
    public function getPendingCount() as Number {
        return pending().size();
    }

    public function getSyncStatus() as String? {
        return _syncStatus;
    }

    //! Push every pending session to the Tidal Labs iPhone app.
    //! ponytail: fire-and-forget, all sessions in one transmit. Nothing here retries — the
    //! payload stays in Storage until the phone acknowledges, so the fix for a failure is to
    //! press the button again.
    public function sync() as Void {
        if (_syncing || (getPendingCount() == 0)) {
            return;
        }
        _syncing = true;
        _syncStatus = "Syncing...";
        WatchUi.requestUpdate();
        Communications.transmit({"sessions" => pending()}, null, new $.SyncListener(self));
    }

    public function onSyncComplete() as Void {
        Application.Storage.deleteValue(PENDING_KEY);
        _syncing = false;
        _syncStatus = "Synced!";
        buzz(60);
        WatchUi.requestUpdate();
    }

    public function onSyncError() as Void {
        _syncing = false;
        _syncStatus = "Phone not connected";
        WatchUi.requestUpdate();
    }

    //! GPS is enabled purely so the FIT file gets a track. Nothing to do per fix — the
    //! session recording consumes the positions itself.
    public function onPosition(info as Position.Info) as Void {
    }

    private function pending() as Array {
        var stored = Application.Storage.getValue(PENDING_KEY);
        if (stored == null) {
            return [] as Array;
        }
        return stored as Array;
    }

    //! A session with no waves is not worth sending — the FIT file already has the track.
    private function queueForSync() as Void {
        if (_waveTimes.size() == 0) {
            return;
        }
        var sessions = pending();
        sessions.add({
            "start" => _startTime,
            "end" => Time.now().value(),
            "waves" => _waveTimes
        });
        Application.Storage.setValue(PENDING_KEY, sessions);
        _waveTimes = [] as Array<Number>;
    }

    //! The Water Lock equivalent: stop delivering touch events to the app so a wet screen
    //! cannot fire a phantom swipe-right and quit mid-session.
    //! ponytail: no device-level "Lock Device" — there is no API for it, so the physical
    //! buttons stay live by design (that is how you log a wave).
    private function setTouchEnabled(enabled as Boolean) as Void {
        if (!(WatchUi has :configureTouchEvents)) {
            return;
        }
        try {
            WatchUi.configureTouchEvents({:enabled => enabled});
        } catch (ex) {
            // Throws unless we are a foreground watch app. Buttons still work; carry on.
        }
    }

    private function buzz(durationMs as Number) as Void {
        if ((Attention has :vibrate) && System.getDeviceSettings().vibrateOn) {
            Attention.vibrate([new Attention.VibeProfile(75, durationMs)]);
        }
    }
}

class SyncListener extends Communications.ConnectionListener {

    private var _controller as SessionController;

    public function initialize(controller as SessionController) {
        ConnectionListener.initialize();
        _controller = controller;
    }

    public function onComplete() as Void {
        _controller.onSyncComplete();
    }

    public function onError() as Void {
        _controller.onSyncError();
    }
}
