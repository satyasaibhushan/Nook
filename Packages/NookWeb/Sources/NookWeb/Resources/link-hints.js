// Nook Link Hints
// Press Option+F to label everything clickable in view; type a label to click it. Escape or any other key cancels. Runs in every frame, each for its own content.
(function () {
    if (window.__nookLinkHints) return;
    window.__nookLinkHints = true;

    // Easiest keys first. One-key labels are dealt from the front; when a page has more
    // targets than keys, the keys at the back become the first key of two-key labels.
    const ALPHABET = "asdfjklghewruiocvmn1234567890tybpqxz";
    const CLICKABLE = [
        "a[href]", "button", "input:not([type=hidden])", "textarea", "select", "summary",
        "label[for]", "[onclick]", "[contenteditable=''],[contenteditable=true]",
        "[role=button]", "[role=link]", "[role=tab]", "[role=menuitem]", "[role=option]",
        "[role=checkbox]", "[role=radio]", "[role=switch]", "[role=textbox]",
        "[tabindex]:not([tabindex='-1'])",
    ].join(",");

    let hints = null; // [{ label, element, chip }] while labels are showing
    let typed = "";
    let host = null;

    function isEditable(element) {
        if (!element || !element.tagName) return false;
        const tag = element.tagName;
        if (tag === "TEXTAREA" || tag === "SELECT" || element.isContentEditable) return true;
        if (tag === "INPUT") {
            return !["button", "checkbox", "radio", "submit", "reset", "image", "file", "range", "color"]
                .includes(element.type);
        }
        return element.getAttribute("role") === "textbox";
    }

    function collect(root, out) {
        for (const element of root.querySelectorAll(CLICKABLE)) out.push(element);
        // Open shadow roots hold most of the buttons on component-built pages.
        for (const element of root.querySelectorAll("*")) {
            if (element.shadowRoot) collect(element.shadowRoot, out);
        }
    }

    function visibleRect(element) {
        for (const rect of element.getClientRects()) {
            if (rect.width < 3 || rect.height < 3) continue;
            if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= innerHeight || rect.left >= innerWidth) continue;
            const style = getComputedStyle(element);
            if (style.visibility !== "visible" || style.pointerEvents === "none" || Number(style.opacity) === 0) return null;
            // Something else on top (a closed menu's items, content under a dialog) is not clickable.
            const x = Math.min(Math.max(rect.left + Math.min(rect.width / 2, 8), 0), innerWidth - 1);
            const y = Math.min(Math.max(rect.top + rect.height / 2, 0), innerHeight - 1);
            let top = document.elementFromPoint(x, y);
            while (top && top.shadowRoot) {
                const inner = top.shadowRoot.elementFromPoint(x, y);
                if (!inner || inner === top) break;
                top = inner;
            }
            if (top && (element.contains(top) || top.contains(element) || shadowContains(element, top))) return rect;
            return null;
        }
        return null;
    }

    function shadowContains(element, node) {
        for (let current = node; current; current = current.parentNode || current.host) {
            if (current === element) return true;
        }
        return false;
    }

    // As many one-key labels as the count allows, in page order, and no label that is the
    // start of another, so a click fires on the last key without waiting.
    function labels(count) {
        const size = ALPHABET.length;
        let prefixes = 0;
        while (size - prefixes + prefixes * size < count && prefixes < size) prefixes++;
        const out = [];
        for (let index = 0; index < size - prefixes && out.length < count; index++) out.push(ALPHABET[index]);
        for (let first = size - prefixes; first < size; first++) {
            for (let second = 0; second < size && out.length < count; second++) {
                out.push(ALPHABET[first] + ALPHABET[second]);
            }
        }
        return out;
    }

    function show() {
        const found = [];
        collect(document, found);
        const seen = new Set();
        const targets = [];
        for (const element of found) {
            if (seen.has(element)) continue;
            seen.add(element);
            const rect = visibleRect(element);
            if (rect) targets.push({ element, rect });
        }
        if (targets.length === 0) return;

        host = document.createElement("div");
        host.style.cssText = "all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647";
        const shadow = host.attachShadow({ mode: "closed" });
        const style = document.createElement("style");
        style.textContent =
            ".chip{position:fixed;font:700 11px/1 ui-monospace,SFMono-Regular,Menlo,monospace;" +
            "letter-spacing:.04em;text-transform:uppercase;color:#1d1a05;background:#ffd84d;" +
            "border:1px solid #b8860b;border-radius:3px;padding:2px 3px;box-shadow:0 1px 3px rgba(0,0,0,.35)}" +
            ".chip b{font-weight:700;opacity:.35}";
        shadow.appendChild(style);

        const names = labels(targets.length);
        // Beyond every two-key label there is nothing left to type; the page's tail goes unlabelled.
        targets.length = names.length;
        hints = targets.map(({ element, rect }, index) => {
            const chip = document.createElement("span");
            chip.className = "chip";
            chip.style.left = Math.max(rect.left, 0) + "px";
            chip.style.top = Math.max(rect.top, 0) + "px";
            chip.textContent = names[index];
            shadow.appendChild(chip);
            return { label: names[index], element, chip };
        });
        typed = "";
        document.documentElement.appendChild(host);
        addEventListener("scroll", hide, true);
        addEventListener("resize", hide, true);
        addEventListener("blur", hide, true);
        addEventListener("mousedown", hide, true);
    }

    function hide() {
        if (!hints) return;
        hints = null;
        host.remove();
        host = null;
        removeEventListener("scroll", hide, true);
        removeEventListener("resize", hide, true);
        removeEventListener("blur", hide, true);
        removeEventListener("mousedown", hide, true);
    }

    function narrow() {
        const matching = hints.filter((hint) => hint.label.startsWith(typed));
        if (matching.length === 0) return hide();
        if (matching.length === 1 && matching[0].label === typed) {
            const element = matching[0].element;
            hide();
            return activate(element);
        }
        for (const hint of hints) {
            const on = hint.label.startsWith(typed);
            hint.chip.style.display = on ? "" : "none";
            if (on) {
                hint.chip.innerHTML = "";
                const done = document.createElement("b");
                done.textContent = typed;
                hint.chip.append(done, hint.label.slice(typed.length));
            }
        }
    }

    function activate(element) {
        if (isEditable(element)) {
            element.focus();
            return;
        }
        // Pages that listen for the press, not the click, need the whole sequence.
        const rect = element.getBoundingClientRect();
        const at = { bubbles: true, cancelable: true, composed: true, view: window,
                     clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
        element.dispatchEvent(new PointerEvent("pointerdown", at));
        element.dispatchEvent(new MouseEvent("mousedown", at));
        element.focus({ preventScroll: true });
        element.dispatchEvent(new PointerEvent("pointerup", at));
        element.dispatchEvent(new MouseEvent("mouseup", at));
        element.click();
    }

    function swallow(event) {
        event.preventDefault();
        event.stopImmediatePropagation();
    }

    addEventListener("keydown", function (event) {
        if (!event.isTrusted) return;
        if (hints) {
            // Modifier-only presses and system shortcuts pass through untouched.
            if (["Shift", "Control", "Alt", "Meta"].includes(event.key)) return;
            if (event.metaKey || event.ctrlKey || event.altKey) return hide();
            swallow(event);
            const key = event.key.toLowerCase();
            if (key === "backspace" && typed) {
                typed = typed.slice(0, -1);
                return narrow();
            }
            if (key.length !== 1 || !ALPHABET.includes(key)) return hide();
            typed += key;
            return narrow();
        }
        // By physical key: with Option held, the character macOS reports is not "f".
        if (event.code !== "KeyF" || !event.altKey || event.metaKey || event.ctrlKey || event.shiftKey || event.repeat) return;
        swallow(event);
        show();
    }, true);

    // The page must not see the rest of a key press the labels consumed.
    for (const type of ["keypress", "keyup"]) {
        addEventListener(type, function (event) {
            if (hints && event.isTrusted && !event.metaKey && !event.ctrlKey && !event.altKey) swallow(event);
        }, true);
    }
})();
