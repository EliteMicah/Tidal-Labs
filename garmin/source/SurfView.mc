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
//! Direction 1a, "the ring is the face": recording puts a progress ring around the rim,
//! heart rate and wave count share one small line at the top, and the elapsed clock is the
//! only hero. The two keys the screen answers to are spelled out as badges under a rule.
//!
//! ponytail: every colour used here is high-luminance (white / green / cyan / light grey)
//! so it still resolves to a visible pixel on the 1 bit-per-pixel Instinct MIP screens.
//! Red and dark blue quantise to black there and vanish, so anything drawn in them (the
//! heart rate number and its heart) goes through accent(), which forces white on 1bpp.
class SurfView extends WatchUi.View {

    //! Row styles for drawStack().
    //!   PLAIN         value only, centred
    //!   CAPSULE       filled pill, black text — the primary action
    //!   OUTLINE       hollow pill, text in the row colour — the secondary action
    //!   STATS         heart + rate, rule, wave count + caption, on one line
    //!   BADGE         key name in a filled chip, caption beside it
    //!   BADGE_OUTLINE the same, chip hollow — for the destructive key
    private const PLAIN = 0;
    private const CAPSULE = 1;
    private const OUTLINE = 2;
    private const STATS = 3;
    private const BADGE = 4;
    private const BADGE_OUTLINE = 5;

    //! Matches the Start capsule and the ring on the Apple Watch app.
    private const CYAN = 0x56CDEC;
    //! Heart glyph and its number, per the design. Both go through accent().
    private const HEART = 0xFF3B4E;
    private const HEART_INK = 0xFFB2A0;
    //! The "end session" key, light enough to stay legible on black.
    private const SALMON = 0xFF8A8E;

    //! Wave-log flash: the ring sweeps from empty to full in FLASH_MS, holds full for
    //! FLASH_HOLD_MS, then clears. FLASH_FRAME_MS is the redraw rate while it runs.
    private const FLASH_MS = 400;
    private const FLASH_HOLD_MS = 250;
    private const FLASH_FRAME_MS = 40;

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

    //! Wave count as of the last draw, and the millisecond the flash started (null when no
    //! flash is running). The count is what tells the view a wave was logged: the controller
    //! already calls requestUpdate() from logWave(), so the change lands here immediately.
    private var _lastWaves as Number = 0;
    private var _flashStart as Number? = null;

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

        var waves = _controller.getWaveCount();
        if (waves != _lastWaves) {
            if (waves > _lastWaves) {
                startFlash();
            }
            _lastWaves = waves;
        }
        // Advances or ends the flash whether or not the ring is drawn, so the fast redraw
        // timer always gets stopped again — including on the Instincts, which have no ring.
        var sweep = flashSweep();

        if (_controller.isRecording()) {
            var ring = drawProgressRing(dc, sweep);
            drawRecording(dc, top + ring, dc.getHeight() - margin - ring);
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
        // Start is the filled one — one primary action, and it carries the accent.
        rows.add([button, accent(dc, CYAN), "Start (" + _keyEnter + ")", CAPSULE]);
        gaps.add(gap / 2);

        if (pending > 0) {
            rows.add([button, accent(dc, CYAN),
                      "Sync " + pending.toString() + " (" + _keySync + ")", OUTLINE]);
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
        var small = isSmall(dc);

        var heartRate = Activity.getActivityInfo().currentHeartRate;
        var hr = (heartRate != null) ? heartRate.toString() : null;
        var waves = _controller.getWaveCount().format("%02d");
        var elapsed = formatElapsed(_controller.getElapsedSeconds());

        var hintFont = Graphics.FONT_XTINY;
        var hintHeight = dc.getFontHeight(hintFont);
        var hintPad = capsulePad(hintHeight);
        var waveKey = _hasDown ? "DOWN" : "TAP";
        var stopKey = "HOLD " + _keyEnter;

        // The hints land at the bottom of the block, which on a round face is where the
        // chord is narrowest, so the caption is measured and shortened instead of trusted to
        // fit: "log a wave" degrades to "wave" and then to nothing at all, leaving the key
        // name — the half that cannot be guessed from the screen. The budget is the chord at
        // `bottom`, the lowest the block can reach, so it holds wherever drawStack ends up
        // centring the rows.
        var budget = usableWidth(dc, bottom) * 94 / 100;
        var waveCaption = fitCaption(dc, hintFont, waveKey, ["log a wave", "wave"], budget);
        var stopCaption = fitCaption(dc, hintFont, stopKey, ["end session", "end"], budget);

        // A badge costs a row of vertical padding, and the 176px Instincts have none to
        // spare. They degrade to plain text — so does any round face where the chip and its
        // caption would still run past the chord once the captions are as short as they go.
        var badges = !small
            && (badgeRowWidth(dc, hintFont, waveKey, waveCaption) <= budget)
            && (badgeRowWidth(dc, hintFont, stopKey, stopCaption) <= budget);
        var hintRowHeight = badges ? hintHeight + (2 * hintPad) : hintHeight;

        var statGap = labelHeight / 3;
        var hintGap = labelHeight / 2;

        // The hints ride higher than the block would otherwise centre them: down at the
        // bottom of a round face they sit right on the bezel, and the space is dead anyway.
        bottom -= labelHeight / 2;

        // Everything except the elapsed clock has a known height, so the clock gets the rest.
        var fixed = labelHeight + statGap + hintGap
                  + (2 * hintRowHeight) + (badges ? hintPad : 0);
        var heightBudget = (bottom - top) - fixed;
        var widthBudget = dc.getWidth() * 78 / 100;

        var number = NUMBER_FONTS[NUMBER_FONTS.size() - 1];
        for (var i = 0; i < NUMBER_FONTS.size(); i++) {
            var candidate = NUMBER_FONTS[i];
            if ((dc.getFontHeight(candidate) <= heightBudget)
                && (dc.getTextWidthInPixels(elapsed, candidate) <= widthBudget)) {
                number = candidate;
                break;
            }
        }

        var rows = [
            [label, Graphics.COLOR_WHITE, hr, STATS, waves],
            [number, Graphics.COLOR_WHITE, elapsed, PLAIN]
        ] as Array<Array>;
        var gaps = [statGap, hintGap] as Array<Number>;

        rows.add([hintFont, accent(dc, CYAN),
                  badges ? waveKey : hintText(waveKey, waveCaption),
                  badges ? BADGE : PLAIN, waveCaption]);
        gaps.add(badges ? hintPad : 0);
        rows.add([hintFont, accent(dc, SALMON),
                  badges ? stopKey : hintText(stopKey, stopCaption),
                  badges ? BADGE_OUTLINE : PLAIN, stopCaption]);

        drawStack(dc, rows, gaps, top, bottom);
    }

    //! The ring around the rim. Returns the width it claims from the top and bottom of the
    //! layout, or 0 when nothing was drawn.
    //!
    //! The ring is not a clock. It sits empty for the whole session and fills in one quick
    //! sweep when a wave is logged, which is the confirmation the button press has no other
    //! way to give: Garmin has no crown to scrub and the wave count is small type. `sweep` is
    //! 0..360 degrees, from flashSweep().
    private function drawProgressRing(dc as Graphics.Dc, sweep as Number) as Number {
        // Where a sub-display is fitted it physically covers the rim the ring would run
        // along, so those three products go without it.
        if (subscreen() != null) {
            return 0;
        }
        var size = dc.getWidth() < dc.getHeight() ? dc.getWidth() : dc.getHeight();
        var pen = size * 4 / 100;
        if (pen < 3) {
            pen = 3;
        }
        var radius = (size / 2) - pen;
        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;

        dc.setPenWidth(pen);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, radius);

        if (sweep >= 360) {
            // A 360 degree arc has the same start and end angle, which drawArc cannot tell
            // from a zero-length one. Draw the closed ring instead.
            dc.setColor(accent(dc, CYAN), Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, radius);
        } else if (sweep >= 1) {
            // Degrees run counter-clockwise from 3 o'clock, so 12 o'clock is 90 and a
            // clockwise sweep counts down from there.
            var end = 90 - sweep;
            if (end < 0) {
                end += 360;
            }
            dc.setColor(accent(dc, CYAN), Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, radius, Graphics.ARC_CLOCKWISE, 90, end);
        }
        dc.setPenWidth(1);
        return pen * 2;
    }

    //! Degrees of ring to draw right now, 0 when no flash is running. Also owns the flash
    //! lifetime: it ends the animation and drops the redraw rate back to 1s once the hold
    //! has expired, so nothing else has to remember to.
    private function flashSweep() as Number {
        var start = _flashStart;
        if (start == null) {
            return 0;
        }
        // getTimer() wraps at the 32-bit boundary, which makes age negative. Treat that as
        // the animation being over rather than leaving the fast timer running for 24 days.
        var age = System.getTimer() - start;
        if ((age < 0) || (age >= FLASH_MS + FLASH_HOLD_MS)) {
            endFlash();
            return 0;
        }
        if (age >= FLASH_MS) {
            return 360;
        }
        return (age * 360) / FLASH_MS;
    }

    private function startFlash() as Void {
        _flashStart = System.getTimer();
        _tick.stop();
        _tick.start(method(:onTick), FLASH_FRAME_MS, true);
    }

    private function endFlash() as Void {
        _flashStart = null;
        _tick.stop();
        _tick.start(method(:onTick), 1000, true);
    }

    //! Width of a badge row: the chip, a gap, the caption. An empty caption is a bare chip,
    //! and then the gap would push it off centre.
    private function badgeRowWidth(dc as Graphics.Dc, font as Graphics.FontDefinition,
                                   key as String, caption as String) as Number {
        var pad = capsulePad(dc.getFontHeight(font));
        return dc.getTextWidthInPixels(key, font) + (3 * pad)
                + captionGap(pad, caption)
                + dc.getTextWidthInPixels(caption, font);
    }

    private function captionGap(pad as Number, caption as String) as Number {
        return (caption.length() > 0) ? (2 * pad) : 0;
    }

    //! The longest caption that still fits on one plain line beside `key`, longest first, or
    //! "" when none of them do.
    private function fitCaption(dc as Graphics.Dc, font as Graphics.FontDefinition,
                                key as String, candidates as Array<String>,
                                budget as Number) as String {
        for (var i = 0; i < candidates.size(); i++) {
            var caption = candidates[i];
            if (dc.getTextWidthInPixels(key + " " + caption, font) <= budget) {
                return caption;
            }
        }
        return "";
    }

    private function hintText(key as String, caption as String) as String {
        return (caption.length() > 0) ? (key + " " + caption) : key;
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
        var style = row[3] as Number;
        if ((style == CAPSULE) || (style == OUTLINE)
            || (style == BADGE) || (style == BADGE_OUTLINE)) {
            return height + (2 * capsulePad(height));
        }
        return height;
    }

    private function drawRow(dc as Graphics.Dc, row as Array, x as Number, y as Number) as Void {
        var font = row[0] as Graphics.FontDefinition;
        var color = row[1] as Graphics.ColorType;
        var value = row[2] as String;
        var style = row[3] as Number;
        var fontHeight = dc.getFontHeight(font);

        if (style == STATS) {
            drawStatRow(dc, font, value, row[4] as String, x, y);
            return;
        }

        if ((style == BADGE) || (style == BADGE_OUTLINE)) {
            drawBadgeRow(dc, font, color, value, row[4] as String, style == BADGE, x, y);
            return;
        }

        if ((style != CAPSULE) && (style != OUTLINE)) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, font, value, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var pad = capsulePad(fontHeight);
        var height = fontHeight + (2 * pad);
        var width = dc.getTextWidthInPixels(value, font) + (4 * pad);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (style == OUTLINE) {
            dc.setPenWidth(2);
            dc.drawRoundedRectangle(x - (width / 2), y, width, height, height / 2);
            dc.setPenWidth(1);
            dc.drawText(x, y + pad, font, value, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        dc.fillRoundedRectangle(x - (width / 2), y, width, height, height / 2);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + pad, font, value, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! "<3 132 | 07 WAVES" on one line. Heart rate is dropped, rule and all, when the sensor
    //! has nothing — the wave count then centres on its own.
    private function drawStatRow(dc as Graphics.Dc, font as Graphics.FontDefinition,
                                 hr as String?, waves as String,
                                 x as Number, y as Number) as Void {
        var height = dc.getFontHeight(font);
        var gap = dc.getTextWidthInPixels("  ", font);
        var iconSize = height * 3 / 5;
        var iconGap = iconSize / 3;

        var wavesWidth = dc.getTextWidthInPixels(waves, font);
        var captionWidth = dc.getTextWidthInPixels(" WAVES", font);
        var hrWidth = 0;
        var total = wavesWidth + captionWidth;
        if (hr != null) {
            hrWidth = dc.getTextWidthInPixels(hr, font) + iconGap + iconSize;
            total += hrWidth + (2 * gap) + 1;
        }

        var cursor = x - (total / 2);
        if (hr != null) {
            dc.setColor(accent(dc, HEART_INK), Graphics.COLOR_TRANSPARENT);
            dc.drawText(cursor, y, font, hr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(accent(dc, HEART), Graphics.COLOR_TRANSPARENT);
            drawHeart(dc, cursor + dc.getTextWidthInPixels(hr, font) + iconGap,
                      y + ((height - iconSize) / 2), iconSize);
            cursor += hrWidth + gap;
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(cursor, y + (height / 4), 1, height / 2);
            cursor += 1 + gap;
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cursor, y, font, waves, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cursor + wavesWidth, y, font, " WAVES", Graphics.TEXT_JUSTIFY_LEFT);
    }

    //! A key name in a chip with its caption beside it — "DOWN  log a wave". Filled for the
    //! key you press all session, hollow for the one that ends it.
    private function drawBadgeRow(dc as Graphics.Dc, font as Graphics.FontDefinition,
                                  color as Graphics.ColorType, key as String,
                                  caption as String, filled as Boolean,
                                  x as Number, y as Number) as Void {
        var height = dc.getFontHeight(font);
        var pad = capsulePad(height);
        var chipHeight = height + (2 * pad);
        var chipWidth = dc.getTextWidthInPixels(key, font) + (3 * pad);
        var gap = captionGap(pad, caption);
        var left = x - ((chipWidth + gap + dc.getTextWidthInPixels(caption, font)) / 2);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (filled) {
            dc.fillRoundedRectangle(left, y, chipWidth, chipHeight, chipHeight / 3);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        } else {
            dc.setPenWidth(2);
            dc.drawRoundedRectangle(left, y, chipWidth, chipHeight, chipHeight / 3);
            dc.setPenWidth(1);
        }
        dc.drawText(left + (chipWidth / 2), y + pad, font, key, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left + chipWidth + gap, y + pad, font, caption, Graphics.TEXT_JUSTIFY_LEFT);
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
