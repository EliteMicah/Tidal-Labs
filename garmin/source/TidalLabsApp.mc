import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class TidalLabsApp extends Application.AppBase {

    private var _controller as SessionController;

    public function initialize() {
        AppBase.initialize();
        _controller = new SessionController();
    }

    public function onStart(state as Dictionary?) as Void {
    }

    //! Long-press BACK exits at the system level and cannot be blocked, so treat any
    //! shutdown as an end-of-session: save the FIT file rather than lose it.
    public function onStop(state as Dictionary?) as Void {
        _controller.end();
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new $.SurfView(_controller), new $.SurfDelegate(_controller)];
    }
}
