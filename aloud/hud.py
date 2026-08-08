"""The floating reader panel.

Design notes, so future edits stay coherent:

The panel is a rounded card that sits low on the screen, out of the way of
what you were reading. Top row: the icon and name of the app being read
from. Middle: the waveform — it is not decoration, it is the RMS envelope
of the synthesised audio with a playhead sweeping left to right, and it is
also the scrubber: click or drag anywhere on it to jump. Bottom: transport
controls. Everything but the waveform is deliberately quiet.

  ink      #12121A   scrim over the vibrancy layer
  paper    #EDEAE3   app name, control glyphs
  muted    #8A8794   time readout, hints, secondary state
  signal   #9A8CF0   playhead, lit waveform bars, hover rings
  shadow   #443C6B   unplayed waveform bars
"""

from __future__ import annotations

import time
from typing import Callable

import objc
import Quartz  # noqa: F401 — registers CGColorRef so NSColor.CGColor() bridges cleanly
from AppKit import (
    NSAnimationContext,
    NSBezierPath,
    NSColor,
    NSCompositingOperationSourceAtop,
    NSCompositingOperationSourceOver,
    NSFont,
    NSFontAttributeName,
    NSFontDescriptorSystemDesignRounded,
    NSFontWeightMedium,
    NSFontWeightSemibold,
    NSForegroundColorAttributeName,
    NSImage,
    NSImageScaleProportionallyUpOrDown,
    NSImageSymbolConfiguration,
    NSImageView,
    NSLineBreakByTruncatingTail,
    NSMakeRect,
    NSPanel,
    NSRectFillUsingOperation,
    NSScreen,
    NSScreenSaverWindowLevel,
    NSTextAlignmentCenter,
    NSTextAlignmentLeft,
    NSTextField,
    NSTrackingActiveAlways,
    NSTrackingArea,
    NSTrackingMouseEnteredAndExited,
    NSView,
    NSViewHeightSizable,
    NSViewWidthSizable,
    NSVisualEffectBlendingModeBehindWindow,
    NSVisualEffectMaterialHUDWindow,
    NSVisualEffectStateActive,
    NSVisualEffectView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
)
from Foundation import NSPoint, NSTimer, NSZeroRect
from PyObjCTools import AppHelper

PANEL_W = 400.0
PANEL_H = 172.0
BOTTOM_INSET = 140.0
CORNER = 24.0

WAVE_BUCKETS = 46
WAVE_H = 32.0
WAVE_PAD = 28.0

SKIP_SECONDS = 10.0


def _rgb(hex_str: str, alpha: float = 1.0):
    hex_str = hex_str.lstrip("#")
    r, g, b = (int(hex_str[i : i + 2], 16) / 255.0 for i in (0, 2, 4))
    return NSColor.colorWithSRGBRed_green_blue_alpha_(r, g, b, alpha)


INK = _rgb("12121A", 0.72)
PAPER = _rgb("EDEAE3")
MUTED = _rgb("8A8794")
SIGNAL = _rgb("9A8CF0")
SHADOW = _rgb("443C6B")


def _rounded_font(size: float, weight: float):
    """SF Rounded when available — speech should not look like a spreadsheet."""
    base = NSFont.systemFontOfSize_weight_(size, weight)
    desc = base.fontDescriptor().fontDescriptorWithDesign_(
        NSFontDescriptorSystemDesignRounded
    )
    if desc is not None:
        rounded = NSFont.fontWithDescriptor_size_(desc, size)
        if rounded is not None:
            return rounded
    return base


def _symbol(name: str, point_size: float, color) -> NSImage | None:
    """An SF Symbol rendered in our palette instead of template black."""
    img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
    if img is None:
        return None
    cfg = NSImageSymbolConfiguration.configurationWithPointSize_weight_(
        point_size, NSFontWeightMedium
    )
    img = img.imageWithSymbolConfiguration_(cfg)
    size = img.size()
    out = NSImage.alloc().initWithSize_(size)
    out.lockFocus()
    rect = NSMakeRect(0, 0, size.width, size.height)
    img.drawInRect_fromRect_operation_fraction_(
        rect, NSZeroRect, NSCompositingOperationSourceOver, 1.0
    )
    color.set()
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop)
    out.unlockFocus()
    return out


def _fmt_time(seconds: float) -> str:
    m, s = divmod(max(0, int(seconds)), 60)
    return f"{m}:{s:02d}"


class WaveView(NSView):
    """The signature element: the audio you are hearing — and the scrubber."""

    def initWithFrame_(self, frame):
        self = objc.super(WaveView, self).initWithFrame_(frame)
        if self is None:
            return None
        self._envelope = [0.08] * WAVE_BUCKETS
        self._progress = 0.0
        self._idle = True
        self._on_seek = None
        return self

    def setEnvelope_(self, envelope):
        self._envelope = list(envelope) or [0.08] * WAVE_BUCKETS
        self._idle = False
        self.setNeedsDisplay_(True)

    def setProgress_(self, value):
        self._progress = max(0.0, min(1.0, value))
        self.setNeedsDisplay_(True)

    def setIdle_(self, flag):
        self._idle = bool(flag)
        self.setNeedsDisplay_(True)

    def setSeekBlock_(self, fn):
        self._on_seek = fn

    def mouseDownCanMoveWindow(self):
        return False

    def mouseDown_(self, event):
        self.seekWithEvent_(event)

    def mouseDragged_(self, event):
        self.seekWithEvent_(event)

    def seekWithEvent_(self, event):
        point = self.convertPoint_fromView_(event.locationInWindow(), None)
        width = self.bounds().size.width
        if width <= 0:
            return
        fraction = max(0.0, min(1.0, point.x / width))
        if self._on_seek is not None:
            self._on_seek(fraction)
        self.setProgress_(fraction)

    def drawRect_(self, rect):
        bounds = self.bounds()
        count = len(self._envelope)
        if count == 0:
            return

        slot = bounds.size.width / count
        width = max(1.5, slot - 1.6)
        mid = bounds.size.height / 2.0
        playhead = self._progress * count

        for i, level in enumerate(self._envelope):
            # A floor keeps silence legible as a thin seam rather than a gap.
            height = max(2.0, level * bounds.size.height)
            x = i * slot
            bar = NSMakeRect(x, mid - height / 2.0, width, height)

            if self._idle:
                MUTED.colorWithAlphaComponent_(0.25).set()
            elif i < playhead - 1:
                SIGNAL.colorWithAlphaComponent_(0.95).set()
            elif i < playhead:
                # Soften the leading edge so the sweep does not stutter.
                SIGNAL.colorWithAlphaComponent_(0.55).set()
            else:
                SHADOW.colorWithAlphaComponent_(0.85).set()

            NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                bar, width / 2.0, width / 2.0
            ).fill()


class GlyphButton(NSView):
    """A transport control: an SF Symbol with a hover ring, nothing more."""

    def initWithFrame_(self, frame):
        self = objc.super(GlyphButton, self).initWithFrame_(frame)
        if self is None:
            return None
        self._image = None
        self._hover = False
        self._action = None
        return self

    def setImage_(self, image):
        self._image = image
        self.setNeedsDisplay_(True)

    def setActionBlock_(self, fn):
        self._action = fn

    def mouseDownCanMoveWindow(self):
        return False

    def updateTrackingAreas(self):
        for area in list(self.trackingAreas()):
            self.removeTrackingArea_(area)
        area = NSTrackingArea.alloc().initWithRect_options_owner_userInfo_(
            self.bounds(),
            NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways,
            self,
            None,
        )
        self.addTrackingArea_(area)

    def mouseEntered_(self, event):
        self._hover = True
        self.setNeedsDisplay_(True)

    def mouseExited_(self, event):
        self._hover = False
        self.setNeedsDisplay_(True)

    def mouseDown_(self, event):
        if self._action:
            self._action()

    def drawHover(self):
        if not self._hover:
            return
        b = self.bounds()
        ring = 17.0
        cx, cy = b.size.width / 2.0, b.size.height / 2.0
        circle = NSMakeRect(cx - ring, cy - ring, ring * 2, ring * 2)
        SIGNAL.colorWithAlphaComponent_(0.18).set()
        NSBezierPath.bezierPathWithOvalInRect_(circle).fill()

    def drawRect_(self, rect):
        self.drawHover()
        if self._image is None:
            return
        b = self.bounds()
        size = self._image.size()
        target = NSMakeRect(
            (b.size.width - size.width) / 2.0,
            (b.size.height - size.height) / 2.0,
            size.width,
            size.height,
        )
        self._image.drawInRect_fromRect_operation_fraction_(
            target, NSZeroRect, NSCompositingOperationSourceOver, 1.0
        )


class TextButton(GlyphButton):
    """Same interaction as GlyphButton, but a short text glyph — the 1× speed."""

    def initWithFrame_(self, frame):
        self = objc.super(TextButton, self).initWithFrame_(frame)
        if self is None:
            return None
        self._title = ""
        return self

    def setTitle_(self, title):
        self._title = str(title)
        self.setNeedsDisplay_(True)

    def drawRect_(self, rect):
        self.drawHover()
        if not self._title:
            return
        from Foundation import NSAttributedString

        attrs = {
            NSFontAttributeName: _rounded_font(14.0, NSFontWeightSemibold),
            NSForegroundColorAttributeName: PAPER,
        }
        text = NSAttributedString.alloc().initWithString_attributes_(self._title, attrs)
        size = text.size()
        b = self.bounds()
        text.drawAtPoint_(
            NSPoint(
                (b.size.width - size.width) / 2.0,
                (b.size.height - size.height) / 2.0,
            )
        )


class ReaderHUD:
    """Owns the panel and keeps it in step with playback."""

    def __init__(
        self,
        engine,
        on_stop: Callable[[], None],
        on_toggle: Callable[[], None],
        on_seek: Callable[[float], None],
        on_skip: Callable[[float], None],
        on_speed: Callable[[], str],
        speed_label: str = "1×",
    ):
        self._engine = engine
        self._on_stop = on_stop
        self._on_toggle = on_toggle
        self._on_seek = on_seek
        self._on_skip = on_skip
        self._on_speed = on_speed
        self._initial_speed = speed_label
        self._timer = None
        self._hide_at = None
        self._session_id = None
        self._env_version = -1
        self._message_mode = False
        self._source_name = None
        self._source_icon = None
        self._showing_pause = None
        self._build()

    # -- construction --------------------------------------------------------

    def _build(self):
        screen = NSScreen.mainScreen().frame()
        x = (screen.size.width - PANEL_W) / 2.0
        frame = NSMakeRect(x, BOTTOM_INSET, PANEL_W, PANEL_H)

        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            frame,
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            2,
            False,
        )
        self.panel.setLevel_(NSScreenSaverWindowLevel)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setHasShadow_(True)
        self.panel.setHidesOnDeactivate_(False)
        self.panel.setMovableByWindowBackground_(True)
        self.panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorStationary
        )
        self.panel.setAlphaValue_(0.0)

        blur = NSVisualEffectView.alloc().initWithFrame_(
            NSMakeRect(0, 0, PANEL_W, PANEL_H)
        )
        blur.setMaterial_(NSVisualEffectMaterialHUDWindow)
        blur.setBlendingMode_(NSVisualEffectBlendingModeBehindWindow)
        blur.setState_(NSVisualEffectStateActive)
        blur.setWantsLayer_(True)
        blur.layer().setCornerRadius_(CORNER)
        blur.layer().setMasksToBounds_(True)
        blur.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        self.panel.setContentView_(blur)

        scrim = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, PANEL_W, PANEL_H))
        scrim.setWantsLayer_(True)
        scrim.layer().setBackgroundColor_(INK.CGColor())
        scrim.layer().setCornerRadius_(CORNER)
        scrim.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        blur.addSubview_(scrim)

        # Source row: the app being read from.
        self.icon = NSImageView.alloc().initWithFrame_(NSMakeRect(0, 131, 26.0, 26.0))
        self.icon.setImageScaling_(NSImageScaleProportionallyUpOrDown)
        self.icon.setWantsLayer_(True)
        self.icon.layer().setCornerRadius_(6.0)
        self.icon.layer().setMasksToBounds_(True)
        self.icon.setHidden_(True)
        blur.addSubview_(self.icon)

        self.name_label = NSTextField.alloc().initWithFrame_(
            NSMakeRect(20.0, 131.0, PANEL_W - 40.0, 24.0)
        )
        self._style_label(
            self.name_label, _rounded_font(18.0, NSFontWeightSemibold), PAPER
        )
        blur.addSubview_(self.name_label)

        # Waveform scrubber.
        self.wave = WaveView.alloc().initWithFrame_(
            NSMakeRect(WAVE_PAD, 92.0, PANEL_W - WAVE_PAD * 2, WAVE_H)
        )
        self.wave.setSeekBlock_(self._on_seek)
        blur.addSubview_(self.wave)

        self.time_label = NSTextField.alloc().initWithFrame_(
            NSMakeRect(20.0, 72.0, PANEL_W - 40.0, 14.0)
        )
        self._style_label(
            self.time_label,
            NSFont.monospacedDigitSystemFontOfSize_weight_(10.0, 0.0),
            MUTED,
        )
        self.time_label.setAlignment_(NSTextAlignmentCenter)
        blur.addSubview_(self.time_label)

        # Transport row.
        self._img_play = _symbol("play.fill", 17.0, PAPER)
        self._img_pause = _symbol("pause.fill", 17.0, PAPER)

        def control(cls, offset, action):
            btn = cls.alloc().initWithFrame_(
                NSMakeRect(PANEL_W / 2.0 + offset - 22.0, 14.0, 44.0, 44.0)
            )
            btn.setActionBlock_(action)
            blur.addSubview_(btn)
            return btn

        self.speed_btn = control(TextButton, -124.0, self._cycle_speed)
        self.speed_btn.setTitle_(self._initial_speed)

        back = control(GlyphButton, -62.0, lambda: self._on_skip(-SKIP_SECONDS))
        back.setImage_(_symbol("gobackward.10", 16.0, PAPER))

        self.play_btn = control(GlyphButton, 0.0, self._on_toggle)
        self.play_btn.setImage_(self._img_pause)
        self._showing_pause = True

        stop = control(GlyphButton, 62.0, self._on_stop)
        stop.setImage_(_symbol("stop.fill", 16.0, PAPER))

        fwd = control(GlyphButton, 124.0, lambda: self._on_skip(SKIP_SECONDS))
        fwd.setImage_(_symbol("goforward.10", 16.0, PAPER))

    @staticmethod
    def _style_label(field, font, color):
        field.setBezeled_(False)
        field.setDrawsBackground_(False)
        field.setEditable_(False)
        field.setSelectable_(False)
        field.setFont_(font)
        field.setTextColor_(color)
        field.cell().setLineBreakMode_(NSLineBreakByTruncatingTail)
        field.setStringValue_("")

    def _cycle_speed(self):
        self.speed_btn.setTitle_(self._on_speed())

    # -- visibility ----------------------------------------------------------

    def show(self):
        AppHelper.callAfter(self._show)

    def _show(self):
        self._hide_at = None
        self._reposition()
        self.panel.orderFrontRegardless()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.currentContext().setDuration_(0.16)
        self.panel.animator().setAlphaValue_(1.0)
        NSAnimationContext.endGrouping()
        self._ensure_timer()

    def _reposition(self):
        screen = NSScreen.mainScreen()
        if screen is None:
            return
        visible = screen.visibleFrame()
        x = visible.origin.x + (visible.size.width - PANEL_W) / 2.0
        y = visible.origin.y + BOTTOM_INSET
        self.panel.setFrameOrigin_(NSPoint(x, y))

    def hide(self, delay: float = 0.0):
        AppHelper.callAfter(self._schedule_hide, delay)

    def _schedule_hide(self, delay):
        if delay <= 0:
            self._hide_now()
        else:
            self._hide_at = time.time() + delay

    def _hide_now(self):
        self._hide_at = None
        NSAnimationContext.beginGrouping()
        NSAnimationContext.currentContext().setDuration_(0.22)
        self.panel.animator().setAlphaValue_(0.0)
        NSAnimationContext.endGrouping()
        self.wave.setIdle_(True)

    # -- state ---------------------------------------------------------------

    def set_source(self, name: str, icon=None):
        """Show which app the text came from. Icon is an NSImage or None."""
        AppHelper.callAfter(self._set_source, name, icon)

    def _set_source(self, name, icon):
        self._source_name = name or "…"
        self._source_icon = icon
        self._apply_source()

    def _apply_source(self):
        self._message_mode = False
        self.name_label.setAlignment_(NSTextAlignmentLeft)
        self.name_label.setStringValue_(self._source_name or "…")
        self.name_label.sizeToFit()
        f = self.name_label.frame()
        name_w = min(f.size.width, PANEL_W - 100.0)
        icon_w = 34.0 if self._source_icon is not None else 0.0
        x0 = (PANEL_W - icon_w - name_w) / 2.0
        if self._source_icon is not None:
            self.icon.setImage_(self._source_icon)
            self.icon.setHidden_(False)
            self.icon.setFrameOrigin_(NSPoint(x0, 131.0))
        else:
            self.icon.setHidden_(True)
        self.name_label.setFrame_(
            NSMakeRect(
                x0 + icon_w, 131.0 + (26.0 - f.size.height) / 2.0, name_w, f.size.height
            )
        )
        self.time_label.setStringValue_("")

    def set_message(self, text: str, status: str = ""):
        AppHelper.callAfter(self._set_message, text, status)

    def _set_message(self, text, status):
        self._message_mode = True
        self.icon.setHidden_(True)
        self.name_label.setAlignment_(NSTextAlignmentCenter)
        self.name_label.setFrame_(NSMakeRect(20.0, 131.0, PANEL_W - 40.0, 24.0))
        self.name_label.setStringValue_(text or "")
        self.time_label.setStringValue_(status or "")

    def set_speed_label(self, label: str):
        AppHelper.callAfter(self.speed_btn.setTitle_, label)

    # -- animation -----------------------------------------------------------

    def _ensure_timer(self):
        if self._timer is not None:
            return
        self._timer = NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            1.0 / 30.0, True, lambda _t: self._tick()
        )

    def _tick(self):
        snap = self._engine.snapshot() if self._engine is not None else None
        if snap is not None and snap["session"] != self._session_id:
            self._session_id = snap["session"]
            self._env_version = -1

        if snap is not None and snap["active"]:
            if snap["version"] != self._env_version and snap["buffered"] > 0:
                self._env_version = snap["version"]
                self.wave.setEnvelope_(self._engine.envelope(WAVE_BUCKETS))
                # First audio has arrived: replace any "warming up" notice.
                if self._message_mode and self._source_name:
                    self._apply_source()
            self.wave.setProgress_(snap["fraction"])
            if not self._message_mode:
                suffix = "" if snap["synth_done"] else "…"
                self.time_label.setStringValue_(
                    f"{_fmt_time(snap['position'])} / {_fmt_time(snap['buffered'])}{suffix}"
                )
            self._set_play_icon(snap["paused"])

        if self._hide_at is not None and time.time() >= self._hide_at:
            self._hide_now()

    def _set_play_icon(self, paused):
        want_pause = not paused
        if want_pause != self._showing_pause:
            self._showing_pause = want_pause
            self.play_btn.setImage_(self._img_pause if want_pause else self._img_play)
