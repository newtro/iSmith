import WebKit

/// The script the agent's browser tools run in a tab, in iSmith's own content world for agents
/// (never the page's world, so a page can't see or replace it, and its element numbers are its
/// own). It reads the page; it never changes it, except to scroll an element into view, focus a
/// field the agent is about to type in, or set a `<select>`'s value (see `select`).
///
/// Element numbers: every interactive element the snapshot lists gets a number that stays the
/// same for that element until the page is replaced (a navigation), kept in a WeakMap in this
/// world. A number whose element has left the page answers "gone".
///
/// Secrets: a password field's value is never read, and neither are one-time codes or card
/// fields; the snapshot shows them as "(hidden)".
enum AgentPageScript {
    static let world = WKContentWorld.world(name: "ismith-agent")

    /// Defines `globalThis.__ismithAgent` once per document in the agent world.
    static let library = #"""
    (() => {
    if (globalThis.__ismithAgent) return;
    const A = globalThis.__ismithAgent = {};
    let next = 1;
    const byNumber = new Map();
    const numberOf = new WeakMap();
    const number = (el) => {
      let n = numberOf.get(el);
      if (!n) { n = next++; numberOf.set(el, n); byNumber.set(n, new WeakRef(el)); }
      return n;
    };
    A.element = (n) => {
      const ref = byNumber.get(n);
      const el = ref && ref.deref();
      return el && el.isConnected ? el : null;
    };

    const ROLES = new Set(["button","link","checkbox","radio","tab","menuitem","menuitemcheckbox","menuitemradio",
      "option","switch","combobox","textbox","searchbox","slider","spinbutton","treeitem","gridcell","listbox"]);
    const SECRET_AUTOCOMPLETE = /(one-time-code|cc-number|cc-csc|cc-exp|current-password|new-password)/i;
    const SECRET_NAME = /(password|passwd|passcode|otp|one.?time|verification.?code|security.?code|cvv|cvc|card.?number|ssn)/i;

    const visible = (el) => {
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };

    const roleOf = (el) => {
      const explicit = (el.getAttribute("role") || "").trim().split(/\s+/)[0].toLowerCase();
      if (ROLES.has(explicit)) return explicit;
      const tag = el.tagName.toLowerCase();
      if (tag === "a" && el.hasAttribute("href")) return "link";
      if (tag === "button" || tag === "summary") return "button";
      if (tag === "select") return el.multiple ? "listbox" : "combobox";
      if (tag === "textarea") return "textbox";
      if (tag === "input") {
        const t = (el.type || "text").toLowerCase();
        if (t === "hidden") return null;
        if (["button","submit","reset","image"].includes(t)) return "button";
        if (t === "checkbox") return "checkbox";
        if (t === "radio") return "radio";
        if (t === "range") return "slider";
        if (t === "search") return "searchbox";
        if (t === "file") return "file";
        if (t === "color") return "color";
        return "textbox";
      }
      if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return "textbox";
      if (el.hasAttribute("onclick")) return "clickable";
      const ti = el.getAttribute("tabindex");
      if (ti !== null && +ti >= 0 && tag !== "body" && tag !== "html") return "clickable";
      return null;
    };

    const clean = (s, max) => {
      s = String(s || "").replace(/\s+/g, " ").trim();
      return max && s.length > max ? s.slice(0, max - 1) + "…" : s;
    };

    // A field once seen as a password stays secret: a "show password" toggle that turns it into
    // a text field doesn't reveal its value to the agent.
    const wasSecret = new WeakSet();
    const isSecret = (el) => {
      if (el.tagName !== "INPUT" && el.tagName !== "TEXTAREA") return false;
      if (wasSecret.has(el)) return true;
      let secret = (el.type || "").toLowerCase() === "password"
        || SECRET_AUTOCOMPLETE.test(el.getAttribute("autocomplete") || "")
        || SECRET_NAME.test((el.name || "") + " " + (el.id || ""))
        || /^(pass|pw|pwd|pin|code|cc|cvv)$/i.test(el.name || "") || /^(pass|pw|pwd|pin|cvv)$/i.test(el.id || "");
      if (secret) wasSecret.add(el);
      return secret;
    };
    /// Whether a password, code or card field on the page (or a same-site frame) holds a value:
    /// screenshots are refused then, since they'd show what a "show password" toggle reveals.
    A.secretFilled = () => {
      const docs = [document];
      for (const f of document.querySelectorAll("iframe")) { try { if (f.contentDocument) docs.push(f.contentDocument); } catch (_) {} }
      if (docs.some((d) => Array.from(d.querySelectorAll("input, textarea")).some((i) => isSecret(i) && i.value))) return true;
      const sensitive = /(^|\.)(stripe\.com|stripe\.network|braintreegateway\.com|braintree-api\.com|paypal\.com|paypalobjects\.com|adyen\.com|checkout\.com|squareup\.com|square\.site|recurly\.com|chargebee\.com|authorize\.net|klarna\.com|affirm\.com|google\.com|microsoftonline\.com|live\.com|apple\.com|okta\.com|auth0\.com)$/i;
      return Array.from(document.querySelectorAll("iframe")).some((f) => {
        if (!visible(f)) return false;
        try { return sensitive.test(new URL(f.src, location.href).hostname) && new URL(f.src, location.href).origin !== location.origin; } catch (_) { return false; }
      });
    };

    const nameOf = (el) => {
      const aria = el.getAttribute("aria-label");
      if (aria && aria.trim()) return clean(aria, 120);
      const by = el.getAttribute("aria-labelledby");
      if (by) {
        const text = by.split(/\s+/).map((id) => { const l = el.ownerDocument.getElementById(id); return l ? l.innerText || l.textContent : ""; }).join(" ");
        if (clean(text)) return clean(text, 120);
      }
      if (el.labels && el.labels.length) {
        const text = Array.from(el.labels).map((l) => l.innerText || l.textContent).join(" ");
        if (clean(text)) return clean(text, 120);
      }
      const tag = el.tagName;
      if (tag === "INPUT" && ["submit","button","reset"].includes((el.type || "").toLowerCase()) && el.value) return clean(el.value, 120);
      if (tag === "IMG" || (tag === "INPUT" && el.type === "image")) return clean(el.alt || el.title, 120);
      const inner = clean(el.innerText || el.textContent, 120);
      if (inner) return inner;
      const img = el.querySelector && el.querySelector("img[alt], svg[aria-label], [title]");
      if (img) return clean(img.getAttribute("alt") || img.getAttribute("aria-label") || img.getAttribute("title"), 120);
      return clean(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name"), 120);
    };

    /// What clicking (or pressing Return on) an element would do, for "Confirm submits":
    /// "delete", "purchase", "send", "submit" or null. Heuristic; see AGENT_PANEL.md.
    const intentOf = (el) => {
      if (!el) return null;
      const target = el.closest("button, a, input, [role=button], [role=link], [role=menuitem], summary") || el;
      const words = [nameOf(target), target.getAttribute("title"), target.getAttribute("aria-label"),
        target.getAttribute("data-action"), target.id, target.getAttribute("name"),
        typeof target.className === "string" ? target.className : ""].join(" ").toLowerCase().replace(/[_-]+/g, " ");
      if (/\b(delete|remove|discard|trash|destroy|erase|unsubscribe|deactivate|close account|archive|revoke|uninstall)\b/.test(words)) return "delete";
      if (/\b(pay|buy|purchase|checkout|check out|place order|order now|complete order|donate|transfer|subscribe)\b/.test(words)) return "purchase";
      if (/\b(send|reply|forward|post|publish|tweet|share|comment|submit|confirm|approve|reject|merge|sign|accept|invite)\b/.test(words)) return "send";
      const tag = target.tagName;
      const type = (target.getAttribute("type") || "").toLowerCase();
      const form = target.form || target.closest("form");
      if (form && ((tag === "BUTTON" && (type === "" || type === "submit")) || (tag === "INPUT" && (type === "submit" || type === "image")))) return "submit";
      if (tag === "A") {
        const href = (target.getAttribute("href") || "").toLowerCase();
        if (/(delete|remove|destroy|unsubscribe)/.test(href)) return "delete";
      }
      return null;
    };

    /// What pressing a key on the focused element would do.
    A.keyIntent = (key, modifiers) => {
      const el = document.activeElement;
      if (!el || el === document.body) return null;
      const enter = key === "Enter";
      const editing = el.tagName === "TEXTAREA" || el.isContentEditable
        || (el.tagName === "INPUT" && !["button", "submit", "reset", "image", "checkbox", "radio", "file", "color", "range"].includes((el.type || "").toLowerCase()));
      // Focus inside a frame, a shadow root or a custom element: what a key does there can't be
      // seen from here.
      if (el.tagName === "IFRAME" || el.tagName === "FRAME" || el.shadowRoot || el.tagName.includes("-")) {
        return enter || key === " " || key === "Space" || key === "Delete" || key === "Backspace" || key.length === 1 ? "unknown" : null;
      }
      if (!editing) {
        // Outside a text field, Delete removes the selected item (a mail, a file) and a single
        // letter or digit is a web app's shortcut (e to archive, # to delete).
        if (key === "Delete" || key === "Backspace") return "delete";
        if (key.length === 1 && key !== " ") return "unknown";
      }
      if (!enter && key !== " " && key !== "Space") return null;
      const role = (el.getAttribute("role") || "").toLowerCase();
      const type = (el.type || "").toLowerCase();
      if (el.tagName === "BUTTON" || el.tagName === "A" || el.tagName === "SUMMARY"
          || ["button", "link", "menuitem", "option", "tab", "menuitemcheckbox", "menuitemradio"].includes(role)
          || (el.tagName === "INPUT" && ["submit", "image", "button", "reset"].includes(type))) {
        return intentOf(el) || (el.tagName === "INPUT" && (type === "submit" || type === "image") ? "submit" : null);
      }
      if (!enter) return null;
      if (el.tagName === "INPUT") {
        // A field in a form submits it; one without a form is often a chat or search box that
        // sends on Return.
        return el.form ? "submit" : "send";
      }
      // Return in a message box (Teams, Slack, Outlook) usually sends it.
      if (el.tagName === "TEXTAREA" || el.isContentEditable) {
        if ((modifiers || []).includes("shift")) return null;
        return "send";
      }
      return null;
    };

    const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TR|UL|BR|TD|TH|DETAILS|SUMMARY|DIALOG)$/;
    const SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|CANVAS|IFRAME|OBJECT|EMBED|HEAD|META|LINK)$/;

    const describe = (el, role) => {
      const n = number(el);
      let line = `[${n}] ${role}`;
      const name = nameOf(el);
      if (name) line += ` "${name.replace(/"/g, "'")}"`;
      if (role === "link") {
        const href = el.getAttribute("href") || "";
        if (href && !href.startsWith("javascript:")) line += ` -> ${clean(href, 100)}`;
      }
      const tag = el.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA") {
        const type = (el.type || "text").toLowerCase();
        if (isSecret(el)) line += ` (${type === "password" ? "password" : "secret"} field, value hidden)`;
        else if (!["checkbox","radio","submit","button","reset","image","file"].includes(type)) {
          line += ` value="${clean(el.value, 200).replace(/"/g, "'")}"`;
          if (type !== "text" && type !== "textarea") line += ` type=${type}`;
        }
      } else if (tag === "SELECT") {
        const opts = Array.from(el.options).slice(0, 30).map((o) => (o.selected ? "*" : "") + clean(o.label || o.text, 60));
        line += ` options=[${opts.join(" | ")}${el.options.length > 30 ? " | …" : ""}]`;
      } else if (el.isContentEditable) {
        line += ` value="${clean(el.innerText, 200).replace(/"/g, "'")}"`;
      }
      const states = [];
      if (el.checked || el.getAttribute("aria-checked") === "true") states.push("checked");
      if (el.disabled || el.getAttribute("aria-disabled") === "true") states.push("disabled");
      if (el.getAttribute("aria-expanded") === "true") states.push("expanded");
      if (el.getAttribute("aria-expanded") === "false") states.push("collapsed");
      if (el.getAttribute("aria-selected") === "true" || el.getAttribute("aria-current")) states.push("selected");
      if (el.required || el.getAttribute("aria-required") === "true") states.push("required");
      if (el.readOnly) states.push("read-only");
      if (el === el.ownerDocument.activeElement) states.push("focused");
      if (states.length) line += ` (${states.join(", ")})`;
      return line;
    };

    /// The page as text with numbered interactive elements, in reading order.
    A.snapshot = (maxChars) => {
      const out = [];
      let size = 0, count = 0, truncated = false, frames = 0;
      let line = "";
      const flush = () => {
        const t = line.replace(/\s+/g, " ").trim();
        line = "";
        if (!t) return;
        if (size + t.length > maxChars) { truncated = true; return; }
        out.push(t); size += t.length + 1;
      };
      const emit = (t) => { flush(); if (size + t.length > maxChars) { truncated = true; return; } out.push(t); size += t.length + 1; };
      const walk = (node, depth) => {
        if (truncated || depth > 200) return;
        if (node.nodeType === 3) { line += node.nodeValue; return; }
        if (node.nodeType !== 1) return;
        const el = node;
        if (SKIP.test(el.tagName)) {
          if (el.tagName === "IFRAME") {
            let doc = null;
            try { doc = el.contentDocument; } catch (_) {}
            if (doc && doc.body && visible(el)) { flush(); frames++; walk(doc.body, depth + 1); flush(); }
            else if (visible(el)) emit(`(embedded frame from another site: ${clean(el.src, 80)})`);
          }
          return;
        }
        if (el.getAttribute("aria-hidden") === "true") return;
        const style = el.ownerDocument.defaultView.getComputedStyle(el);
        if (style.display === "none") return;
        if (style.visibility === "hidden" && !el.children.length) return;
        const role = roleOf(el) || (style.cursor === "pointer" && el.tagName !== "LABEL" && !el.closest("a, button, [role=button], [onclick]") && el.children.length < 4 && clean(el.innerText, 80) ? "clickable" : null);
        if (role && visible(el)) {
          count++;
          emit(describe(el, role));
          // A container that's also clickable (a card, a list) still shows what's inside it.
          const container = (role === "clickable" || role === "listbox" || role === "gridcell" || role === "treeitem")
            && el.tagName !== "SELECT"
            && ((el.innerText || "").length > 150 || el.querySelector("a[href], button, input, select, textarea, [role=button], [role=link], [role=option]"));
          if (!container) return;
        }
        const tag = el.tagName;
        if (/^H[1-6]$/.test(tag)) { flush(); line = "#".repeat(+tag[1]) + " "; }
        else if (BLOCK.test(tag)) flush();
        if (tag === "IMG" && el.alt && visible(el)) line += ` [image: ${clean(el.alt, 80)}] `;
        for (const child of el.childNodes) walk(child, depth + 1);
        if (el.shadowRoot) for (const child of el.shadowRoot.childNodes) walk(child, depth + 1);
        if (BLOCK.test(tag) || /^H[1-6]$/.test(tag)) flush();
        else if (style.display.startsWith("block") || style.display === "flex" || style.display === "grid" || style.display === "list-item") flush();
      };
      walk(document.body || document.documentElement, 0);
      flush();
      return JSON.stringify({
        url: location.href, title: document.title, text: out.join("\n"), elements: count, truncated,
        scrollY: Math.round(scrollY), scrollHeight: Math.round(document.documentElement.scrollHeight),
        viewportHeight: innerHeight, viewportWidth: innerWidth, signIn: A.signIn(),
      });
    };

    /// Where an element is, scrolled into view: its center in viewport CSS pixels, and whether a
    /// click there reaches it (or something covers it).
    A.locate = (n) => {
      const el = A.element(n);
      if (!el) return JSON.stringify({ error: "gone" });
      el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
      let x = 0, y = 0;
      let r = el.getBoundingClientRect();
      // An element in a same-site frame: add the frames' offsets.
      for (let w = el.ownerDocument.defaultView; w && w.frameElement; w = w.parent) {
        const f = w.frameElement.getBoundingClientRect();
        x += f.left + w.frameElement.clientLeft; y += f.top + w.frameElement.clientTop;
      }
      if (r.width <= 0 || r.height <= 0) return JSON.stringify({ error: "hidden" });
      const points = [[0.5, 0.5], [0.25, 0.5], [0.75, 0.5], [0.5, 0.25], [0.5, 0.75]];
      let covered = null;
      for (const [fx, fy] of points) {
        const px = r.left + r.width * fx, py = r.top + r.height * fy;
        const hit = el.ownerDocument.elementFromPoint(px, py);
        if (hit && (hit === el || el.contains(hit) || hit.contains(el) && hit.tagName === "LABEL")) {
          return JSON.stringify({ x: x + px, y: y + py, role: roleOf(el), name: nameOf(el), intent: intentOf(el),
            tag: el.tagName.toLowerCase(), type: (el.type || "").toLowerCase(), secret: isSecret(el),
            editable: el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable });
        }
        if (hit && !covered) covered = hit;
      }
      return JSON.stringify({ error: "covered", by: covered ? (nameOf(covered) || covered.tagName.toLowerCase()) : "something",
        x: x + r.left + r.width / 2, y: y + r.top + r.height / 2, role: roleOf(el), name: nameOf(el), intent: intentOf(el) });
    };

    /// What's at a point (click_at): the nearest interactive element and what clicking it would do.
    A.at = (px, py) => {
      const hit = document.elementFromPoint(px, py);
      if (!hit) return JSON.stringify({ error: "nothing" });
      let el = hit;
      while (el && el !== document.body && !roleOf(el)) el = el.parentElement;
      const target = el && el !== document.body ? el : hit;
      // A frame (often another site's: a payment button) or a shadow host hides what's under the
      // point, so a click there counts as one that may submit.
      const opaque = hit.tagName === "IFRAME" || hit.tagName === "FRAME" || hit.tagName === "OBJECT" || hit.tagName === "EMBED"
        || !!hit.shadowRoot || hit.tagName.includes("-");
      return JSON.stringify({ role: roleOf(target) || target.tagName.toLowerCase(), name: nameOf(target),
        intent: intentOf(target) || (opaque ? "unknown" : null),
        tag: target.tagName.toLowerCase(), type: (target.type || "").toLowerCase() });
    };

    /// Selects the text of a field (so typing replaces it), or puts the caret at its end.
    A.prepareTyping = (n, clear) => {
      const el = A.element(n);
      if (!el) return JSON.stringify({ error: "gone" });
      const active = el.ownerDocument.activeElement;
      if (active !== el && !el.contains(active)) el.focus();
      if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
        try { if (clear) el.select(); else { const end = el.value.length; el.setSelectionRange(end, end); } } catch (_) { if (clear) el.select(); }
      } else if (el.isContentEditable) {
        const sel = el.ownerDocument.getSelection();
        const range = el.ownerDocument.createRange();
        range.selectNodeContents(el);
        if (!clear) range.collapse(false);
        sel.removeAllRanges(); sel.addRange(range);
      }
      const focused = el.ownerDocument.activeElement;
      return JSON.stringify({ focused: focused === el || el.contains(focused) });
    };

    /// Sets a <select>'s value (by option text or value). WebKit shows <select> as a native menu,
    /// which can't be driven without taking over the screen, so this is the one input that goes
    /// through the DOM; it fires input and change as a user's pick does.
    A.select = (n, wanted) => {
      const el = A.element(n);
      if (!el) return JSON.stringify({ error: "gone" });
      if (el.tagName !== "SELECT") return JSON.stringify({ error: "not a select" });
      const w = String(wanted).trim().toLowerCase();
      const opts = Array.from(el.options);
      const match = opts.find((o) => o.value.toLowerCase() === w || clean(o.label || o.text).toLowerCase() === w)
        || opts.find((o) => clean(o.label || o.text).toLowerCase().includes(w));
      if (!match) return JSON.stringify({ error: "no option", options: opts.slice(0, 30).map((o) => clean(o.label || o.text, 60)) });
      el.focus();
      el.value = match.value;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      return JSON.stringify({ selected: clean(match.label || match.text, 80) });
    };

    A.scroll = (n, dx, dy) => {
      if (n) {
        const el = A.element(n);
        if (!el) return JSON.stringify({ error: "gone" });
        el.scrollIntoView({ block: "center", behavior: "instant" });
      } else {
        scrollBy({ left: dx, top: dy, behavior: "instant" });
      }
      return JSON.stringify({ scrollY: Math.round(scrollY), scrollHeight: Math.round(document.documentElement.scrollHeight), viewportHeight: innerHeight });
    };

    A.findText = (query, limit) => {
      const q = String(query).toLowerCase();
      const text = (document.body ? document.body.innerText : "") || "";
      const lower = text.toLowerCase();
      const hits = [];
      let i = lower.indexOf(q);
      while (i >= 0 && hits.length < limit) {
        hits.push(clean(text.slice(Math.max(0, i - 80), i + q.length + 80), 240));
        i = lower.indexOf(q, i + q.length);
      }
      return JSON.stringify({ count: hits.length, hits });
    };

    A.hasText = (query) => ((document.body && document.body.innerText) || "").toLowerCase().includes(String(query).toLowerCase());

    /// A sign-in or two-step page: a visible password or one-time-code field, or a known sign-in
    /// provider's page. The agent never signs in; the user does (the hand-off).
    A.signIn = () => {
      const host = location.hostname.toLowerCase();
      const path = location.pathname.toLowerCase();
      const fields = Array.from(document.querySelectorAll("input")).filter((i) => visible(i));
      for (const i of document.querySelectorAll("input")) isSecret(i);
      if (fields.some((i) => (i.type || "").toLowerCase() === "password")) return "password";
      if (fields.some((i) => /one-time-code/i.test(i.getAttribute("autocomplete") || "")
          || /(otp|one.?time|verification.?code|security.?code|2fa|mfa|totp|passcode|auth.?code|two.?factor)/i.test((i.name || "") + " " + (i.id || "") + " " + (i.getAttribute("aria-label") || "")))) return "two-step";
      const providers = [/^login\.microsoftonline\.com$/, /^login\.live\.com$/, /^login\.windows\.net$/, /^accounts\.google\.com$/,
        /^appleid\.apple\.com$/, /(^|\.)okta\.com$/, /(^|\.)okta-emea\.com$/, /(^|\.)auth0\.com$/, /(^|\.)onelogin\.com$/,
        /^login\.salesforce\.com$/, /^signin\.aws\.amazon\.com$/, /^(.+\.)?awsapps\.com$/, /^login\.yahoo\.com$/, /^id\.atlassian\.com$/];
      if (providers.some((p) => p.test(host))) return "provider";
      if (host === "github.com" && /^\/(login|session|sessions\/two-factor)/.test(path)) return "provider";
      return null;
    };
    })();
    """#

    /// Runs `body` (JavaScript returning a value) after making sure the library is defined, in
    /// the agent world of the main frame.
    @MainActor
    static func run(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(library + "\n" + body, arguments: arguments, in: nil, contentWorld: world)
    }

    /// Like `run`, for the library's functions that answer with JSON text.
    @MainActor
    static func json(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> [String: Any] {
        let value = try await run(body, arguments: arguments, in: webView)
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
