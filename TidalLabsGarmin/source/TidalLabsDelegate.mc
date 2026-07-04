import Toybox.Lang;
import Toybox.WatchUi;

class TidalLabsDelegate extends WatchUi.BehaviorDelegate {

    private var _view as TidalLabsView;

    function initialize(view as TidalLabsView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    // SELECT (START button) — start session when idle, record wave when active
    function onSelect() as Boolean {
        if (!_view.sessionActive) {
            _view.startSession();
        } else {
            _view.recordWave();
        }
        return true;
    }

    // UP button — record wave during session (matches "Scroll Up to Record"), start from idle
    function onNextPage() as Boolean {
        if (_view.sessionActive) {
            _view.recordWave();
        } else {
            _view.startSession();
        }
        return true;
    }

    // BACK button — end session when active, exit app when idle
    function onBack() as Boolean {
        if (_view.sessionActive) {
            _view.endSession();
            return true;
        }
        return false;
    }
}
