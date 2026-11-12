// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+AgentInput.swift
//  NookWeb
//
//  Clicks and typing for DevMCP agents. A click is a real mouse event sent to the page's view,
//  so the page sees a trusted click at the element's centre; text goes in through the view's
//  text input, as typing does. Neither goes through the window, so the person's focus and key
//  window stay as they are. Finding elements runs in the picker's isolated world, where
//  snapshot refs live.
//
//  Keys are the exception: a native key event WebKit leaves unhandled is resent to the app's
//  key window, which is the person's, so keys are synthetic events plus their default action.
//

import AppKit
import WebKit

extension PageSession {
    /// Runs `body` as an async function in the picker's world with `__nookAgent` installed.
    public func agentScript(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let webView else { throw AgentInputError.noPage }
        do {
            return try await webView.callAsyncJavaScript(
                DevPickerScript.source + AgentInputScript.source + "\n" + body,
                arguments: arguments, in: nil, contentWorld: DevPickerScript.world)
        } catch {
            // The script's own errors say what was wrong with the target; pass them on as they are.
            let info = (error as NSError).userInfo
            if let message = info["WKJavaScriptExceptionMessage"] as? String {
                throw AgentInputError.page(message.replacingOccurrences(of: "Error: ", with: ""))
            }
            throw error
        }
    }

    /// A left click at `point`, in CSS pixels of the viewport, sent straight to the page's view.
    /// `cssWidth` is the viewport's width in CSS pixels, which scales the point for zoom.
    public func agentClick(at point: CGPoint, cssWidth: Double) throws {
        guard let view = webView, let window = view.window, cssWidth > 0 else { throw AgentInputError.noPage }
        let scale = view.bounds.width / cssWidth
        let local = CGPoint(x: point.x * scale, y: view.isFlipped ? point.y * scale : view.bounds.height - point.y * scale)
        let location = view.convert(local, to: nil)
        // Clicking a view does not make it first responder; keep it so if WebKit tries.
        let responder = window.firstResponder
        defer { if window.firstResponder !== responder { window.makeFirstResponder(responder) } }
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            switch type {
            case .mouseMoved: view.mouseMoved(with: event)
            case .leftMouseDown: view.mouseDown(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    /// Types `text` at the page's focused element, as the keyboard's text input would.
    public func agentInsertText(_ text: String) throws {
        guard let view = webView else { throw AgentInputError.noPage }
        view.insertText(text)
    }

    /// Runs an editing command such as `insertNewline:` or `deleteBackward:` on the focused element.
    public func agentEditCommand(_ selector: String) throws {
        guard let view = webView else { throw AgentInputError.noPage }
        view.doCommand(by: NSSelectorFromString(selector))
    }
}

public enum AgentInputError: LocalizedError {
    case noPage
    case page(String)
    public var errorDescription: String? {
        switch self {
        case .noPage: return "The tab has no page in a window"
        case .page(let message): return message
        }
    }
}

enum AgentInputScript {
    static let source = """
    (() => {
      if (window.__nookAgent) return;
      const P = window.__nookDevPicker;
      const CLICKABLE = 'a, button, input[type="submit"], input[type="button"], input[type="checkbox"], input[type="radio"], [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="checkbox"], [onclick], summary, label';
      function visible(el) {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
      }
      function find(spec) {
        if (spec.ref) {
          const el = P.resolve(spec.ref);
          if (!el) throw new Error('No element with ref ' + spec.ref + ' on this page. Take a new snapshot.');
          return el;
        }
        if (spec.selector) {
          const el = document.querySelector(spec.selector);
          if (!el) throw new Error('Nothing matches ' + spec.selector);
          return el;
        }
        if (spec.text) {
          const query = spec.text.trim().toLowerCase();
          let best = null, bestLength = Infinity;
          for (const el of document.querySelectorAll(spec.clickable ? CLICKABLE : '*')) {
            if (!visible(el)) continue;
            const label = (P.nameOf(el) || el.textContent || '').trim();
            const lower = label.toLowerCase();
            if (lower === query) return el;
            if (lower.includes(query) && label.length < bestLength) { best = el; bestLength = label.length; }
          }
          if (!best) throw new Error('No visible element has the text ' + JSON.stringify(spec.text));
          return best;
        }
        throw new Error('Pass ref, selector or text');
      }
      function describe(el) {
        const role = P.roleOf(el) || el.tagName.toLowerCase();
        const name = (P.nameOf(el) || '').trim().slice(0, 60);
        return role + (name ? ' "' + name + '"' : '') + ' [ref=' + P.ref(el) + ']';
      }

      // Where to click `spec`: its centre after scrolling it into view, and what covers it there.
      let clickSeen = null, clickTarget = null;
      window.addEventListener('click', e => {
        if (clickTarget && (e.target === clickTarget || clickTarget.contains(e.target))) clickSeen = { trusted: e.isTrusted };
      }, true);
      function locate(spec) {
        const el = find(Object.assign({ clickable: true }, spec));
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        const out = { element: describe(el), ref: P.ref(el), width: window.innerWidth };
        if (r.width === 0 || r.height === 0) { out.hidden = true; return out; }
        out.x = r.left + r.width / 2;
        out.y = r.top + r.height / 2;
        const hit = document.elementFromPoint(out.x, out.y);
        if (!hit || !(hit === el || el.contains(hit) || (el.control && el.control === hit) || (hit.control && hit.control === el))) {
          out.covered = hit ? describe(hit) : 'nothing (outside the viewport)';
        }
        clickSeen = null;
        clickTarget = el;
        return out;
      }
      function clickResult() { return clickSeen; }
      function scriptClick(ref) {
        const el = P.resolve(ref);
        if (!el) throw new Error('The element left the page');
        el.click();
      }

      // Focuses `spec` for typing; its contents selected unless `append`.
      function focusField(spec, append) {
        const el = find(spec);
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        const field = el.matches('input, textarea, select') || el.isContentEditable;
        if (!field) throw new Error(describe(el) + ' is not a text field');
        if (el.disabled || el.readOnly) throw new Error(describe(el) + ' is ' + (el.disabled ? 'disabled' : 'read-only'));
        el.focus();
        if (el.tagName === 'SELECT') return { element: describe(el), select: true };
        if (el.isContentEditable) {
          const range = document.createRange();
          range.selectNodeContents(el);
          if (append) range.collapse(false);
          const sel = getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        } else if (append) {
          try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
        } else {
          el.select();
        }
        return { element: describe(el), ref: P.ref(el), focused: document.activeElement === el, before: valueOf(el) };
      }
      function valueOf(el) { return el.isContentEditable ? el.innerText : el.value; }
      function fieldValue(ref) { const el = P.resolve(ref); return el ? valueOf(el) : null; }
      // When typing did not reach the field: set the value as a framework would see typing.
      function setValue(ref, value) {
        const el = P.resolve(ref);
        if (!el) throw new Error('The field left the page');
        el.focus();
        if (el.isContentEditable) {
          document.execCommand('selectAll');
          document.execCommand('insertText', false, value);
          return;
        }
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      function selectOption(ref, value) {
        const el = P.resolve(ref);
        const option = [...el.options].find(o => o.value === value || o.label.trim() === value || o.text.trim() === value);
        if (!option) throw new Error('No option ' + JSON.stringify(value) + '. Options: ' + [...el.options].map(o => o.text.trim()).join(', '));
        el.value = option.value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return option.text.trim();
      }

      // Keys: the page gets keydown, keypress and keyup events; when it does not prevent the
      // keydown, Nook performs what the key does. Native work comes back as { command } or { text }.
      const CODES = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ' ': 32, ArrowLeft: 37, ArrowUp: 38,
        ArrowRight: 39, ArrowDown: 40, Home: 36, End: 35, PageUp: 33, PageDown: 34 };
      const EDIT = { Backspace: 'deleteBackward:', Delete: 'deleteForward:', ArrowLeft: 'moveLeft:', ArrowRight: 'moveRight:',
        ArrowUp: 'moveUp:', ArrowDown: 'moveDown:', Home: 'moveToBeginningOfLine:', End: 'moveToEndOfLine:' };
      const SCROLL = { ArrowDown: [0, 40], ArrowUp: [0, -40], ArrowRight: [40, 0], ArrowLeft: [-40, 0], PageDown: [0, 0.9],
        PageUp: [0, -0.9], ' ': [0, 0.9], Home: [0, -1e9], End: [0, 1e9] };
      function keyEvent(type, target, key, mods) {
        const code = CODES[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
        const e = new KeyboardEvent(type, { key, code: key.length === 1 ? (/[a-z]/i.test(key) ? 'Key' + key.toUpperCase() : '') : key,
          keyCode: code, which: code, charCode: type === 'keypress' ? key.charCodeAt(0) : 0,
          shiftKey: mods.shift, ctrlKey: mods.control, altKey: mods.alt, metaKey: mods.meta, bubbles: true, cancelable: true, composed: true });
        return target.dispatchEvent(e);
      }
      function tabbables() {
        return [...document.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable=""], [contenteditable="true"]')]
          .filter(el => el.tabIndex >= 0 && !el.disabled && visible(el) && !(el.type === 'hidden'));
      }
      function editable(el) {
        return el && (el.isContentEditable || el.tagName === 'TEXTAREA' ||
          (el.tagName === 'INPUT' && !['checkbox', 'radio', 'submit', 'button', 'reset', 'file', 'image', 'range', 'color'].includes(el.type)));
      }
      function keyDown(spec, key, mods) {
        if (spec.ref || spec.selector) find(spec).focus();
        const target = document.activeElement || document.body;
        const proceed = keyEvent('keydown', target, key, mods);
        const printable = key.length === 1 && !mods.meta && !mods.control;
        if (proceed && (printable || key === 'Enter')) keyEvent('keypress', target, printable ? key : '\\r', mods);
        const out = { target: describe(target), prevented: !proceed };
        if (!proceed) return out;
        const tag = target.tagName;
        if (mods.meta || mods.control) {
          if (key.toLowerCase() === 'a') out.command = 'selectAll:';
          return out;
        }
        if (printable) {
          if (key === ' ' && (tag === 'BUTTON' || (tag === 'INPUT' && ['checkbox', 'radio', 'button', 'submit'].includes(target.type)))) target.click();
          else if (editable(target)) out.text = key;
          else if (key === ' ') scrollBy(0, (mods.shift ? -1 : 1) * innerHeight * 0.9);
          return out;
        }
        if (key === 'Enter') {
          if (tag === 'TEXTAREA' || target.isContentEditable) out.command = 'insertNewline:';
          else if (tag === 'INPUT' && target.form && editable(target)) target.form.requestSubmit();
          else if (tag === 'A' || tag === 'BUTTON' || tag === 'SUMMARY' || (tag === 'INPUT' && ['submit', 'button', 'checkbox', 'radio'].includes(target.type))) target.click();
          return out;
        }
        if (key === 'Tab') {
          const all = tabbables();
          const at = all.indexOf(target);
          const next = all[(at + (mods.shift ? -1 : 1) + all.length + (at < 0 && mods.shift ? 1 : 0)) % all.length];
          if (next) { next.focus(); out.focused = describe(next); }
          return out;
        }
        if (editable(target) && EDIT[key]) { out.command = EDIT[key]; return out; }
        const scroll = SCROLL[key];
        if (scroll) {
          const [dx, dy] = scroll;
          scrollBy(Math.abs(dx) < 1 ? dx * innerWidth : dx, Math.abs(dy) < 1 ? dy * innerHeight : dy);
        }
        return out;
      }
      function keyUp(key, mods) { keyEvent('keyup', document.activeElement || document.body, key, mods); }

      window.__nookAgent = { find, describe, locate, clickResult, scriptClick, focusField, fieldValue, setValue, selectOption, keyDown, keyUp };
    })();
    """
}
