import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class TidalLabsApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Lang.Dictionary?) as Void {
    }

    function onStop(state as Lang.Dictionary?) as Void {
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new TidalLabsView();
        var delegate = new TidalLabsDelegate(view);
        return [view, delegate];
    }
}
