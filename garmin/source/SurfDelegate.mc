import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Physical buttons only.
//!
//! Extends InputDelegate, not BehaviorDelegate, on purpose: BehaviorDelegate.onSelect()
//! fires on a screen tap as well as an ENTER press, and a wet screen taps itself. onTap
//! and onSelect are deliberately not implemented here.
//!
//! Five-button watches (fenix, Instinct, Forerunner, ...):
//!   START  press          - begin a session
//!   START  hold 1000ms    - end and save it
//!   DOWN   press          - log a wave (recording only)
//!   UP     press          - push finished sessions to the phone (idle only)
//!
//! Two-button touchscreens (Venu, vivoactive, Venu X1) have no UP or DOWN key, so ENTER
//! and ESC carry everything. Touch is not the fallback — the whole delegate exists
//! because a wet screen taps itself.
//!   START  press          - begin a session, or log a wave while recording
//!   START  hold 1500ms    - end and save it
//!   BACK   press          - sync, but only while the Sync capsule is on screen
class SurfDelegate extends WatchUi.InputDelegate {

    //! Longer on two-button watches: the same key logs waves there, so a fumbled press held
    //! a beat too long would otherwise end the session mid-surf.
    private const HOLD_MS = 1000;
    private const HOLD_MS_TWO_KEY = 1500;

    private var _controller as SessionController;
    private var _holdTimer as Timer.Timer;
    private var _holdFired as Boolean = false;
    private var _hasDown as Boolean;
    private var _holdMs as Number;

    public function initialize(controller as SessionController) {
        InputDelegate.initialize();
        _controller = controller;
        _holdTimer = new Timer.Timer();
        _hasDown = (System.getDeviceSettings().inputButtons & System.BUTTON_INPUT_DOWN) != 0;
        _holdMs = _hasDown ? HOLD_MS : HOLD_MS_TWO_KEY;
    }

    public function onKeyPressed(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();
        if (key == WatchUi.KEY_ENTER) {
            // Only a hold ends a session. A stray press mid-session must not kill the recording.
            if (_controller.isRecording()) {
                _holdFired = false;
                _holdTimer.start(method(:onHoldElapsed), _holdMs, false);
            }
            return true;
        }
        if (key == WatchUi.KEY_DOWN) {
            _controller.logWave();
            return true;
        }
        if (key == WatchUi.KEY_UP) {
            if (!_controller.isRecording()) {
                _controller.sync();
            }
            return true;
        }
        if (key == WatchUi.KEY_ESC && syncsOnBack()) {
            _controller.sync();
            return true;
        }
        return isConsumed(key);
    }

    public function onKeyReleased(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();
        if (key == WatchUi.KEY_ENTER) {
            _holdTimer.stop();
            if (!_holdFired) {
                if (!_controller.isRecording()) {
                    _controller.start();
                } else if (!_hasDown) {
                    // No DOWN key to log with, so a short press does it instead.
                    _controller.logWave();
                }
            }
            _holdFired = false;
            return true;
        }
        return isConsumed(key);
    }

    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        // Everything is already handled on press/release. Swallow the ACTION event so the
        // system does not also apply its default behavior to the same button.
        return isConsumed(keyEvent.getKey());
    }

    //! Swipes only reach an InputDelegate on touchscreen models, and only before
    //! configureTouchEvents() has suppressed them. Eat them anyway while recording.
    public function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return _controller.isRecording();
    }

    public function onHoldElapsed() as Void {
        _holdFired = true;
        _controller.end();
    }

    //! BACK syncs on two-button watches, but only in the exact state where the idle screen
    //! is drawing the Sync capsule. With nothing to sync the button keeps its normal meaning
    //! and leaves the app, so BACK never does something the screen is not offering.
    private function syncsOnBack() as Boolean {
        return !_hasDown && !_controller.isRecording() && (_controller.getPendingCount() > 0);
    }

    //! BACK is swallowed for as long as a session is live, so neither the ESC button nor a
    //! phantom swipe-right can exit mid-session. (Long-press BACK still exits at the system
    //! level and cannot be blocked — AppBase.onStop() saves the session in that case.)
    private function isConsumed(key as WatchUi.Key) as Boolean {
        if (key == WatchUi.KEY_ESC) {
            return _controller.isRecording() || syncsOnBack();
        }
        return (key == WatchUi.KEY_ENTER) || (key == WatchUi.KEY_DOWN) || (key == WatchUi.KEY_UP);
    }
}
