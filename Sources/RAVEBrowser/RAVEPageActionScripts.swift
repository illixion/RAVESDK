//
//  RAVEPageActionScripts.swift
//  RAVEBrowser
//
//  The scripts behind the actions added for agents that drive a browser the
//  way Chrome MCP does: keys, hover, drag, select, check, upload, waiting for
//  text, and the two halves of real (native) input: `target`, which finds
//  where a press must land, and `focusField`, which puts the caret where
//  native typing should go. Same rules as `RAVEPageScripts`: function bodies
//  for `callAsyncJavaScript`, run in the driver's own content world, each
//  starting with the shared prelude and returning a JSON string.
//
//  Synthetic events here are the fallback for platforms with no way to send a
//  real one (visionOS, iOS) and for presses a real event must not make: a
//  right click (AppKit would open a context menu and track it modally) and a
//  `<select>` (its native popup menu does the same).
//

extension RAVEPageScripts {

    /// Arguments: `ref`, or `x` and `y`. Scrolls a ref into view and says where
    /// a real press on it must land, in viewport CSS pixels: the centre, or the
    /// first of the five sample points `elements` hit-tests that is not
    /// covered. `covered` names what is on top when every point is; `newWindow`
    /// is a link's URL when it would open a new window.
    static let target = prelude + #"""
        watch();
        // Whether the real events that follow reach the page at all: WebKit
        // drops some (a pointer move into a window that is not key), and the
        // driver then falls back to synthetic ones.
        R.seen = {};
        for (const type of ['mousemove', 'mousedown']) {
            document.addEventListener(type, () => { R.seen[type] = true; }, { capture: true, once: true });
        }
        let el = ref !== null ? refElement(ref) : deepElementFromPoint(x, y);
        if (!el) throw new Error('nothing at ' + x + ',' + y);
        const vw = innerWidth, vh = innerHeight;
        let px = x, py = y, covered = null;
        if (ref !== null) {
            el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
            const r = el.getBoundingClientRect();
            const left = Math.max(r.left, 0), right = Math.min(r.right, vw - 1);
            const top = Math.max(r.top, 0), bottom = Math.min(r.bottom, vh - 1);
            const points = [[0.5, 0.5], [0.15, 0.15], [0.85, 0.15], [0.15, 0.85], [0.85, 0.85]]
                .map(([fx, fy]) => [left + (right - left) * fx, top + (bottom - top) * fy]);
            const lands = ([px, py]) => {
                const hit = deepElementFromPoint(px, py);
                return !!hit && (composedContains(el, hit) || composedContains(hit, el));
            };
            const point = points.find(lands);
            if (point) {
                [px, py] = point;
            } else {
                [px, py] = points[0];
                const hit = deepElementFromPoint(px, py);
                covered = hit ? describe(hit) : 'nothing (off screen)';
            }
        }
        const link = el.closest && el.closest('a[href]');
        const newWindow = link && link.target && !/^_(self|parent|top)$/i.test(link.target) ? link.href : null;
        const tag = el.tagName.toLowerCase();
        const select = tag === 'select' || !!(el.closest && el.closest('select'));
        return JSON.stringify({ target: describe(el), x: px, y: py, width: vw, height: vh, covered, newWindow, tag,
                                select, draggable: !!(el.closest && el.closest('[draggable=true]')) });
        """#

    /// No arguments. This document's frame id (null in the main frame), its
    /// URL and viewport, and its own iframes' content boxes in its viewport —
    /// what the driver needs to place a child frame's elements on the page.
    static let frameGeometry = prelude + #"""
        const frames = Array.from(document.querySelectorAll('iframe, frame')).map(f => {
            const r = f.getBoundingClientRect();
            return { src: f.src || (f.hasAttribute('srcdoc') ? 'about:srcdoc' : 'about:blank'),
                     x: r.left + f.clientLeft, y: r.top + f.clientTop, w: f.clientWidth, h: f.clientHeight,
                     shown: r.width > 1 && r.height > 1 && getComputedStyle(f).visibility !== 'hidden' };
        });
        return JSON.stringify({ id: R.frameID || null, url: location.href, width: innerWidth, height: innerHeight, frames });
        """#

    /// Arguments: `points` (`[x, y]` in viewport CSS pixels), `frame` (the
    /// index of an iframe in `frameGeometry`'s list). Which points land on
    /// that iframe rather than on something covering it.
    static let framePointsShown = prelude + #"""
        const f = document.querySelectorAll('iframe, frame')[frame];
        return JSON.stringify(points.map(([px, py]) => !!f && deepElementFromPoint(px, py) === f));
        """#

    /// No arguments. Which real events the page has seen since `target`.
    static let seen = prelude + #"""
        return JSON.stringify({ mousemove: !!(R.seen && R.seen.mousemove), mousedown: !!(R.seen && R.seen.mousedown) });
        """#

    /// Arguments: `ref`, `append`. Focuses a text field or an editable element
    /// and selects its contents (or, with `append`, puts the caret at the end),
    /// so text a native input inserts replaces or extends it.
    static let focusField = prelude + #"""
        const el = refElement(ref);
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        const tag = el.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA') {
            if (el.disabled || el.readOnly) throw new Error('ref ' + ref + ' is ' + describe(el) + ', which is ' + (el.disabled ? 'disabled' : 'read-only'));
            if (document.activeElement !== el && el.focus) el.focus({ preventScroll: true });
            try {
                if (append) el.setSelectionRange(el.value.length, el.value.length); else el.select();
            } catch (e) {
                // Types with no selection API (email, number): select() still works.
                if (!append && el.select) el.select();
            }
            return JSON.stringify({ target: describe(el), kind: 'field', value: el.type === 'password' ? '' : el.value });
        }
        if (el.isContentEditable) {
            if (el.focus) el.focus({ preventScroll: true });
            const selection = getSelection();
            selection.selectAllChildren(el);
            if (append) selection.collapseToEnd();
            return JSON.stringify({ target: describe(el), kind: 'editable', value: clean(el.innerText, 2000) });
        }
        if (tag === 'SELECT') throw new Error('ref ' + ref + ' is a <select>: use select with the option to choose');
        throw new Error('ref ' + ref + ' is ' + describe(el) + ', not a text field');
        """#

    /// Arguments: `ref`. A field's current text, to check what native typing did.
    static let fieldValue = prelude + #"""
        const el = refElement(ref);
        const value = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' ? el.value
            : el.isContentEditable ? el.innerText : '';
        return JSON.stringify({ target: describe(el), value });
        """#

    /// Arguments: `ref` (or null for whatever has focus), `keys`: presses as
    /// `{key, code, keyCode, shift, ctrl, alt, meta, text}`. Dispatches
    /// keydown/keypress/keyup for each and, unless the page cancelled the
    /// keydown, does what the key would have done: Enter submits a field's
    /// form or presses a button, Tab moves focus, Backspace and Delete erase,
    /// Space presses a button, arrows move through a `<select>`, and a key
    /// that types inserts its text.
    static let keys = prelude + #"""
        watch();
        const deepActive = () => {
            let a = document.activeElement;
            while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
            return a && a !== document.body ? a : null;
        };
        if (ref !== null) {
            const el = refElement(ref);
            el.scrollIntoView({ block: 'center', behavior: 'instant' });
            if (el.focus) el.focus({ preventScroll: true });
        }
        const FOCUSABLE = 'a[href],button,input:not([type=hidden]),select,textarea,[tabindex]:not([tabindex="-1"]),[contenteditable=""],[contenteditable=true]';
        const focusables = () => Array.from(allElements(document))
            .filter(e => e.matches && e.matches(FOCUSABLE) && !e.disabled && e.getClientRects().length);
        const isField = t => t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA');
        const setValue = (t, v, inputType, data) => {
            const proto = t.tagName === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(t, v);
            t.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType, data }));
        };
        const span = t => {
            let start = null, end = null;
            try { start = t.selectionStart; end = t.selectionEnd; } catch (e) {}
            if (start === null) start = end = t.value.length;
            return [start, end];
        };
        const caret = (t, at) => { try { t.setSelectionRange(at, at); } catch (e) {} };
        const insert = (t, text) => {
            if (isField(t)) {
                const [s, e] = span(t);
                setValue(t, t.value.slice(0, s) + text + t.value.slice(e), 'insertText', text);
                caret(t, s + text.length);
            } else if (t && t.isContentEditable) {
                document.execCommand('insertText', false, text);
            }
        };
        const erase = (t, forward) => {
            if (isField(t)) {
                let [s, e] = span(t);
                if (s === e) { if (forward) e = Math.min(t.value.length, e + 1); else s = Math.max(0, s - 1); }
                setValue(t, t.value.slice(0, s) + t.value.slice(e), forward ? 'deleteContentForward' : 'deleteContentBackward', null);
                caret(t, s);
            } else if (t && t.isContentEditable) {
                document.execCommand(forward ? 'forwardDelete' : 'delete', false);
            }
        };
        const press = t => { if (t && t.click) t.click(); };
        const act = (t, k) => {
            const tag = t ? t.tagName : '';
            const role = t ? roleOf(t) : '';
            if ((k.meta || k.ctrl) && k.key.toLowerCase() === 'a') {
                if (isField(t)) t.select(); else if (t && t.isContentEditable) getSelection().selectAllChildren(t);
                else getSelection().selectAllChildren(document.body);
                return;
            }
            if (k.meta || k.ctrl || k.alt) return;
            switch (k.key) {
            case 'Enter':
                if (tag === 'INPUT' && t.form) { if (t.form.requestSubmit) t.form.requestSubmit(); else t.form.submit(); }
                else if (tag === 'TEXTAREA') insert(t, '\n');
                else if (t && t.isContentEditable) document.execCommand('insertLineBreak', false);
                else if (role === 'button' || role === 'link' || tag === 'A') press(t);
                return;
            case 'Tab': {
                const list = focusables();
                const at = t ? list.indexOf(t) : -1;
                const next = list[(at + (k.shift ? -1 : 1) + list.length) % list.length];
                if (next && next.focus) next.focus();
                return;
            }
            case 'Backspace': erase(t, false); return;
            case 'Delete': erase(t, true); return;
            case ' ':
                if (role === 'button' || role === 'checkbox' || role === 'radio' || role === 'switch') { press(t); return; }
                break;
            case 'ArrowDown': case 'ArrowUp':
                if (tag === 'SELECT') {
                    const i = Math.min(Math.max(t.selectedIndex + (k.key === 'ArrowDown' ? 1 : -1), 0), t.options.length - 1);
                    if (i !== t.selectedIndex) {
                        t.selectedIndex = i;
                        t.dispatchEvent(new Event('input', { bubbles: true }));
                        t.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                }
                return;
            }
            if (k.text !== null) insert(t, k.text);
        };
        for (const k of keys) {
            const t = deepActive();
            const target = t || document.body;
            const init = { key: k.key, code: k.code, keyCode: k.keyCode, which: k.keyCode, shiftKey: k.shift,
                           ctrlKey: k.ctrl, altKey: k.alt, metaKey: k.meta, bubbles: true, cancelable: true, composed: true };
            const proceed = target.dispatchEvent(new KeyboardEvent('keydown', init));
            if (proceed && k.text !== null && !k.meta && !k.ctrl) {
                target.dispatchEvent(new KeyboardEvent('keypress', Object.assign({}, init, { charCode: k.text.charCodeAt(0) })));
            }
            if (proceed) act(t, k);
            (deepActive() || document.body).dispatchEvent(new KeyboardEvent('keyup', init));
        }
        const now = deepActive();
        return JSON.stringify({ target: now ? describe(now) : 'the page' });
        """#

    /// Arguments: `ref`, or `x` and `y`. Moves a synthetic pointer onto an
    /// element: leave events for whatever it was over, then over/enter/move.
    static let hover = prelude + #"""
        watch();
        let el = ref !== null ? refElement(ref) : deepElementFromPoint(x, y);
        if (!el) throw new Error('nothing at ' + x + ',' + y);
        if (ref !== null) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        const base = { bubbles: true, cancelable: true, composed: true, clientX: ref !== null ? r.left + r.width / 2 : x,
                       clientY: ref !== null ? r.top + r.height / 2 : y };
        const pointer = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, base);
        const quiet = Object.assign({}, base, { bubbles: false });
        const was = R.hovered && R.hovered.isConnected ? R.hovered : null;
        if (was && was !== el) {
            was.dispatchEvent(new PointerEvent('pointerout', pointer));
            was.dispatchEvent(new PointerEvent('pointerleave', Object.assign({}, pointer, { bubbles: false })));
            was.dispatchEvent(new MouseEvent('mouseout', base));
            was.dispatchEvent(new MouseEvent('mouseleave', quiet));
        }
        if (was !== el) {
            el.dispatchEvent(new PointerEvent('pointerover', pointer));
            el.dispatchEvent(new PointerEvent('pointerenter', Object.assign({}, pointer, { bubbles: false })));
            el.dispatchEvent(new MouseEvent('mouseover', base));
            el.dispatchEvent(new MouseEvent('mouseenter', quiet));
        }
        el.dispatchEvent(new PointerEvent('pointermove', pointer));
        el.dispatchEvent(new MouseEvent('mousemove', base));
        R.hovered = el;
        return JSON.stringify({ target: describe(el) });
        """#

    /// Arguments: `fromRef`/`fromX`/`fromY`, `toRef`/`toX`/`toY`, `steps`. An
    /// element that is draggable (HTML drag and drop) gets dragstart → dragover
    /// → drop → dragend with one shared DataTransfer; anything else gets a
    /// pointer drag: down, `steps` moves, up.
    static let drag = prelude + #"""
        watch();
        const at = (r, px, py) => {
            if (r !== null) {
                const el = refElement(r);
                el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
                const b = el.getBoundingClientRect();
                return { el, x: b.left + b.width / 2, y: b.top + b.height / 2 };
            }
            return { el: deepElementFromPoint(px, py), x: px, y: py };
        };
        const from = at(fromRef, fromX, fromY);
        if (!from.el) throw new Error('nothing to drag at ' + fromX + ',' + fromY);
        // Measured after the source scrolled in, so a target ref is where it
        // is now.
        const to = at(toRef, toX, toY);
        const mouse = (p, extra) => Object.assign({ bubbles: true, cancelable: true, composed: true, button: 0,
                                                    clientX: p.x, clientY: p.y }, extra || {});
        const source = from.el.closest && from.el.closest('[draggable=true]');
        if (source) {
            const dt = new DataTransfer();
            const drag = (type, el, p) => el.dispatchEvent(new DragEvent(type, mouse(p, { dataTransfer: dt })));
            if (!drag('dragstart', source, from)) {
                return JSON.stringify({ from: describe(source), to: null, html5: true, dropped: false, note: 'the page cancelled dragstart' });
            }
            const target = deepElementFromPoint(to.x, to.y) || to.el;
            drag('drag', source, to);
            drag('dragenter', target, to);
            const accepted = !drag('dragover', target, to);
            if (accepted) drag('drop', target, to);
            drag('dragend', source, to);
            return JSON.stringify({ from: describe(source), to: target ? describe(target) : null, html5: true, dropped: accepted });
        }
        // Moves and the release go to the pressed element, as pointer capture
        // sends them: what drag widgets rely on (`setPointerCapture`, which a
        // synthetic pointer cannot take, or listeners on the document, which
        // these reach by bubbling).
        const pointer = (p, extra) => Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, mouse(p, extra));
        const held = from.el;
        held.dispatchEvent(new PointerEvent('pointerdown', pointer(from, { buttons: 1 })));
        held.dispatchEvent(new MouseEvent('mousedown', mouse(from, { buttons: 1 })));
        const n = Math.max(1, steps);
        for (let i = 1; i <= n; i++) {
            const p = { x: from.x + (to.x - from.x) * i / n, y: from.y + (to.y - from.y) * i / n };
            held.dispatchEvent(new PointerEvent('pointermove', pointer(p, { buttons: 1 })));
            held.dispatchEvent(new MouseEvent('mousemove', mouse(p, { buttons: 1 })));
        }
        held.dispatchEvent(new PointerEvent('pointerup', pointer(to, { buttons: 0 })));
        held.dispatchEvent(new MouseEvent('mouseup', mouse(to, { buttons: 0 })));
        const end = deepElementFromPoint(to.x, to.y);
        return JSON.stringify({ from: describe(held), to: end ? describe(end) : null, html5: false, dropped: true });
        """#

    /// Arguments: `ref`, `values` (option values or visible texts). Chooses
    /// options of a native `<select>`; several only on a multiple one.
    static let selectOption = prelude + #"""
        watch();
        let el = refElement(ref);
        if (el.tagName !== 'SELECT') el = (el.closest && el.closest('select')) || (el.querySelector && el.querySelector('select')) || el;
        if (el.tagName !== 'SELECT') {
            throw new Error('ref ' + ref + ' is ' + describe(el) + ', not a <select>: click it to open its list, then click the option');
        }
        if (el.disabled) throw new Error('ref ' + ref + ' is disabled');
        const norm = s => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
        const options = Array.from(el.options);
        const wanted = values.map(v => {
            const option = options.find(o => o.value === v) || options.find(o => norm(o.text) === norm(v))
                || options.find(o => norm(o.text).includes(norm(v)));
            if (!option) throw new Error('no option "' + v + '"; the options are: ' + options.slice(0, 30).map(o => '"' + clean(o.text, 40) + '"').join(', '));
            return option;
        });
        if (wanted.length > 1 && !el.multiple) throw new Error('ref ' + ref + ' takes one option, not ' + wanted.length);
        if (el.multiple) for (const o of options) o.selected = wanted.includes(o);
        else el.value = wanted[0].value;
        el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return JSON.stringify({ target: describe(el), selected: options.filter(o => o.selected).map(o => clean(o.text, 100)) });
        """#

    /// Arguments: `ref`. Whether a checkbox, radio, switch or ARIA equivalent
    /// is checked; throws for anything that cannot be.
    static let checkState = prelude + #"""
        let el = refElement(ref);
        if (el.tagName === 'LABEL' && el.control) el = el.control;
        if (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio')) {
            return JSON.stringify({ target: describe(el), checked: el.checked, disabled: el.disabled });
        }
        const aria = el.getAttribute('aria-checked') ?? el.getAttribute('aria-pressed') ?? el.getAttribute('aria-selected');
        if (aria !== null) {
            return JSON.stringify({ target: describe(el), checked: aria === 'true', disabled: el.getAttribute('aria-disabled') === 'true' });
        }
        throw new Error('ref ' + ref + ' is ' + describe(el) + ', which has no checked state: click it instead');
        """#

    /// Arguments: `ref`, `files`: `[{name, type, data}]`, data base64. Puts
    /// files into a file input (the ref, one inside it, or its label's), or
    /// drops them on a drop zone. No file picker opens.
    static let upload = prelude + #"""
        watch();
        const el = refElement(ref);
        const isFile = n => n && n.tagName === 'INPUT' && n.type === 'file';
        let input = isFile(el) ? el : null;
        if (!input && el.querySelector) input = el.querySelector('input[type=file]');
        if (!input && el.closest) { const label = el.closest('label'); if (label && isFile(label.control)) input = label.control; }
        const toFile = f => {
            const bin = atob(f.data);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            return new File([bytes], f.name, { type: f.type || 'application/octet-stream', lastModified: Date.now() });
        };
        const dt = new DataTransfer();
        for (const f of files) dt.items.add(toFile(f));
        if (input) {
            if (input.disabled) throw new Error('the file field is disabled');
            if (!input.multiple && files.length > 1) throw new Error('the file field takes one file, not ' + files.length);
            input.files = dt.files;
            input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            return JSON.stringify({ target: describe(input), via: 'input', count: input.files.length });
        }
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        const init = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2,
                       clientY: r.top + r.height / 2, dataTransfer: dt };
        el.dispatchEvent(new DragEvent('dragenter', init));
        const accepted = !el.dispatchEvent(new DragEvent('dragover', init));
        el.dispatchEvent(new DragEvent('drop', init));
        return JSON.stringify({ target: describe(el), via: 'drop', count: files.length, accepted });
        """#

    /// Arguments: `text`, `gone`, `maxMs`. Waits until the page's rendered
    /// text contains `text` (or, with `gone`, no longer does).
    static let waitForText = prelude + #"""
        const needle = text.toLowerCase();
        const start = performance.now();
        const present = () => ((document.body && document.body.innerText) || '').toLowerCase().includes(needle);
        return await new Promise(resolve => {
            let done = false;
            const finish = (met, leaving) => {
                if (done) return;
                done = true;
                resolve(JSON.stringify({ met, waited: Math.round(performance.now() - start), leaving }));
            };
            addEventListener('pagehide', () => finish(false, true), { once: true });
            const check = () => {
                if (done) return;
                if (present() !== gone) finish(true, false);
                else if (performance.now() - start >= maxMs) finish(false, false);
                else setTimeout(check, 100);
            };
            check();
        });
        """#

    /// Wraps the caller's JavaScript for `RAVEPageDriver.evaluate`: run it as
    /// an expression (awaited) or, when it is statements, as an async
    /// function's body, and turn whatever it produced into JSON a model can
    /// read. Runs in the page's world. Argument: `__ravenMax`.
    static func evaluation(_ source: String, asExpression: Bool) -> String {
        let run = asExpression
            ? "const __ravenValue = await (\n\(source)\n);"
            : "const __ravenValue = await (async () => {\n\(source)\n})();"
        return #"""
            const __ravenDescribe = n => {
                if (n.nodeType !== 1) return n.nodeName.toLowerCase() + (n.nodeValue ? ' "' + n.nodeValue.trim().slice(0, 60) + '"' : '');
                const id = n.id ? '#' + n.id : '';
                const cls = typeof n.className === 'string' && n.className.trim() ? '.' + n.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
                const text = (n.innerText || n.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
                return '<' + n.tagName.toLowerCase() + id + cls + '>' + (text ? ' "' + text + '"' : '');
            };
            const __ravenJSON = (value, max) => {
                const seen = new WeakSet();
                const replacer = function (key, v) {
                    if (typeof v === 'function') return '[function ' + (v.name || 'anonymous') + ']';
                    if (typeof v === 'bigint') return v.toString() + 'n';
                    if (typeof v === 'symbol') return v.toString();
                    if (v === undefined) return '[undefined]';
                    if (v instanceof Error) return { error: v.name, message: v.message };
                    if (typeof Node !== 'undefined' && v instanceof Node) return __ravenDescribe(v);
                    if (typeof Window !== 'undefined' && v instanceof Window) return '[window]';
                    if (v instanceof Map) return { map: Array.from(v.entries()).slice(0, 200) };
                    if (v instanceof Set) return { set: Array.from(v).slice(0, 200) };
                    if (typeof NodeList !== 'undefined' && (v instanceof NodeList || v instanceof HTMLCollection)) {
                        return Array.from(v).slice(0, 200);
                    }
                    if (v !== null && typeof v === 'object') {
                        if (seen.has(v)) return '[circular]';
                        seen.add(v);
                    }
                    return v;
                };
                const type = value === null ? 'null' : Array.isArray(value) ? 'array'
                    : (typeof Node !== 'undefined' && value instanceof Node) ? 'node' : typeof value;
                let text;
                if (value === undefined) {
                    text = null;
                } else {
                    try { text = JSON.stringify(value, replacer); } catch (e) { text = JSON.stringify(String(value)); }
                    if (text === undefined) text = JSON.stringify(String(value));
                }
                const length = text === null ? 0 : text.length;
                return JSON.stringify({ type, json: text === null ? null : text.slice(0, max), length, truncated: length > max });
            };
            """# + run + "\nreturn __ravenJSON(__ravenValue, __ravenMax);"
    }
}
