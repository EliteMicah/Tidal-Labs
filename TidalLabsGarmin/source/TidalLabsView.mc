import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Application;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

const COLOR_ACCENT  = 0x2F62F4;
const COLOR_CYAN    = 0x16A6CE;
const COLOR_DANGER  = 0xE5484D;
const COLOR_MUTED   = 0x9FB6CE;
const COLOR_GREEN   = 0x30D158;

class TidalLabsView extends WatchUi.View {

    // Session state
    var sessionActive   as Boolean        = false;
    var sessionId       as String         = "";
    var sessionStart    as Time.Moment?   = null;
    var waveCount       as Number         = 0;
    var waveDurSecs     as Number         = 60;

    private var _timestamps as Lang.Array = [] as Lang.Array;

    // UI feedback
    private var _flashMsg       as String  = "";
    private var _flashActive    as Boolean = false;
    private var _flashTimer     as Timer.Timer?;

    // Heart rate
    var heartRate as Number = 0;
    private var _hrTimer as Timer.Timer?;

    // Workout session
    private var _workout as ActivityRecording.Session?;

    function initialize() {
        View.initialize();
        _loadSettings();
        _startHrPolling();
    }

    function onLayout(dc as Graphics.Dc) as Void {
    }

    function onShow() as Void {
    }

    function onHide() as Void {
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        var r  = cx < cy ? cx : cy;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (sessionActive) {
            _drawActive(dc, cx, cy, r);
        } else {
            _drawIdle(dc, cx, cy, r);
        }
    }

    // ── Idle screen ──────────────────────────────────────────────────────────

    private function _drawIdle(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        // "Tidal Labs" title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 38, Graphics.FONT_MEDIUM, "Tidal Labs",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // "Start Session" white pill button
        var btnW = (r * 1.1).toNumber();
        var btnH = 38;
        var btnX = cx - btnW / 2;
        var btnY = cy + 10;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(btnX, btnY, btnW, btnH, 19);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, btnY + btnH / 2, Graphics.FONT_SMALL, "Start Session",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Pending sessions badge
        var pendingCount = _getPendingSessions().size();
        if (pendingCount > 0) {
            dc.setColor(COLOR_CYAN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, btnY + btnH + 14, Graphics.FONT_TINY,
                pendingCount + " unsynced", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // ── Active screen ─────────────────────────────────────────────────────────

    private function _drawActive(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        // HR — top-left
        if (heartRate > 0) {
            dc.setColor(COLOR_DANGER, Graphics.COLOR_TRANSPARENT);
            dc.drawText((cx - r * 0.66).toNumber(), (cy - r * 0.58).toNumber(), Graphics.FONT_TINY,
                heartRate.toString() + " bpm",
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // Time — top-right
        var ct  = System.getClockTime();
        var mn  = ct.min;
        var mnStr = mn < 10 ? "0" + mn.toString() : mn.toString();
        var timeStr = ct.hour.toString() + ":" + mnStr;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText((cx + r * 0.66).toNumber(), (cy - r * 0.58).toNumber(), Graphics.FONT_TINY,
            timeStr,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Status center — "Ready" or wave count + "waves logged"
        var statusY = cy - 24;
        if (_flashActive) {
            dc.setColor(COLOR_CYAN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, statusY, Graphics.FONT_MEDIUM, _flashMsg,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else if (waveCount == 0) {
            dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, statusY, Graphics.FONT_MEDIUM, "Ready",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, statusY - 16, Graphics.FONT_NUMBER_MEDIUM, waveCount.toString(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, statusY + 22, Graphics.FONT_TINY, "waves logged",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // Green up arrow
        dc.setColor(COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 12, Graphics.FONT_SMALL, "^",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // "UP to Record" hint
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 30, Graphics.FONT_TINY, "UP to Record",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Divider
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        var divY    = cy + 50;
        var divHalf = (r * 0.42).toNumber();
        dc.drawLine(cx - divHalf, divY, cx + divHalf, divY);

        // "End Session" dark-red pill button
        var btnW = (r * 1.05).toNumber();
        var btnH = 32;
        var btnX = cx - btnW / 2;
        var btnY = divY + 8;
        dc.setColor(0x4A0000, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(btnX, btnY, btnW, btnH, 16);
        dc.setColor(COLOR_DANGER, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, btnY + btnH / 2, Graphics.FONT_TINY, "End Session",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Session control ───────────────────────────────────────────────────────

    function startSession() as Void {
        if (sessionActive) { return; }
        sessionActive  = true;
        sessionId      = _generateId();
        sessionStart   = Time.now();
        waveCount      = 0;
        _timestamps    = [] as Lang.Array;
        _startWorkout();
        _pulse(1);
        WatchUi.requestUpdate();
    }

    function endSession() as Void {
        if (!sessionActive) { return; }
        _finalizeSession();
        _stopWorkout();
        _pulse(3);
        WatchUi.requestUpdate();
    }

    function recordWave() as Void {
        if (!sessionActive) { return; }

        var now   = Time.now();
        var start = now.subtract(new Time.Duration(waveDurSecs));
        _timestamps.add({
            "id"    => _generateId(),
            "start" => start.value().toFloat(),
            "end"   => now.value().toFloat()
        });
        waveCount++;

        _showFlash("Wave " + waveCount + " logged");
        _pulse(2);
        WatchUi.requestUpdate();
    }

    // ── Flash feedback ────────────────────────────────────────────────────────

    private function _showFlash(msg as String) as Void {
        _flashMsg    = msg;
        _flashActive = true;
        if (_flashTimer != null) {
            (_flashTimer as Timer.Timer).stop();
        }
        _flashTimer = new Timer.Timer();
        (_flashTimer as Timer.Timer).start(method(:_clearFlash), 2000, false);
    }

    function _clearFlash() as Void {
        _flashActive = false;
        _flashMsg    = "";
        WatchUi.requestUpdate();
    }

    // ── Workout session ───────────────────────────────────────────────────────

    private function _startWorkout() as Void {
        try {
            var opts = {
                :name     => "Surfing",
                :sport    => ActivityRecording.SPORT_SURFING,
                :subSport => ActivityRecording.SUB_SPORT_GENERIC
            };
            _workout = ActivityRecording.createSession(opts);
            (_workout as ActivityRecording.Session).start();
        } catch (ex instanceof Lang.Exception) {}
    }

    private function _stopWorkout() as Void {
        if (_workout == null) { return; }
        var ws = _workout as ActivityRecording.Session;
        ws.stop();
        ws.save();
        _workout = null;
    }

    // ── Heart rate polling ────────────────────────────────────────────────────

    private function _startHrPolling() as Void {
        _hrTimer = new Timer.Timer();
        (_hrTimer as Timer.Timer).start(method(:_pollHr), 3000, true);
    }

    function _pollHr() as Void {
        try {
            var info = Activity.getActivityInfo();
            if (info != null && info.currentHeartRate != null) {
                heartRate = info.currentHeartRate;
                if (sessionActive) { WatchUi.requestUpdate(); }
            }
        } catch (ex instanceof Lang.Exception) {}
    }

    // ── Persistence ───────────────────────────────────────────────────────────

    private function _finalizeSession() as Void {
        if (sessionStart != null && _timestamps.size() > 0) {
            var session = {
                "id"         => sessionId,
                "startDate"  => (sessionStart as Time.Moment).value().toFloat(),
                "endDate"    => Time.now().value().toFloat(),
                "timestamps" => _timestamps
            };
            var existing = _getPendingSessions();
            existing.add(session);
            Application.Storage.setValue("pendingSessions", existing);
        }
        sessionActive = false;
        sessionId     = "";
        sessionStart  = null;
        waveCount     = 0;
        _timestamps   = [] as Lang.Array;
        _flashActive  = false;
    }

    function getPendingSessionCount() as Number {
        return _getPendingSessions().size();
    }

    function clearConfirmedSessions(ids as Lang.Array) as Void {
        var sessions = _getPendingSessions();
        var kept     = [] as Lang.Array;
        for (var i = 0; i < sessions.size(); i++) {
            var s  = sessions[i] as Lang.Dictionary;
            var id = s["id"] as String;
            if (ids.indexOf(id) < 0) {
                kept.add(s);
            }
        }
        Application.Storage.setValue("pendingSessions", kept);
    }

    private function _getPendingSessions() as Lang.Array {
        var stored = Application.Storage.getValue("pendingSessions");
        if (stored instanceof Lang.Array) {
            return stored as Lang.Array;
        }
        return [] as Lang.Array;
    }

    private function _loadSettings() as Void {
        var dur = Application.Storage.getValue("waveDurationSeconds");
        if (dur instanceof Number) {
            waveDurSecs = dur as Number;
        }
    }

    // ── Haptics ───────────────────────────────────────────────────────────────

    private function _pulse(count as Number) as Void {
        if (!(Attention has :vibrate)) { return; }
        var pattern = [] as Lang.Array;
        for (var i = 0; i < count; i++) {
            pattern.add(new Attention.VibeProfile(100, 200));
            if (i < count - 1) {
                pattern.add(new Attention.VibeProfile(0, 175));
            }
        }
        Attention.vibrate(pattern);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private function _generateId() as String {
        return Time.now().value().toString() + Math.rand().toString();
    }
}
