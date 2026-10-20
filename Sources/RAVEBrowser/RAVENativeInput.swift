//
//  RAVENativeInput.swift
//  RAVEBrowser
//
//  Real input into a WKWebView on the Mac: `NSEvent`s handed to the web view
//  the way AppKit hands it a person's, so the page sees `isTrusted` events —
//  the thing a script cannot fake, and what sites that check (a payment
//  form, a "press and hold" check, an editor that ignores synthetic input)
//  key on. visionOS and iOS have no public way to inject a touch, which is
//  why the driver keeps synthetic events as the fallback.
//
//  Events go straight to the web view's responder methods rather than
//  through `NSWindow.sendEvent`: the press is meant for the page, whichever
//  window is key and whatever AppKit would have hit-tested on top of it.
//
//  Two presses are never sent this way, because AppKit answers them with a
//  menu it tracks modally, on the main thread, until a real mouse dismisses
//  it: a right click (the context menu) and a press on a `<select>` (its
//  popup). The driver sends those synthetically.
//

#if os(macOS) && canImport(WebKit)
import AppKit
import WebKit

@MainActor
enum RAVENativeInput {
    enum Button: Sendable { case left, middle }

    /// Real events reach only a web view that is in a window.
    static func isAvailable(for view: WKWebView) -> Bool { view.window != nil }

    /// A viewport point in CSS pixels, in the window's coordinates. The scale
    /// is the view's width over the viewport's (page zoom and magnification
    /// both change it), and any height the view has beyond the viewport is an
    /// inset along its top (a toolbar the page scrolls under).
    static func windowPoint(css point: CGPoint, viewport: CGSize, in view: WKWebView) -> NSPoint {
        let bounds = view.bounds
        let scale = viewport.width > 0 ? bounds.width / viewport.width : 1
        let inset = max(0, bounds.height - viewport.height * scale)
        let fromTop = inset + point.y * scale
        let local = NSPoint(x: point.x * scale, y: view.isFlipped ? fromTop : bounds.height - fromTop)
        return view.convert(local, to: nil)
    }

    static func modifierFlags(_ modifiers: RAVEPageModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    // MARK: - Mouse

    static func move(_ view: WKWebView, to point: NSPoint) {
        guard let event = mouseEvent(.mouseMoved, at: point, in: view) else { return }
        view.mouseMoved(with: event)
    }

    static func click(_ view: WKWebView, at point: NSPoint, button: Button = .left, count: Int = 1,
                      modifiers: RAVEPageModifiers = []) {
        let flags = modifierFlags(modifiers)
        // Onto the target first, as a real pointer would arrive: hover state,
        // `pointerenter` and the cursor all come from this.
        move(view, to: point)
        for click in 1...max(1, count) {
            switch button {
            case .left:
                if let down = mouseEvent(.leftMouseDown, at: point, in: view, flags: flags, clickCount: click) {
                    view.mouseDown(with: down)
                }
                if let up = mouseEvent(.leftMouseUp, at: point, in: view, flags: flags, clickCount: click) {
                    view.mouseUp(with: up)
                }
            case .middle:
                if let down = mouseEvent(.otherMouseDown, at: point, in: view, flags: flags, clickCount: click, button: 2) {
                    view.otherMouseDown(with: down)
                }
                if let up = mouseEvent(.otherMouseUp, at: point, in: view, flags: flags, clickCount: click, button: 2) {
                    view.otherMouseUp(with: up)
                }
            }
        }
    }

    /// Press at `from`, move in `steps` to `to`, release. For pointer-driven
    /// drags (a slider, a canvas, a map). HTML drag and drop is not this: it
    /// starts an AppKit dragging session, which follows the real mouse only.
    static func drag(_ view: WKWebView, from: NSPoint, to: NSPoint, steps: Int) {
        move(view, to: from)
        if let down = mouseEvent(.leftMouseDown, at: from, in: view) { view.mouseDown(with: down) }
        let n = max(1, steps)
        for step in 1...n {
            let t = CGFloat(step) / CGFloat(n)
            let point = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let dragged = mouseEvent(.leftMouseDragged, at: point, in: view, pressure: 1) {
                view.mouseDragged(with: dragged)
            }
        }
        if let up = mouseEvent(.leftMouseUp, at: to, in: view) { view.mouseUp(with: up) }
    }

    // MARK: - Keyboard

    /// Makes the web view first responder in its window, which is where key
    /// events and inserted text go.
    static func focus(_ view: WKWebView) {
        guard let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    /// One press: key down and key up, with its modifiers held. Command
    /// chords are offered as key equivalents first, as AppKit does, so
    /// Command-A selects all and Command-C copies.
    static func press(_ view: WKWebView, _ chord: RAVEPageKeyChord) {
        focus(view)
        let flags = modifierFlags(chord.modifiers)
        guard let down = keyEvent(.keyDown, chord, flags: flags, in: view),
              let up = keyEvent(.keyUp, chord, flags: flags, in: view) else { return }
        if chord.modifiers.contains(.command), view.performKeyEquivalent(with: down) { return }
        if chord.modifiers.contains(.command), let action = commandAction(chord), view.responds(to: action) {
            view.perform(action, with: nil)
            return
        }
        view.keyDown(with: down)
        view.keyUp(with: up)
    }

    /// Text inserted as typing inserts it (`insertText:`), into whatever has
    /// focus in the page: one trusted `beforeinput`/`input` per call, with no
    /// key codes to know and no keyboard layout to match.
    static func insert(_ view: WKWebView, text: String) {
        focus(view)
        view.insertText(text)
    }

    /// The editing commands a Command chord means when nothing claims it as
    /// a key equivalent (a web view outside an app with an Edit menu).
    private static func commandAction(_ chord: RAVEPageKeyChord) -> Selector? {
        guard chord.modifiers.subtracting(.shift) == .command else { return nil }
        switch chord.key.lowercased() {
        case "a": return #selector(NSText.selectAll(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "x": return #selector(NSText.cut(_:))
        case "z": return chord.modifiers.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    // MARK: - Events

    private static var eventNumber = 0

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in view: WKWebView,
                                   flags: NSEvent.ModifierFlags = [], clickCount: Int = 1, button: Int = 0,
                                   pressure: Float? = nil) -> NSEvent? {
        guard let window = view.window else { return nil }
        eventNumber += 1
        let isPress = type == .leftMouseDown || type == .otherMouseDown || type == .leftMouseDragged
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: eventNumber, clickCount: type == .mouseMoved ? 0 : clickCount,
            pressure: pressure ?? (isPress ? 1 : 0))
        // `mouseEvent(with:)` has no button argument; the CGEvent underneath
        // carries it, and a middle press must say which button it is.
        if button != 0, let cgEvent = event?.cgEvent {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            return NSEvent(cgEvent: cgEvent)
        }
        return event
    }

    private static func keyEvent(_ type: NSEvent.EventType, _ chord: RAVEPageKeyChord,
                                 flags: NSEvent.ModifierFlags, in view: WKWebView) -> NSEvent? {
        guard let window = view.window else { return nil }
        let characters = chord.macCharacters
        // AppKit's convention: without Shift's effect for letters, lower case.
        let ignoringModifiers = chord.key.count == 1 ? chord.key.lowercased() : characters
        return NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: chord.modifiers.contains(.command) ? ignoringModifiers : characters,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: false,
            keyCode: chord.macKeyCode ?? 0)
    }
}
#endif
