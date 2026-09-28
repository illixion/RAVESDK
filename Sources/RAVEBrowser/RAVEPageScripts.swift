//
//  RAVEPageScripts.swift
//  RAVEBrowser
//
//  The JavaScript `RAVEPageDriver` runs, as `callAsyncJavaScript` function
//  bodies. Each is `prelude` + its own body, runs in the driver's isolated
//  content world (so the page can neither see nor redefine what it uses),
//  reads its arguments as local variables, and returns a JSON string that
//  one of RAVEPageModel's types decodes.
//
//  Element refs live in that world's global, `__rave.refs`. A navigation
//  brings a fresh document and so a fresh global, which is what makes a ref
//  from the previous page fail loudly rather than hit something else.
//
//  Kept site-agnostic on purpose: no selectors for any one site. Open shadow
//  roots are walked, since component-built sites (new Reddit among them)
//  keep their controls in them.
//

enum RAVEPageScripts {

    /// Shared helpers, prepended to every script.
    static let prelude = #"""
        const R = globalThis.__rave || (globalThis.__rave = { refs: [] });
        const clean = (s, n) => (s || '').replace(/\s+/g, ' ').trim().slice(0, n || 100);
        const composedParent = n => n.parentElement || (n.parentNode && n.parentNode.host) || null;
        const composedContains = (outer, n) => { for (let c = n; c; c = composedParent(c)) if (c === outer) return true; return false; };
        const deepElementFromPoint = (x, y) => {
            let el = document.elementFromPoint(x, y);
            while (el && el.shadowRoot) {
                const inner = el.shadowRoot.elementFromPoint(x, y);
                if (!inner || inner === el) break;
                el = inner;
            }
            return el;
        };
        // Every element, including those inside open shadow roots.
        const allElements = function* (root) {
            for (const el of root.querySelectorAll('*')) {
                yield el;
                if (el.shadowRoot) yield* allElements(el.shadowRoot);
            }
        };
        const viewport = () => {
            const s = document.scrollingElement || document.documentElement;
            return { width: innerWidth, height: innerHeight, scrollX: s.scrollLeft, scrollY: s.scrollTop,
                     scrollWidth: s.scrollWidth, scrollHeight: s.scrollHeight };
        };
        const SELECTOR = [
            'a[href]', 'button', 'input:not([type=hidden])', 'textarea', 'select', 'summary',
            '[role=button]', '[role=link]', '[role=tab]', '[role=menuitem]', '[role=checkbox]',
            '[role=radio]', '[role=switch]', '[role=option]', '[role=combobox]', '[role=textbox]',
            '[contenteditable=""]', '[contenteditable=true]', '[onclick]', '[tabindex]:not([tabindex="-1"])'
        ].join(',');
        const candidates = () => {
            const found = [], seen = new Set();
            (function walk(root) {
                for (const el of root.querySelectorAll(SELECTOR)) if (!seen.has(el)) { seen.add(el); found.push(el); }
                for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot);
            })(document);
            return found;
        };
        // A ref whose element has gone is looked for again by what it was:
        // feeds and other client-rendered pages replace their nodes between
        // one listing and the next action, with the same link and label.
        const refElement = ref => {
            const el = R.refs[ref];
            if (el && el.isConnected) return el;
            const was = R.meta && R.meta[ref];
            if (was) {
                const again = candidates().find(c => was.href ? c.href === was.href && roleOf(c) === was.role
                                                             : roleOf(c) === was.role && nameOf(c) === was.name);
                if (again) { R.refs[ref] = again; return again; }
            }
            throw new Error('ref ' + ref + ' is gone from the page: use a number from the current list');
        };
        const roleOf = el => {
            const explicit = el.getAttribute('role');
            if (explicit) return explicit.split(' ')[0];
            const tag = el.tagName.toLowerCase();
            if (tag === 'a') return 'link';
            if (tag === 'button' || tag === 'summary') return 'button';
            if (tag === 'select') return 'combobox';
            if (tag === 'textarea') return 'textbox';
            if (tag === 'input') {
                const type = (el.type || 'text').toLowerCase();
                return ({ checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
                          image: 'button', range: 'slider', search: 'searchbox' })[type] || 'textbox';
            }
            if (el.isContentEditable) return 'textbox';
            return 'clickable';
        };
        const nameOf = el => {
            const aria = el.getAttribute('aria-label');
            if (aria && aria.trim()) return clean(aria);
            const labelledBy = el.getAttribute('aria-labelledby');
            if (labelledBy) {
                const root = el.getRootNode();
                const text = labelledBy.split(/\s+/).map(id => {
                    const n = root.getElementById ? root.getElementById(id) : document.getElementById(id);
                    return n ? (n.innerText || n.textContent) : '';
                }).join(' ');
                if (text.trim()) return clean(text);
            }
            if (el.labels && el.labels.length) {
                const text = Array.from(el.labels).map(l => l.innerText).join(' ');
                if (text.trim()) return clean(text);
            }
            const tag = el.tagName;
            if (tag !== 'INPUT' && tag !== 'TEXTAREA' && tag !== 'SELECT') {
                const text = el.innerText || el.textContent;
                if (text && text.trim()) return clean(text);
            }
            const img = el.querySelector && el.querySelector('img[alt]');
            if (img && img.alt.trim()) return clean(img.alt);
            for (const attr of ['placeholder', 'title', 'alt', 'name']) {
                const v = el.getAttribute(attr);
                if (v && v.trim()) return clean(v);
            }
            if (tag === 'INPUT' && /^(submit|button|reset)$/i.test(el.type) && el.value) return clean(el.value);
            return '';
        };
        const describe = el => {
            const name = nameOf(el);
            return roleOf(el) + (name ? ' "' + name + '"' : ' <' + el.tagName.toLowerCase() + '>');
        };
        """#

    /// Arguments: `scope` ("viewport" | "page"), `limit`.
    static let elements = prelude + #"""
        const vw = innerWidth, vh = innerHeight;
        const onlyViewport = scope !== 'page';

        const shown = (el, r) => {
            if (r.width < 2 || r.height < 2) return false;
            const cs = getComputedStyle(el);
            return cs.visibility !== 'hidden' && cs.display !== 'none' && parseFloat(cs.opacity) !== 0;
        };
        const inViewport = r => r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw;
        // What is actually on top: an overlay hides what is under it, which
        // is exactly what a model should be told. Five points, not just the
        // centre, because feeds lay a transparent link over each card and
        // the card's own content over parts of that link — hit-testing the
        // centre alone loses the link, and with it the post.
        const unobscured = (el, r) => {
            const left = Math.max(r.left, 0), right = Math.min(r.right, vw - 1);
            const top = Math.max(r.top, 0), bottom = Math.min(r.bottom, vh - 1);
            const points = [[0.5, 0.5], [0.15, 0.15], [0.85, 0.15], [0.15, 0.85], [0.85, 0.85]];
            return points.some(([fx, fy]) => {
                const hit = deepElementFromPoint(left + (right - left) * fx, top + (bottom - top) * fy);
                return !!hit && (composedContains(el, hit) || composedContains(hit, el));
            });
        };
        const clickableRoles = new Set(['link', 'button']);

        const kept = [];
        const keptSet = new Set();
        for (const el of candidates()) {
            if (el.closest && el.closest('[aria-hidden=true], [inert]')) continue;
            const r = el.getBoundingClientRect();
            if (!shown(el, r)) continue;
            if (onlyViewport && (!inViewport(r) || !unobscured(el, r))) continue;
            // A control inside a link or button is the same target twice.
            let nested = false;
            for (let a = composedParent(el), depth = 0; a && depth < 8; a = composedParent(a), depth++) {
                if (keptSet.has(a) && clickableRoles.has(roleOf(a))) { nested = true; break; }
            }
            if (nested) continue;
            kept.push({ el, r });
            keptSet.add(el);
        }
        kept.sort((a, b) => (Math.round(a.r.top) - Math.round(b.r.top)) || (a.r.left - b.r.left));

        R.refs = [];
        R.meta = [];
        const elements = [];
        for (const { el, r } of kept.slice(0, limit)) {
            const ref = elements.length + 1;
            R.refs[ref] = el;
            const item = { ref, role: roleOf(el), name: nameOf(el), tag: el.tagName.toLowerCase(),
                           x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
            if (el.href && typeof el.href === 'string') item.href = el.href;
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
                item.value = el.type === 'password' ? (el.value ? '•••' : '') : clean(el.value);
            }
            if (el.type === 'checkbox' || el.type === 'radio') item.checked = el.checked;
            else if (el.getAttribute('aria-checked')) item.checked = el.getAttribute('aria-checked') === 'true';
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') item.disabled = true;
            R.meta[ref] = { role: item.role, name: item.name, href: item.href || null };
            elements.push(item);
        }
        return JSON.stringify({ viewport: viewport(), elements, total: kept.length, truncated: kept.length > elements.length });
        """#

    /// Arguments: `ref`, or `x` and `y` in viewport CSS pixels.
    static let click = prelude + #"""
        let el = ref !== null ? refElement(ref) : deepElementFromPoint(x, y);
        if (!el) throw new Error('nothing at ' + x + ',' + y);
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const target = describe(el);
        // A web view with no UI delegate drops new-window navigations, so a
        // link that would open one is followed in place instead.
        const link = el.closest && el.closest('a[href]');
        if (link && link.target && !/^_(self|parent|top)$/i.test(link.target)) {
            location.href = link.href;
            return JSON.stringify({ target, followed: link.href });
        }
        const r = el.getBoundingClientRect();
        const init = { bubbles: true, cancelable: true, composed: true, button: 0, buttons: 1,
                       clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
        const pointer = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, init);
        el.dispatchEvent(new PointerEvent('pointerdown', pointer));
        el.dispatchEvent(new MouseEvent('mousedown', init));
        if (el.focus) el.focus({ preventScroll: true });
        el.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, pointer, { buttons: 0 })));
        el.dispatchEvent(new MouseEvent('mouseup', Object.assign({}, init, { buttons: 0 })));
        el.click();
        return JSON.stringify({ target });
        """#

    /// Arguments: `ref`, `text`, `append`, `submit`.
    static let type = prelude + #"""
        const el = refElement(ref);
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        if (el.focus) el.focus({ preventScroll: true });
        const tag = el.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA') {
            // The prototype's own setter, not `el.value =`: frameworks that
            // track a field's value (React) only notice a change they did
            // not make themselves this way.
            const proto = tag === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, append ? el.value + text : text);
            el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (tag === 'SELECT') {
            const option = Array.from(el.options).find(o => o.value === text || o.text.trim() === text);
            if (!option) throw new Error('no option "' + text + '"');
            el.value = option.value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (el.isContentEditable) {
            const selection = getSelection();
            selection.selectAllChildren(el);
            if (append) selection.collapseToEnd();
            document.execCommand('insertText', false, text);
        } else {
            throw new Error('ref ' + ref + ' is ' + describe(el) + ', not a text field');
        }
        if (submit) {
            const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
            const proceed = el.dispatchEvent(new KeyboardEvent('keydown', key));
            el.dispatchEvent(new KeyboardEvent('keypress', key));
            el.dispatchEvent(new KeyboardEvent('keyup', key));
            if (proceed && tag === 'INPUT' && el.form) {
                if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
            }
        }
        return JSON.stringify({ target: describe(el) });
        """#

    /// Arguments: `by` (viewports, negative is up), `to` ("top" | "bottom"),
    /// `ref`; the first one that is not null wins.
    static let scroll = prelude + #"""
        const doc = document.scrollingElement || document.documentElement;
        // The document when it scrolls at all; otherwise the nearest
        // scrollable ancestor of whatever is in the middle of the viewport,
        // for app-shell pages whose body never moves.
        const scroller = () => {
            if (doc.scrollHeight > innerHeight + 4) return doc;
            for (let el = deepElementFromPoint(innerWidth / 2, innerHeight / 2); el; el = composedParent(el)) {
                const cs = getComputedStyle(el);
                if (/(auto|scroll|overlay)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 4) return el;
            }
            return doc;
        };
        let s = scroller();
        const before = s.scrollTop;
        if (ref !== null) {
            refElement(ref).scrollIntoView({ block: 'center', behavior: 'instant' });
        } else if (to === 'top') {
            s.scrollTo({ top: 0, behavior: 'instant' });
        } else if (to === 'bottom') {
            s.scrollTo({ top: s.scrollHeight, behavior: 'instant' });
        } else {
            const page = s === doc ? innerHeight : s.clientHeight;
            s.scrollBy({ top: (by === null ? 0.8 : by) * page, behavior: 'instant' });
        }
        const client = s === doc ? innerHeight : s.clientHeight;
        return JSON.stringify({ moved: Math.abs(s.scrollTop - before) > 0.5, inner: s !== doc,
                                scrollY: s.scrollTop, scrollHeight: s.scrollHeight, clientHeight: client,
                                atTop: s.scrollTop <= 1, atBottom: s.scrollTop + client >= s.scrollHeight - 1 });
        """#

    /// Arguments: `text`, `index`.
    static let find = prelude + #"""
        const needle = text.toLowerCase();
        const hits = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let n; (n = walker.nextNode());) {
            const at = n.nodeValue.toLowerCase().indexOf(needle);
            if (at >= 0 && n.parentElement && n.parentElement.getClientRects().length) hits.push({ n, at });
        }
        const pick = hits.length ? Math.min(Math.max(index, 0), hits.length - 1) : -1;
        if (pick >= 0) hits[pick].n.parentElement.scrollIntoView({ block: 'center', behavior: 'instant' });
        const snippets = hits.slice(0, 10).map(({ n, at }) => {
            const v = n.nodeValue;
            return clean(v.slice(Math.max(0, at - 60), at + needle.length + 60), 200);
        });
        return JSON.stringify({ count: hits.length, index: pick, snippets });
        """#

    /// No arguments. Hides modal-looking layers and undoes scroll locks.
    /// A heuristic, and the reason it hides rather than removes: a false
    /// positive is one `display` away from coming back.
    static let dismissOverlays = prelude + #"""
        const vw = innerWidth, vh = innerHeight, area = vw * vh;
        const NAG = /cookie|consent|privacy|gdpr|subscribe|newsletter|sign ?up|log ?in|sign ?in|accept|continue|\b(open in|get|use) the app\b/i;
        const main = document.querySelector('main, article, [role=main]');
        const hidden = [];
        const hide = el => {
            el.style.setProperty('display', 'none', 'important');
            const cls = typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\s+/)[0] : '';
            hidden.push(el.tagName.toLowerCase() + cls + ' "' + clean(el.innerText, 60) + '"');
        };
        for (const el of document.querySelectorAll('dialog[open], [aria-modal=true]')) hide(el);
        // Site chrome is fixed too, and full of "Log in" and "Sign up".
        const CHROME = 'header, nav, aside, [role=banner], [role=navigation], [role=complementary]';
        for (const el of allElements(document.body)) {
            const cs = getComputedStyle(el);
            if (cs.position !== 'fixed' || cs.display === 'none') continue;
            const r = el.getBoundingClientRect();
            const w = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
            const h = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
            const cover = (w * h) / area;
            // A fixed layer that holds the page's own content is the app
            // shell, not an overlay.
            if (main && composedContains(el, main)) continue;
            if (el.matches(CHROME) || el.querySelector(CHROME)) continue;
            const text = el.innerText || '';
            if (cover > 0.3 && text.length < 5000) hide(el);
            // Banners and nags sit at the bottom or in the middle; a fixed
            // strip along the top or a sidebar from under the header is
            // navigation.
            else if (cover > 0.05 && r.top > vh * 0.3 && NAG.test(text.slice(0, 2000))) hide(el);
        }
        let unlockedScroll = false;
        for (const el of [document.documentElement, document.body]) {
            const cs = getComputedStyle(el);
            if (cs.overflow === 'hidden' || cs.overflowY === 'hidden') {
                el.style.setProperty('overflow', 'auto', 'important');
                unlockedScroll = true;
            }
            if (el === document.body && cs.position === 'fixed') {
                const top = -parseFloat(el.style.top || '0') || 0;
                el.style.setProperty('position', 'static', 'important');
                el.style.removeProperty('top');
                window.scrollTo(0, top);
                unlockedScroll = true;
            }
        }
        return JSON.stringify({ hidden, unlockedScroll });
        """#

    /// No arguments.
    static let info = prelude + #"""
        return JSON.stringify({ title: document.title, url: location.href, readyState: document.readyState,
                                visibility: document.visibilityState, viewport: viewport() });
        """#

    /// Whether Readability is loaded into the world yet.
    static let hasReadability = "return typeof Readability === 'function';"

    /// Arguments: `mode` ("auto" | "reader" | "page"), `maxCharacters`.
    /// Needs Readability loaded first.
    static let read = prelude + #"""
        // Block structure as blank lines, headings as '#', list items as '- ':
        // enough shape for a model, none of the markup.
        const BLOCK = /^(P|DIV|SECTION|ARTICLE|MAIN|HEADER|FOOTER|ASIDE|BLOCKQUOTE|PRE|UL|OL|TABLE|TR|FIGURE|FIGCAPTION|H[1-6]|DL|DT|DD|HR)$/;
        const toText = root => {
            const out = [];
            (function walk(n) {
                if (n.nodeType === 3) { out.push(n.nodeValue); return; }
                if (n.nodeType !== 1) return;
                const tag = n.tagName;
                if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return;
                if (tag === 'BR') { out.push('\n'); return; }
                if (tag === 'IMG') { if (n.alt) out.push('[image: ' + n.alt + ']'); return; }
                const block = BLOCK.test(tag);
                if (block) out.push('\n\n');
                if (tag === 'LI') out.push('\n- ');
                if (/^H[1-6]$/.test(tag)) out.push('#'.repeat(+tag[1]) + ' ');
                for (const c of n.childNodes) walk(c);
                if (block) out.push('\n\n');
            })(root);
            return out.join('').split('\n').map(l => l.replace(/[ \t ]+/g, ' ').trim()).join('\n')
                .replace(/\n{3,}/g, '\n\n').trim();
        };
        const tidy = s => s.split('\n').map(l => l.replace(/[ \t ]+/g, ' ').trim()).join('\n').replace(/\n{3,}/g, '\n\n').trim();

        let result = { mode: 'page', title: document.title, url: location.href, lang: document.documentElement.lang || null };
        let text = '';
        if (mode !== 'page') {
            try {
                // Readability rewrites the document it is given; hand it a copy.
                const article = new Readability(document.cloneNode(true)).parse();
                if (article && article.content && (mode === 'reader' || (article.length || 0) > 250)) {
                    const doc = new DOMParser().parseFromString(article.content, 'text/html');
                    text = toText(doc.body);
                    result = Object.assign(result, { mode: 'reader', title: article.title || document.title,
                        byline: article.byline || null, excerpt: article.excerpt || null, siteName: article.siteName || null });
                }
            } catch (e) {
                if (mode === 'reader') throw e;
            }
        }
        if (!text) text = tidy(document.body ? document.body.innerText : '');
        result.length = text.length;
        result.truncated = text.length > maxCharacters;
        result.text = text.slice(0, maxCharacters);
        return JSON.stringify(result);
        """#
}
