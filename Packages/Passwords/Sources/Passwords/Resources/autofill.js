// iSmith password capture and autofill.
//
// Runs in iSmith's own WKContentWorld, never the page's world: its variables, its handler and its
// fill function are invisible to page scripts, and page scripts can't patch the prototypes it
// uses. It shares only the DOM with the page.
//
// It never fills anything by itself. It tells the app when a login field is focused and when a
// form is submitted; the app fills a login only when the user picks one, by calling the fill
// function below in this world and in the frame the focus came from.
//
// __HANDLER__ and __FILL__ are replaced by the app with JSON string literals.
(() => {
  "use strict";
  const HANDLER = __HANDLER__;
  const FILL = __FILL__;
  const handlers = window.webkit && window.webkit.messageHandlers;
  const handler = handlers && handlers[HANDLER];
  if (!handler || window[FILL]) return;

  // A random id for this document. Fill requests carry it back, so a frame that navigated since
  // the focus (a new document, a new id) is never filled.
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  const docID = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

  const post = (message) => {
    message.docID = docID;
    try { handler.postMessage(message); } catch (e) { /* the app went away */ }
  };

  // Fields are referred to by ids kept only in this world (no DOM attributes the page could see
  // or forge).
  const idsByField = new WeakMap();
  const fieldsByID = new Map();
  let nextID = 1;
  const fieldID = (el) => {
    let id = idsByField.get(el);
    if (!id) {
      id = "f" + nextID++;
      idsByField.set(el, id);
      fieldsByID.set(id, new WeakRef(el));
    }
    return id;
  };
  // Fields seen as type=password stay password fields when a "show password" button flips them
  // to text.
  const passwordFields = new WeakSet();

  const MAX_VALUE = 4096;
  const TEXT_TYPES = new Set(["text", "email", "tel", "username", "url", ""]);
  const USERNAME_HINT = /user|e-?mail|login|logon|account|identifier|loginfmt|signin|phone|mobile|member|customer/i;
  const NOT_USERNAME = /search|query|^q$|captcha|otp|one-?time|2fa|totp|verification|coupon|promo|zip|postal|city|address|first.?name|last.?name|company/i;
  const NEW_PASSWORD_HINT = /new|create|confirm|repeat|retype|again|verify|register|signup|sign-up/i;
  const CURRENT_PASSWORD_HINT = /current|old|existing/i;
  const SUBMIT_TEXT = /\b(log ?in|log ?on|sign ?in|sign ?on|next|continue|submit|weiter|suivant|sign ?up|register|create|join|save|change|update|reset|verify|done|go|ok|enter)\b/i;
  const NOT_SUBMIT_TEXT = /\b(show|hide|reveal|view|forgot|cancel|back|help|clear|toggle)\b|eye/i;

  const isInput = (el) => el instanceof HTMLInputElement;

  const isPasswordField = (el) => {
    if (!isInput(el)) return false;
    if (el.type === "password") { passwordFields.add(el); return true; }
    return passwordFields.has(el) && el.type === "text";
  };

  const attrText = (el) =>
    [el.name, el.id, el.getAttribute("autocomplete"), el.getAttribute("placeholder"),
     el.getAttribute("aria-label")].filter(Boolean).join(" ");

  const autocompleteTokens = (el) => (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);

  const usernameScore = (el) => {
    if (!isInput(el) || isPasswordField(el) || !TEXT_TYPES.has(el.type)) return -1;
    const ac = autocompleteTokens(el);
    if (ac.includes("one-time-code")) return -1;
    if (ac.includes("username") || ac.includes("email") || ac.includes("webauthn")) return 10;
    const text = attrText(el);
    if (NOT_USERNAME.test(text)) return -1;
    let score = 0;
    if (el.type === "email") score += 4;
    if (USERNAME_HINT.test(text)) score += 3;
    if (el.type === "tel") score += 1;
    return score;
  };

  const isVisible = (el) => {
    if (!el.isConnected || el.disabled) return false;
    if (el.type === "hidden") return false;
    const rect = el.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) return false;
    if (rect.right + window.scrollX < 0 || rect.bottom + window.scrollY < 0) return false;
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
      if (parseFloat(style.opacity) < 0.1) return false;
      if (style.clipPath && style.clipPath !== "none" && /inset\(\s*50%|circle\(\s*0/.test(style.clipPath)) return false;
    }
    return true;
  };

  // The form a field belongs to, or for fields outside any form, the document body (fields in
  // other forms excluded).
  const scopeOf = (el) => el.form || document.body || document.documentElement;

  const scopeInputs = (scope) => {
    if (scope instanceof HTMLFormElement) return Array.from(scope.elements).filter(isInput);
    return Array.from(scope.querySelectorAll("input")).filter((el) => !el.form);
  };

  // What kind of form a scope holds, and its fields:
  //   login        username (optional) + one password
  //   signup       username (optional) + new password (+ confirmation)
  //   change       current password + new password (+ confirmation)
  //   usernameOnly the first step of a two-step sign-in: a username and no password
  const analyze = (scope) => {
    const inputs = scopeInputs(scope);
    const visible = inputs.filter(isVisible);
    const passwords = visible.filter(isPasswordField);
    const firstPassword = passwords[0];
    const candidates = visible.filter((el) => usernameScore(el) >= 0 &&
      (!firstPassword || (el.compareDocumentPosition(firstPassword) & Node.DOCUMENT_POSITION_FOLLOWING)));
    let username = null;
    let best = -1;
    for (const el of candidates) {
      const score = usernameScore(el);
      // Ties go to the later field: the one nearest the password.
      if (score >= best) { best = score; username = el; }
    }
    const result = { kind: null, username, password: null, newPassword: null, confirm: null, scope };
    if (passwords.length === 0) {
      if (username && best >= 3) result.kind = "usernameOnly";
      return result;
    }
    const isNew = (el) => autocompleteTokens(el).includes("new-password") || NEW_PASSWORD_HINT.test(attrText(el));
    const isCurrent = (el) => autocompleteTokens(el).includes("current-password") || CURRENT_PASSWORD_HINT.test(attrText(el));
    if (passwords.length === 1) {
      const p = passwords[0];
      if (isNew(p) && !isCurrent(p)) { result.kind = "signup"; result.newPassword = p; }
      else { result.kind = "login"; result.password = p; }
    } else if (passwords.length === 2) {
      const [a, b] = passwords;
      if (isCurrent(a) && !isCurrent(b)) {
        result.kind = "change"; result.password = a; result.newPassword = b;
      } else {
        result.kind = "signup"; result.newPassword = a; result.confirm = b;
      }
    } else {
      result.kind = "change";
      [result.password, result.newPassword, result.confirm] = passwords;
    }
    return result;
  };

  const fieldRole = (el, a) => {
    if (el === a.username) return "username";
    if (el === a.password) return "password";
    if (el === a.newPassword || el === a.confirm) return "newPassword";
    return null;
  };

  const intAttr = (el, name) => {
    const v = parseInt(el.getAttribute(name), 10);
    return Number.isFinite(v) && v > 0 ? v : null;
  };

  const clip = (s) => (typeof s === "string" ? s.slice(0, MAX_VALUE) : "");

  // A username shown but not typed on a password-only page: a hidden or read-only field the
  // site keeps from the first step (Microsoft, Google).
  const usernameHint = (scope) => {
    for (const el of scopeInputs(scope).concat(scope === document.body ? [] : scopeInputs(document.body))) {
      if (isPasswordField(el)) continue;
      const looksRight = el.type === "email" || autocompleteTokens(el).includes("username") ||
        (USERNAME_HINT.test(attrText(el)) && !NOT_USERNAME.test(attrText(el)));
      if (!looksRight) continue;
      const v = (el.value || "").trim();
      if (v && v.length < 256 && !/\s/.test(v) && (el.type === "hidden" || el.readOnly || !isVisible(el))) return v;
    }
    return "";
  };

  // MARK: Focus

  let lastFocus = { id: null, at: 0 };
  const onFocus = (event) => {
    if (!event.isTrusted) return;
    const el = event.composedPath ? event.composedPath()[0] : event.target;
    if (!isInput(el) || !isVisible(el)) return;
    const a = analyze(scopeOf(el));
    if (!a.kind) return;
    const role = fieldRole(el, a);
    if (!role) return;
    const id = fieldID(el);
    const now = Date.now();
    if (lastFocus.id === id && now - lastFocus.at < 400) return;
    lastFocus = { id, at: now };
    const r = el.getBoundingClientRect();
    post({
      type: "focus",
      fieldID: id,
      field: role,
      form: a.kind,
      rect: { x: r.left, y: r.top, width: r.width, height: r.height },
      mainFrame: window === window.top,
      minLength: intAttr(el, "minlength"),
      maxLength: intAttr(el, "maxlength"),
      passwordRules: (el.getAttribute("passwordrules") || "").slice(0, 512),
    });
  };
  document.addEventListener("focusin", onFocus, true);
  document.addEventListener("mousedown", onFocus, true);

  // MARK: Submission

  let lastReport = { key: "", at: 0 };
  const report = (scope) => {
    const a = analyze(scope);
    if (!a.kind) return;
    const message = { type: "submit", form: a.kind, username: "", password: "", newPassword: "", usernameHint: "" };
    if (a.username) message.username = clip(a.username.value.trim());
    if (a.kind === "usernameOnly") {
      if (!message.username) return;
    } else {
      if (a.password) message.password = clip(a.password.value);
      if (a.newPassword) message.newPassword = clip(a.newPassword.value);
      if (a.confirm && a.confirm.value !== a.newPassword.value) message.newPassword = "";
      if (!message.password && !message.newPassword) return;
      if (!message.username) message.usernameHint = clip(usernameHint(scope));
    }
    const key = [message.form, message.username, message.password, message.newPassword].join("\u0000");
    const now = Date.now();
    if (key === lastReport.key && now - lastReport.at < 3000) return;
    lastReport = { key, at: now };
    post(message);
  };

  document.addEventListener("submit", (event) => {
    if (event.target instanceof HTMLFormElement) report(event.target);
  }, true);

  // Sites that sign in by script (no real submit): Enter in a field, or a click on the form's
  // sign-in or next button.
  document.addEventListener("keydown", (event) => {
    if (!event.isTrusted || event.key !== "Enter") return;
    const el = event.composedPath ? event.composedPath()[0] : event.target;
    if (isInput(el)) report(scopeOf(el));
  }, true);

  const buttonLike = (el) => {
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      if (node instanceof HTMLButtonElement) return node;
      if (isInput(node) && (node.type === "submit" || node.type === "button" || node.type === "image")) return node;
      if (node.getAttribute("role") === "button") return node;
      if (node instanceof HTMLFormElement || node === document.body) return null;
    }
    return null;
  };

  document.addEventListener("click", (event) => {
    if (!event.isTrusted) return;
    const target = event.composedPath ? event.composedPath()[0] : event.target;
    const button = buttonLike(target);
    if (!button) return;
    const label = [button.textContent, button.value, button.getAttribute("aria-label"), button.id, button.name]
      .filter(Boolean).join(" ").slice(0, 200);
    const isSubmit = (button instanceof HTMLButtonElement && button.type === "submit" && button.form) ||
      (isInput(button) && button.type === "submit");
    if (NOT_SUBMIT_TEXT.test(label) && !isSubmit) return;
    if (!isSubmit && !SUBMIT_TEXT.test(label)) return;
    report(button.form || scopeOf(button));
  }, true);

  // MARK: Forms on the page

  // Tells the app that this frame has a login form (for ⌘\ and a key icon), once per kind set.
  let lastKinds = "";
  let scanTimer = null;
  const scan = () => {
    scanTimer = null;
    const kinds = new Set();
    for (const form of Array.from(document.forms)) {
      const a = analyze(form);
      if (a.kind) kinds.add(a.kind);
    }
    if (document.body) {
      const a = analyze(document.body);
      if (a.kind) kinds.add(a.kind);
    }
    const summary = Array.from(kinds).sort().join(",");
    if (summary === lastKinds) return;
    lastKinds = summary;
    if (summary) post({ type: "forms", kinds: Array.from(kinds).sort(), mainFrame: window === window.top });
  };
  const scheduleScan = () => {
    if (scanTimer === null) scanTimer = setTimeout(scan, 300);
  };
  const startObserving = () => {
    scheduleScan();
    new MutationObserver(scheduleScan).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["type", "style", "class", "hidden"] });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startObserving, { once: true });
  else startObserving();

  // MARK: Fill (called only by the app, after the user picks a login)

  // Sets a value the way typing would be seen by frameworks: through the element's own value
  // setter (this world's, which page scripts can't patch), then input and change events.
  const setValue = (el, value) => {
    el.focus();
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };

  const normalizedOrigin = () => {
    const host = location.hostname.toLowerCase().replace(/\.+$/, "");
    return location.protocol + "//" + host + (location.port ? ":" + location.port : "");
  };

  Object.defineProperty(window, FILL, {
    value: (request) => {
      if (!request || request.docID !== docID) return "stale";
      if (normalizedOrigin() !== request.origin) return "originMismatch";
      const ref = fieldsByID.get(request.fieldID);
      const el = ref && ref.deref();
      if (!el || !el.isConnected || !isVisible(el)) return "noField";
      const a = analyze(scopeOf(el));
      if (!fieldRole(el, a)) return "noField";
      if (request.mode === "generated") {
        if (!a.newPassword || !isVisible(a.newPassword)) return "noField";
        setValue(a.newPassword, String(request.password));
        if (a.confirm && isVisible(a.confirm)) setValue(a.confirm, String(request.password));
        return "filled";
      }
      if (a.kind === "usernameOnly") {
        setValue(a.username, String(request.username));
        return "filled";
      }
      const passwordField = a.password || (a.kind === "signup" ? null : a.newPassword);
      if (!passwordField || !isVisible(passwordField)) return "noField";
      if (a.username && isVisible(a.username) && !a.username.readOnly && request.username) {
        setValue(a.username, String(request.username));
      }
      setValue(passwordField, String(request.password));
      return "filled";
    },
    writable: false,
    enumerable: false,
    configurable: false,
  });
})();
