import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The one and only view. High contrast, big numerals, no thin fonts — it has to be
//! readable in glare, through salt water and with the screen covered in droplets.
//!
//! ponytail: every colour used here is high-luminance (white / green / cyan / light grey)
//! so it still resolves to a visible pixel on the 1 bit-per-pixel Instinct MIP screens.
//! Red and dark blue quantise to black there and vanish, so anything drawn in them (the
//! heart rate number and its heart) goes through accent(), which forces white on 1bpp.
class SurfView extends WatchUi.View {

    //! Row styles for drawStack(). COUNT rows carry a caption in row[4] and draw it beside
    //! the value instead of under it, which buys back a whole row of height.
    private const PLAIN = 0;
    private const CAPSULE = 1;
    private const COUNT = 2;

    //! Matches the Start Session capsule on the Apple Watch app.
    private const CYAN = 0x00FFFF;

    //! Number fonts, largest first. Screens run from 166px to 454px and the same font id is
    //! a different size on each, so the layout measures and steps down instead of guessing.
    private const NUMBER_FONTS = [
        Graphics.FONT_NUMBER_MEDIUM,
        Graphics.FONT_NUMBER_MILD,
        Graphics.FONT_LARGE,
        Graphics.FONT_MEDIUM
    ] as Array<Graphics.FontDefinition>;

    private var _controller as SessionController;
    private var _tick as Timer.Timer;

    //! Key names for the hints, as Garmin's own manual prints them. KeyEnter is START on
    //! fenix/Forerunner, GPS on Instinct, ACTION on the two-button touchscreens; KeySync is
    //! UP everywhere with a DOWN key and BACK where there is none. Wired per family in
    //! monkey.jungle. DOWN is the same word on every five-button product, so it is inline.
    private var _keyEnter as String;
    private var _keySync as String;

    //! Same test SurfDelegate uses to pick its key map — the screen has to name the keys the
    //! delegate is actually listening to.
    private var _hasDown as Boolean;

    public function initialize(controller as SessionController) {
        View.initialize();
        _controller = controller;
        _tick = new Timer.Timer();
        _keyEnter = WatchUi.loadResource(Rez.Strings.KeyEnter) as String;
        _keySync = WatchUi.loadResource(Rez.Strings.KeySync) as String;
        _hasDown = (System.getDeviceSettings().inputButtons & System.BUTTON_INPUT_DOWN) != 0;
    }

    public function onShow() as Void {
        _tick.start(method(:onTick), 1000, true);
    }

    public function onHide() as Void {
        _tick.stop();
    }

    public function onTick() as Void {
        WatchUi.requestUpdate();
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // Time of day sits at the top of both screens, like the Apple Watch app.
        var label = labelFont(dc);
        var margin = dc.getHeight() * 6 / 100;
        var top = margin + dc.getFontHeight(label);

        // Instinct's always-on circular sub-display physically covers a corner of the
        // screen. getSubscreen() reports the exact reserved rect (top right, 62x62 of
        // 176x176 on instincte45mm) and returns null on every device without one, so the
        // clock centres in the strip beside it and the main stack starts below it.
        var sub = subscreen();
        var clockX = dc.getWidth() / 2;
        if (sub != null) {
            // Every device that reports one puts it in the right half; the clock takes the
            // strip beside it. Anything else keeps the clock centred rather than guessing.
            if (sub.x >= dc.getWidth() / 2) {
                clockX = sub.x / 2;
            }
            if (top < sub.y + sub.height) {
                top = sub.y + sub.height;
            }
        }
        drawRow(dc, [label, Graphics.COLOR_WHITE, clockText(), PLAIN], clockX, margin);

        if (_controller.isRecording()) {
            drawRecording(dc, top, dc.getHeight() - margin);
        } else {
            drawIdle(dc, top, dc.getHeight() - margin);
        }
    }

    private function drawIdle(dc as Graphics.Dc, top as Number, bottom as Number) as Void {
        var label = labelFont(dc);
        var button = isSmall(dc) ? Graphics.FONT_XTINY : Graphics.FONT_SMALL;
        var title = isSmall(dc) ? Graphics.FONT_SMALL : Graphics.FONT_MEDIUM;
        var gap = dc.getFontHeight(label) / 2;

        var status = _controller.getSyncStatus();
        var pending = _controller.getPendingCount();

        var rows = [] as Array<Array>;
        var gaps = [] as Array<Number>;

        // The 176px Instincts lose the top third of the screen to the sub-display and have
        // no room for a title row.
        if (!isSmall(dc)) {
            rows.add([title, Graphics.COLOR_WHITE, "Tidal Labs", PLAIN]);
            gaps.add(gap / 2);
        }
        // Each capsule names its own key, so the idle screen is its own instruction sheet.
        rows.add([button, Graphics.COLOR_WHITE, "Start (" + _keyEnter + ")", CAPSULE]);
        gaps.add(gap / 2);

        if (pending > 0) {
            rows.add([button, accent(dc, CYAN),
                      "Sync " + pending.toString() + " (" + _keySync + ")", CAPSULE]);
            gaps.add(gap / 4);
        }
        // Sync feedback is the only report the transmit ever makes, so it always gets a row.
        if (status != null) {
            rows.add([label, Graphics.COLOR_LT_GRAY, status, PLAIN]);
            gaps.add(0);
        }

        drawStack(dc, rows, gaps, top, bottom);
    }

    private function drawRecording(dc as Graphics.Dc, top as Number, bottom as Number) as Void {
        var label = labelFont(dc);
        var labelHeight = dc.getFontHeight(label);

        // Heart rate anchors the bottom of the screen; nothing is drawn when it is unavailable.
        // The number reads red with a heart glyph where the " BPM" caption used to be. Both
        // go through accent() so they stay visible on the 1bpp screens, where red is black.
        var heartRate = Activity.getActivityInfo().currentHeartRate;
        if (heartRate != null) {
            bottom -= labelHeight;
            var hrText = heartRate.toString();
            var iconSize = labelHeight * 3 / 5;
            var iconGap = iconSize / 3;
            var textWidth = dc.getTextWidthInPixels(hrText, label);
            var hrX = (dc.getWidth() - (textWidth + iconGap + iconSize)) / 2;

            dc.setColor(accent(dc, Graphics.COLOR_RED), Graphics.COLOR_TRANSPARENT);
            dc.drawText(hrX, bottom, label, hrText, Graphics.TEXT_JUSTIFY_LEFT);
            drawHeart(dc, hrX + textWidth + iconGap, bottom + ((labelHeight - iconSize) / 2),
                      iconSize);
        }

        // The two keys the recording screen answers to, spelled out under the wave count.
        // Always the smallest font: the hint is secondary, and it sits at the point where a
        // round face has narrowed the most.
        var hintFont = Graphics.FONT_XTINY;
        var hintHeight = dc.getFontHeight(hintFont);
        var hints = hintLines(dc, hintFont, bottom);
        var hintGap = labelHeight / 2;

        // The wave count and its caption share one line ("5 WAVES"), which buys back the row
        // the hints need. The 176px Instincts have no other way to fit both — they lose the
        // top third of the screen to the always-on sub-display — and the bigger screens read
        // better this way too, so every product does it.
        var waves = _controller.getWaveCount().toString();

        // The two number rows and the hints have to fit the space left over, and the widest
        // thing drawn has to clear the bezel on a round face. Both rows are measured: three
        // digits plus " WAVES" is wider than the clock.
        var elapsed = formatElapsed(_controller.getElapsedSeconds());
        var heightBudget = (bottom - top) - (hints.size() * hintHeight) - hintGap;
        var widthBudget = dc.getWidth() * 78 / 100;
        var number = NUMBER_FONTS[NUMBER_FONTS.size() - 1];
        for (var i = 0; i < NUMBER_FONTS.size(); i++) {
            var candidate = NUMBER_FONTS[i];
            var widest = dc.getTextWidthInPixels(elapsed, candidate);
            var countWidth = countRowWidth(dc, candidate, waves, "WAVES");
            if (countWidth > widest) {
                widest = countWidth;
            }
            if ((dc.getFontHeight(candidate) * 2 <= heightBudget) && (widest <= widthBudget)) {
                number = candidate;
                break;
            }
        }

        var rows = [
            [number, Graphics.COLOR_WHITE, elapsed, PLAIN],
            [number, accent(dc, Graphics.COLOR_GREEN), waves, COUNT, "WAVES"]
        ] as Array<Array>;

        // A gap after the last stat row, none between the hint lines themselves.
        var gaps = [] as Array<Number>;
        for (var i = 0; i < rows.size(); i++) {
            gaps.add(i == rows.size() - 1 ? hintGap : 0);
        }
        for (var i = 0; i < hints.size(); i++) {
            rows.add([hintFont, Graphics.COLOR_LT_GRAY, hints[i], PLAIN]);
        }

        drawStack(dc, rows, gaps, top, bottom);
    }

    //! Width of a COUNT row: the value in its number font, one space, the caption in the
    //! label font.
    private function countRowWidth(dc as Graphics.Dc, font as Graphics.FontDefinition,
                                   value as String, caption as String) as Number {
        var capFont = labelFont(dc);
        // The gap is a space in the *caption* font. A space in a number font is a full digit
        // advance, which pushed the caption a third of the screen away from the count.
        return dc.getTextWidthInPixels(value, font)
                + dc.getTextWidthInPixels(" ", capFont)
                + dc.getTextWidthInPixels(caption, capFont);
    }

    //! "DOWN wave   hold START end" on one line where it fits, split in two where it does
    //! not — the 260px MIP screens are the tight case. On the two-button watches the same
    //! key does both, so the tap half names the gesture rather than a second key.
    private function hintLines(dc as Graphics.Dc, font as Graphics.FontDefinition,
                               bottom as Number) as Array<String> {
        var wave = _hasDown ? "DOWN wave" : "Tap wave";
        var stop = "hold " + _keyEnter + " end";
        var joined = wave + "   " + stop;
        // Measured against the chord at the bottom of the block, not the full screen width:
        // the hint is the lowest thing drawn, and on a round face that is where the glass
        // runs out. Anything wider is clipped by the bezel.
        var budget = usableWidth(dc, bottom) * 94 / 100;
        if (dc.getTextWidthInPixels(joined, font) <= budget) {
            return [joined] as Array<String>;
        }
        return [wave, stop] as Array<String>;
    }

    //! How much of row y is actually on the glass. Full width on a rectangular screen, the
    //! chord of the circle on a round one — which is what clips the bottom rows.
    private function usableWidth(dc as Graphics.Dc, y as Number) as Number {
        if (System.getDeviceSettings().screenShape != System.SCREEN_SHAPE_ROUND) {
            return dc.getWidth();
        }
        var radius = dc.getHeight() / 2;
        var offset = (y - radius).abs();
        if (offset >= radius) {
            return 0;
        }
        return 2 * Math.sqrt((radius * radius) - (offset * offset)).toNumber();
    }

    //! Draw rows of [font, colour, text, style] as one block centred between top and bottom.
    //! gaps, if given, is the extra space added after each row.
    private function drawStack(dc as Graphics.Dc, rows as Array<Array>, gaps as Array<Number>?,
                               top as Number, bottom as Number) as Void {
        var total = 0;
        for (var i = 0; i < rows.size(); i++) {
            total += rowHeight(dc, rows[i]);
            if (gaps != null && i < gaps.size()) {
                total += gaps[i];
            }
        }

        var x = dc.getWidth() / 2;
        var y = top + ((bottom - top) - total) / 2;
        if (y < top) {
            y = top;
        }
        for (var i = 0; i < rows.size(); i++) {
            drawRow(dc, rows[i], x, y);
            y += rowHeight(dc, rows[i]);
            if (gaps != null && i < gaps.size()) {
                y += gaps[i];
            }
        }
    }

    private function rowHeight(dc as Graphics.Dc, row as Array) as Number {
        var height = dc.getFontHeight(row[0] as Graphics.FontDefinition);
        if ((row[3] as Number) == CAPSULE) {
            height += 2 * capsulePad(height);
        }
        return height;
    }

    private function drawRow(dc as Graphics.Dc, row as Array, x as Number, y as Number) as Void {
        var font = row[0] as Graphics.FontDefinition;
        var color = row[1] as Graphics.ColorType;
        var value = row[2] as String;

        if ((row[3] as Number) == COUNT) {
            // Value and caption side by side, bottoms aligned, the pair centred on x.
            var caption = row[4] as String;
            var capFont = labelFont(dc);
            var valueWidth = dc.getTextWidthInPixels(value, font);
            var spaceWidth = dc.getTextWidthInPixels(" ", capFont);
            var left = x - (countRowWidth(dc, font, value, caption) / 2);
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(left, y, font, value, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            // Sit the caption on the digits' baseline. Font *height* is the whole line box,
            // and a number font's is far taller than its digits, so aligning on it dropped
            // the caption most of a row below the count.
            dc.drawText(left + valueWidth + spaceWidth,
                        y + Graphics.getFontAscent(font) - Graphics.getFontAscent(capFont),
                        capFont, caption, Graphics.TEXT_JUSTIFY_LEFT);
            return;
        }

        if ((row[3] as Number) != CAPSULE) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, font, value, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var fontHeight = dc.getFontHeight(font);
        var pad = capsulePad(fontHeight);
        var height = fontHeight + (2 * pad);
        var width = dc.getTextWidthInPixels(value, font) + (4 * pad);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x - (width / 2), y, width, height, height / 2);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + pad, font, value, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function capsulePad(fontHeight as Number) as Number {
        return fontHeight / 5;
    }

    //! A heart in the box (x, y, size, size): two lobes and a triangle for the point.
    //! ponytail: primitives, not a bitmap — a drawable would need a PNG per icon size and
    //! the launcher icons already carry eight resource folders.
    private function drawHeart(dc as Graphics.Dc, x as Number, y as Number,
                               size as Number) as Void {
        var r = size / 4;
        dc.fillCircle(x + r, y + r, r);
        dc.fillCircle(x + size - r, y + r, r);
        dc.fillPolygon([
            [x, y + r],
            [x + size, y + r],
            [x + (size / 2), y + size]
        ]);
    }

    //! The area the system reserves for an always-on sub-display, or null where there is
    //! none. Only the three semioctagon Instincts (E 40/45mm, 3 Solar 45mm) define it.
    private function subscreen() as Graphics.BoundingBox? {
        if (!(WatchUi has :getSubscreen)) {
            return null;
        }
        return WatchUi.getSubscreen();
    }

    //! The 128K Instinct models are 176x176 and 166x166. Everything else is 260px or wider.
    //! Those same three products (Instinct E 40/45mm, Instinct 3 Solar 45mm) are also the
    //! only 1 bit-per-pixel screens in the product list, so this one test covers both.
    private function isSmall(dc as Graphics.Dc) as Boolean {
        return dc.getHeight() < 200;
    }

    //! On a 1 bit-per-pixel screen only pure black and pure white exist. Light greys and cyan
    //! quantise to white, but green quantises to *black* and vanishes on the black background,
    //! so accents are forced to white there. Verified in the simulator on instincte45mm.
    private function accent(dc as Graphics.Dc, color as Number) as Number {
        return isSmall(dc) ? Graphics.COLOR_WHITE : color;
    }

    private function labelFont(dc as Graphics.Dc) as Graphics.FontDefinition {
        return isSmall(dc) ? Graphics.FONT_XTINY : Graphics.FONT_TINY;
    }

    private function clockText() as String {
        var now = System.getClockTime();
        var hour = now.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) {
                hour = 12;
            }
        }
        return Lang.format("$1$:$2$", [hour.format("%d"), now.min.format("%02d")]);
    }

    private function formatElapsed(seconds as Number) as String {
        return Lang.format("$1$:$2$:$3$", [
            (seconds / 3600).format("%02d"),
            ((seconds % 3600) / 60).format("%02d"),
            (seconds % 60).format("%02d")
        ]);
    }
}
