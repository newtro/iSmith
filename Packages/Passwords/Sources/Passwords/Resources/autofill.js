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

  const isWebDocument = () => location.protocol === "https:" || location.protocol === "http:";
  const post = (message) => {
    if (!isWebDocument()) return;
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
  // The value each field had after the user last typed or pasted into it (trusted input events)
  // or this script filled it. A field is only reported as submitted while it still holds that
  // value, so a page can't swap in values of its own.
  const userValues = new WeakMap();
  const holdsUserValue = (el) => userValues.has(el) && userValues.get(el) === el.value;
  // The last trusted click or Enter: a submission is only reported right after one, so a page
  // calling requestSubmit() on its own (say, on every keystroke) reports nothing.
  let lastAction = 0;
  const ACTION_WINDOW = 3000;
  // The form (scope) each reported field was in when it was focused; a fill refuses a field that
  // has since been moved to another form.
  const scopeAtFocus = new WeakMap();

  const MAX_VALUE = 4096;
  const TEXT_TYPES = new Set(["text", "email", "tel", "username", "url", ""]);
  const USERNAME_HINT = /user|e-?mail|login|logon|account|identifier|loginfmt|signin|phone|mobile|member|customer/i;
  const NOT_USERNAME = /search|query|^q$|captcha|otp|one-?time|2fa|totp|mfa|passcode|verification|security.?code|sms.?code|auth.?code|coupon|promo|zip|postal|city|address|first.?name|last.?name|company/i;
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

  // Two levels of visibility. `isRendered` is cheap and decides what a form is made of.
  // `isVisibleToUser` adds a hit test and is required of the focused field and of every field a
  // fill writes to, so a password never lands in a field the user can't see: transparent,
  // clipped, covered, off-screen, masked, or with invisible text.
  const alphaOf = (color) => {
    if (!color || color === "transparent") return 0;
    // color(srgb r g b / a), oklch(l c h / a), rgb(r g b / a)
    const slash = /\/\s*([\d.]+)(%?)\s*\)\s*$/.exec(color);
    if (slash) {
      const a = slash[2] ? parseFloat(slash[1]) / 100 : parseFloat(slash[1]);
      return Number.isFinite(a) ? a : 1;
    }
    const m = /rgba?\(([^)]*)\)/.exec(color);
    if (!m) return 1;
    const parts = m[1].split(/[\s,\/]+/).filter(Boolean);
    if (parts.length < 4) return 1;
    const a = parts[3].endsWith("%") ? parseFloat(parts[3]) / 100 : parseFloat(parts[3]);
    return Number.isFinite(a) ? a : 1;
  };

  const isRendered = (el) => {
    if (!el.isConnected || el.disabled || el.type === "hidden") return false;
    const rect = el.getBoundingClientRect();
    if (rect.width < 8 || rect.height < 8) return false;
    let opacity = 1;
    for (let node = el; node && node.nodeType === 1; node = node.parentElement || (node.getRootNode() && node.getRootNode().host) || null) {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
      const o = parseFloat(style.opacity);
      if (Number.isFinite(o)) opacity *= o;
      const filter = style.filter || "";
      const fo = /opacity\(\s*([\d.]+)(%?)/.exec(filter);
      if (fo && (fo[2] ? parseFloat(fo[1]) / 100 : parseFloat(fo[1])) < 0.5) return false;
      const blur = /blur\(\s*([\d.]+)px/.exec(filter);
      if (blur && parseFloat(blur[1]) >= 3) return false;
      const mask = style.webkitMaskImage || style.maskImage || "none";
      if (mask !== "none") return false;
    }
    return opacity >= 0.5;
  };

  const elementFromPoint = Document.prototype.elementFromPoint;
  const elementsFromPoint = Document.prototype.elementsFromPoint;
  const labelControlOf = Object.getOwnPropertyDescriptor(HTMLLabelElement.prototype, "control").get;
  const contains = Node.prototype.contains;

  // A hint the page draws over its own empty field instead of a placeholder attribute.
  // Microsoft's sign-in does this on both steps: `div.placeholderInnerContainer >
  // div.placeholder` ("Email, phone, or Skype", "Password") sits on top of the input, so a hit
  // test lands on the hint, and a click on it goes to the hint (the page then focuses the field).
  // It counts as part of the field only while it is plain see-through text: a text element
  // (no image, control, link or shadow root), painting nothing but its glyphs (no background,
  // border, outline, shadow, text shadow or stroke, filter, mask or ::before/::after), in a font
  // no taller than the field, inside the field's own wrapper (its parent or grandparent, never
  // the form or the body) and within the field's box. Only points inside the hint's own box look
  // through it (what paints outside it never does), and some of the field itself must still be
  // hit directly (see `isVisibleToUser`).
  const HINT_TAGS = new Set(["DIV", "SPAN", "P", "SMALL", "EM", "STRONG", "B", "I", "LABEL"]);
  const paintsOnlyText = (style) => {
    if (alphaOf(style.backgroundColor) > 0 || style.backgroundImage !== "none") return false;
    if (style.boxShadow !== "none" || (style.filter || "none") !== "none") return false;
    if ((style.backdropFilter || style.webkitBackdropFilter || "none") !== "none") return false;
    if ((style.webkitMaskImage || style.maskImage || "none") !== "none") return false;
    if ((style.textShadow || "none") !== "none" || parseFloat(style.webkitTextStrokeWidth) > 0) return false;
    if (style.outlineStyle !== "none" && parseFloat(style.outlineWidth) > 0) return false;
    if ((style.borderImageSource || "none") !== "none") return false;
    for (const side of ["Top", "Right", "Bottom", "Left"]) {
      if (parseFloat(style["border" + side + "Width"]) > 0 && alphaOf(style["border" + side + "Color"]) > 0) return false;
    }
    return true;
  };
  const noPseudoContent = (node) => ["::before", "::after"].every((pseudo) => {
    const content = getComputedStyle(node, pseudo).content;
    return !content || content === "none" || content === "normal";
  });
  const isFieldHint = (node, el, x, y) => {
    if (!(node instanceof HTMLElement) || node === el || !HINT_TAGS.has(node.tagName)) return false;
    if (contains.call(node, el) || node.shadowRoot) return false;
    const parent = el.parentElement;
    const wrappers = [parent, parent && parent.parentElement].filter((w) =>
      w && !(w instanceof HTMLFormElement) && w !== docBody() && w !== rootOf.call(document));
    if (!wrappers.some((w) => contains.call(w, node))) return false;
    if (queryAll.call(node, "*").length > 8 ||
        queryAll.call(node, "img, svg, canvas, video, iframe, object, embed, picture, input, textarea, select, button, a").length) return false;
    const f = el.getBoundingClientRect(), r = node.getBoundingClientRect();
    if (r.left < f.left - 2 || r.top < f.top - 2 || r.right > f.right + 2 || r.bottom > f.bottom + 2) return false;
    if (x < r.left || x >= r.right || y < r.top || y >= r.bottom) return false;
    const style = getComputedStyle(node);
    if (!(parseFloat(style.fontSize) <= f.height)) return false;
    return paintsOnlyText(style) && noPseudoContent(node);
  };

  // The input under the point, looking through its own hints, or null.
  const fieldBeneath = (x, y) => {
    if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) return null;
    const stack = elementsFromPoint.call(document, x, y);
    const i = stack.findIndex(isInput);
    if (i < 1) return null;
    const el = stack[i];
    return stack.slice(0, i).every((node) => isFieldHint(node, el, x, y)) ? el : null;
  };

  // The field itself is on top at the point.
  const hitsDirectly = (el, x, y) => {
    if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) return false;
    const hit = elementFromPoint.call(document, x, y);
    if (!hit) return false;
    if (hit === el) return true;
    // The field is inside the hit element's shadow root (or a shadow root nested in it).
    for (let root = el.getRootNode(); root && root.host; root = root.host.getRootNode()) {
      if (root.host === hit) return true;
    }
    return hit instanceof HTMLLabelElement && labelControlOf.call(hit) === el;
  };
  // The field is on top at the point, or under its own hint.
  const hits = (el, x, y) => hitsDirectly(el, x, y) || fieldBeneath(x, y) === el;

  // `strict` (for a field a password is written to): both the middle and the left quarter must
  // be the field, so a field narrowed to a sliver or half covered doesn't count. Otherwise (the
  // field the user just clicked) one of three points is enough, allowing for icons drawn over
  // its ends. Either way, a field seen only through a hint must also be hit directly somewhere
  // (Microsoft's hint leaves the field's lower edge clear), so a hint can't stand in for all of
  // it.
  // `clearText`: the field's own text may be invisible (one-time-code widgets that draw their
  // digits in boxes under a transparent input). Never for a field a password goes into.
  const isVisibleToUser = (el, strict, clearText) => {
    if (!isRendered(el)) return false;
    const style = getComputedStyle(el);
    if (!clearText && alphaOf(style.webkitTextFillColor || style.color) < 0.3) return false;
    const r = el.getBoundingClientRect();
    const y = r.top + r.height / 2;
    const xs = [r.left + r.width / 2, r.left + r.width / 4, r.right - r.width / 4];
    const seen = strict ? hits(el, xs[0], y) && hits(el, xs[1], y) : xs.some((x) => hits(el, x, y));
    if (!seen) return false;
    if (strict ? hitsDirectly(el, xs[0], y) && hitsDirectly(el, xs[1], y) : xs.some((x) => hitsDirectly(el, x, y))) return true;
    return [r.top + 3, r.bottom - 3].some((edge) => xs.some((x) => hitsDirectly(el, x, edge)));
  };

  // A field below the fold (or scrolled away in its container) is brought into view before it's
  // judged, as the user would scroll to it.
  const scrollIntoView = Element.prototype.scrollIntoView;
  const visibleOrScrolled = (el, strict, clearText) => {
    if (isVisibleToUser(el, strict, clearText)) return true;
    if (!isRendered(el)) return false;
    scrollIntoView.call(el, { block: "nearest", inline: "nearest" });
    return isVisibleToUser(el, strict, clearText);
  };

  // Forms and documents have named properties that override built-ins (`<input name="elements">`
  // makes `form.elements` that input; `<img name="body">` does the same to `document.body`), in
  // every world. These read the real values through the prototypes' own getters.
  const getter = (proto, name) => Object.getOwnPropertyDescriptor(proto, name).get;
  const formElementsOf = getter(HTMLFormElement.prototype, "elements");
  const formsOf = getter(Document.prototype, "forms");
  const bodyOf = getter(Document.prototype, "body");
  const rootOf = getter(Document.prototype, "documentElement");
  const inputFormOf = getter(HTMLInputElement.prototype, "form");
  const buttonFormOf = getter(HTMLButtonElement.prototype, "form");
  const queryAll = Element.prototype.querySelectorAll;
  const docBody = () => bodyOf.call(document) || rootOf.call(document);
  const formOf = (el) => {
    if (isInput(el)) return inputFormOf.call(el);
    if (el instanceof HTMLButtonElement) return buttonFormOf.call(el);
    return null;
  };

  // The form a field belongs to, or for fields outside any form, the document body (fields in
  // other forms excluded).
  const scopeOf = (el) => formOf(el) || docBody();

  const scopeInputs = (scope) => {
    if (!scope) return [];
    if (scope instanceof HTMLFormElement) return Array.from(formElementsOf.call(scope)).filter(isInput);
    return Array.from(queryAll.call(scope, "input")).filter((el) => !inputFormOf.call(el));
  };

  // What kind of form a scope holds, and its fields:
  //   login        username (optional) + one password
  //   signup       username (optional) + new password (+ confirmation)
  //   change       current password + new password (+ confirmation)
  //   usernameOnly the first step of a two-step sign-in: a username and no password
  const analyze = (scope) => {
    const inputs = scopeInputs(scope);
    const visible = inputs.filter(isRendered);
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

  // Lengths from the page; absurd values are dropped (the app clamps them again).
  const intAttr = (el, name) => {
    const v = parseInt(el.getAttribute(name), 10);
    return Number.isFinite(v) && v > 0 && v <= 4096 ? v : null;
  };

  const clip = (s) => (typeof s === "string" ? s.slice(0, MAX_VALUE) : "");

  // A username shown but not typed on a password-only page: a hidden or read-only field the
  // site keeps from the first step (Microsoft, Google).
  const usernameHint = (scope) => {
    const body = docBody();
    for (const el of scopeInputs(scope).concat(scope === body ? [] : scopeInputs(body))) {
      if (isPasswordField(el)) continue;
      const looksRight = el.type === "email" || autocompleteTokens(el).includes("username") ||
        (USERNAME_HINT.test(attrText(el)) && !NOT_USERNAME.test(attrText(el)));
      if (!looksRight) continue;
      const v = (el.value || "").trim();
      if (v && v.length < 256 && !/\s/.test(v) && (el.type === "hidden" || el.readOnly || !isRendered(el))) return v;
    }
    return "";
  };

  // MARK: One-time-code fields

  // A field for an SMS or authenticator code: `autocomplete="one-time-code"`, or a text, tel or
  // number field whose name, id, placeholder, aria-label, title or label says so (in a few
  // languages), or an `inputmode="numeric"` field taking 4 to 10 characters, or a row of 4 to 8
  // single-character boxes (one code split over several inputs). Never a password, search or
  // hidden field, and never anything in a payment form or named like a zip code, quantity, card
  // or coupon field. The app only offers a code here when one has just arrived for this page, so
  // a field wrongly taken for a code field costs little, and nothing is ever filled unasked.
  const CODE_TYPES = new Set(["text", "tel", "number", ""]);
  // camelCase, snake_case and kebab-case become words: "otpCode" -> "otp code".
  const words = (s) => String(s || "").replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_\-.:\[\]()]+/g, " ").toLowerCase();
  const CODE_HINT = new RegExp([
    "\\b(otp|otc|totp|hotp|2fa|mfa|tfa|passcode|one ?time( ?(pass ?word|pass ?code|code|pin))?)\\b",
    "\\btwo ?(factor|step)\\b", "\\bmulti ?factor\\b",
    "\\b(verification|verify|confirmation|security|sms|text|login|sign ?in|auth|authentication|access) ?code\\b",
    "\\benter (the |your |a )?(\\d+ ?digit )?code\\b", "\\bcode (we |that was )?(sent|texted)\\b",
    // es, pt, fr, de, it, nl, pl, sv
    "c[oó]digo( de)? (verifica[cç]i?[oó]n?|seguran[cç]a|seguridad|confirma[cç][aã]o|confirmaci[oó]n|acceso)",
    "code (de )?(v[ée]rification|s[ée]curit[ée]|confirmation)",
    "(best[aä]tigungs|verifizierungs|sicherheits|einmal|anmelde)code", "codice (di )?(verifica|sicurezza)",
    "verificatiecode|beveiligingscode", "kod (weryfikacyjny|sms)", "(verifierings|engångs)kod",
  ].join("|"), "i");
  // CJK and Cyrillic don't have \b word edges.
  const CODE_HINT_SCRIPT = /認証コード|確認コード|ワンタイム|验证码|驗證碼|校验码|인증 ?(번호|코드)|код (подтверждения|из смс)|одноразов/;
  // Named like something else: these never count as code fields by heuristics.
  const NOT_CODE = /\b(zip|postal|post ?code|postcode|plz|cep|area ?code|country ?code|dial ?code|promo|coupon|voucher|discount|gift|referral|invite|invitation|quantity|qty|amount|price|search|query|captcha|card|cc|cvv|cvc|csc|cid|exp|expiry|expiration|month|year|birth|dob|age|ssn|iban|routing)\b/;
  const NOT_CODE_AUTOCOMPLETE = /^(cc-|postal-code|bday|tel|transaction-|street|address|country|email|username|current-password|new-password|name|given-name|family-name|organization)/;
  // Fields like these are login identifiers (a phone number, a customer number): the bare
  // inputmode-and-length rule never takes them for a code field.
  const IDENTIFIER = /\b(phone|mobile|cell|tel|telephone|customer|member|account|user|username|login|email|id|card)\b/;
  const CODE_MAX = 12;

  const labelsOf = getter(HTMLInputElement.prototype, "labels");
  const getElementById = Document.prototype.getElementById;
  const textOf = (node) => (node && node.textContent ? node.textContent.replace(/\s+/g, " ").trim().slice(0, 200) : "");
  const labelText = (el) => {
    const parts = [];
    const labels = labelsOf.call(el);
    if (labels) for (const label of Array.from(labels).slice(0, 3)) parts.push(textOf(label));
    for (const id of (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean).slice(0, 3)) {
      parts.push(textOf(getElementById.call(document, id)));
    }
    return parts.join(" ");
  };
  const codeText = (el) => words([attrText(el), el.getAttribute("title"), labelText(el)].filter(Boolean).join(" "));

  // A payment form: card fields anywhere in the scope turn the heuristics off there ("security
  // code" next to a card number is the card's CVC).
  const isPaymentScope = (scope) => scopeInputs(scope).some((el) =>
    autocompleteTokens(el).some((t) => t.startsWith("cc-")) ||
    /\b(card ?(number|num|no)|cc ?(number|num)|credit ?card|cvv|cvc|csc)\b/.test(words([el.name, el.id].join(" "))));

  const inSearch = (el) => !!closest.call(el, "[role=search], [role=searchbox]");

  const codeShaped = (el) => isInput(el) && CODE_TYPES.has(el.type) && !el.readOnly && !el.disabled && !isPasswordField(el);

  // Names that rule a field out, unless the page said one-time-code itself.
  const ruledOut = (el) => {
    const ac = autocompleteTokens(el).filter(Boolean);
    if (ac.some((t) => NOT_CODE_AUTOCOMPLETE.test(t))) return true;
    return NOT_CODE.test(codeText(el));
  };

  const isSingleCodeField = (el, scope) => {
    if (!codeShaped(el) || inSearch(el)) return false;
    const ac = autocompleteTokens(el);
    if (ac.includes("one-time-code")) return !ac.some((t) => t.startsWith("cc-"));
    const max = el.maxLength;
    if (max > 0 && (max < 4 || max > CODE_MAX)) return false;
    if (ruledOut(el) || isPaymentScope(scope)) return false;
    const text = codeText(el);
    if (CODE_HINT.test(text) || CODE_HINT_SCRIPT.test(text)) return true;
    if ((el.getAttribute("inputmode") || "").toLowerCase() !== "numeric" || max < 4 || max > 10) return false;
    if (IDENTIFIER.test(text) || ac.includes("username") || ac.includes("tel")) return false;
    // The username of a login form is not a code field.
    const a = analyze(scope);
    return !(a.username === el && (a.password || a.kind === "usernameOnly"));
  };

  // One character per box, side by side.
  const isBox = (el) => codeShaped(el) && el.maxLength === 1 && isRendered(el);
  const splitBoxes = (el, scope) => {
    if (!isBox(el) || inSearch(el)) return null;
    const inputs = scopeInputs(scope).filter((x) => x.type !== "hidden" && isRendered(x));
    const i = inputs.indexOf(el);
    if (i < 0) return null;
    let a = i, b = i;
    while (a > 0 && isBox(inputs[a - 1])) a--;
    while (b < inputs.length - 1 && isBox(inputs[b + 1])) b++;
    const boxes = inputs.slice(a, b + 1);
    if (boxes.length < 4 || boxes.length > 8) return null;
    if (isPaymentScope(scope) || boxes.some((x) => ruledOut(x) && !autocompleteTokens(x).includes("one-time-code"))) return null;
    // On one line, left to right (a grid of 1-character cells is something else).
    const rects = boxes.map((x) => x.getBoundingClientRect());
    for (let k = 1; k < rects.length; k++) {
      if (Math.abs(rects[k].top - rects[0].top) > rects[0].height / 2 || rects[k].left <= rects[k - 1].left) return null;
    }
    return boxes;
  };

  // The code field `el` belongs to: its boxes (one for an ordinary field) and the longest code it
  // takes, or null.
  const codeFieldOf = (el) => {
    if (!isInput(el)) return null;
    const scope = scopeOf(el);
    const boxes = splitBoxes(el, scope);
    if (boxes) return { boxes, maxLength: boxes.length, scope };
    if (isSingleCodeField(el, scope)) return { boxes: [el], maxLength: el.maxLength > 0 ? el.maxLength : null, scope };
    return null;
  };

  // The element that has focus, inside shadow roots too.
  const deepActive = () => {
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    return active;
  };

  // The code field last reported as focused, until focus leaves it.
  let focusedCode = null;
  // While a code is being typed into its boxes, the focus moving along them reports nothing.
  let fillingCode = false;
  const codeBlurred = () => {
    if (!focusedCode) return;
    const id = focusedCode.id;
    focusedCode = null;
    post({ type: "codeBlur", fieldID: id });
  };
  document.addEventListener("focusout", () => {
    if (!focusedCode) return;
    setTimeout(() => {
      // The window losing focus (a click in the app's popover) leaves the field the active
      // element: that isn't the field losing focus.
      if (!focusedCode) return;
      const active = deepActive();
      if (active && focusedCode.boxes.some((ref) => ref.deref() === active)) return;
      codeBlurred();
    }, 0);
  }, true);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") codeBlurred(); }, true);
  window.addEventListener("pagehide", codeBlurred, true);

  // MARK: Focus

  // A focus counts as the user's when it comes from their click on the field, or from Tab just
  // pressed. A page calling `el.focus()` also produces a trusted focus event, but not one of these.
  let lastPointer = { el: null, at: 0 };
  let lastTab = 0;
  const closest = Element.prototype.closest;
  // The field a click is on: the clicked element, or (`labels`) the field of the label clicked
  // (which focuses it), or the field under a hint the page draws over it (whose click handler focuses
  // the field: Microsoft's sign-in).
  const pointerField = (event, labels) => {
    const el = event.composedPath ? event.composedPath()[0] : event.target;
    if (isInput(el) || !el || el.nodeType !== 1) return el;
    const label = labels ? closest.call(el, "label") : null;
    const control = label && labelControlOf.call(label);
    if (control) return control;
    return fieldBeneath(event.clientX, event.clientY) || el;
  };
  document.addEventListener("pointerdown", (event) => {
    if (!event.isTrusted) return;
    lastPointer = { el: pointerField(event, true), at: Date.now() };
  }, true);

  let lastFocus = { id: null, at: 0, user: false };
  const onFocus = (event) => {
    if (!event.isTrusted) return;
    // A mousedown on a hint is one on its field (whose page may then focus it without a new
    // focus event, as Microsoft's does when it already has focus). A label counts only once the
    // field it names is really focused.
    const el = event.type === "mousedown" ? pointerField(event, false)
      : event.composedPath ? event.composedPath()[0] : event.target;
    if (!isInput(el)) return;
    const visible = isVisibleToUser(el);
    if (!visible && !isVisibleToUser(el, false, true)) return;
    const now = Date.now();
    const user = event.type === "mousedown" ||
      (lastPointer.el === el && now - lastPointer.at < 1000) || now - lastTab < 500;
    if (fillingCode) return;
    const code = codeFieldOf(el);
    if (code) {
      // A split field is one field, named by its first box: moving between boxes is no new focus.
      const id = fieldID(code.boxes[0]);
      if (lastFocus.id === id && now - lastFocus.at < 400 && (lastFocus.user || !user)) return;
      lastFocus = { id, at: now, user };
      scopeAtFocus.set(code.boxes[0], code.scope);
      focusedCode = { id, boxes: code.boxes.map((b) => new WeakRef(b)) };
      const first = code.boxes[0].getBoundingClientRect(), last = code.boxes[code.boxes.length - 1].getBoundingClientRect();
      post({
        type: "codeFocus",
        fieldID: id,
        boxes: code.boxes.length,
        maxLength: code.maxLength,
        userInitiated: user,
        rect: { x: first.left, y: first.top, width: last.right - first.left, height: Math.max(first.height, last.height) },
        mainFrame: window === window.top,
      });
      return;
    }
    if (!visible) return;
    const scope = scopeOf(el);
    const a = analyze(scope);
    if (!a.kind) return;
    const role = fieldRole(el, a);
    if (!role) return;
    const id = fieldID(el);
    if (lastFocus.id === id && now - lastFocus.at < 400 && (lastFocus.user || !user)) return;
    lastFocus = { id, at: now, user };
    scopeAtFocus.set(el, scope);
    const r = el.getBoundingClientRect();
    post({
      type: "focus",
      fieldID: id,
      field: role,
      form: a.kind,
      userInitiated: user,
      rect: { x: r.left, y: r.top, width: r.width, height: r.height },
      mainFrame: window === window.top,
      minLength: intAttr(el, "minlength"),
      maxLength: intAttr(el, "maxlength"),
      passwordRules: (el.getAttribute("passwordrules") || "").slice(0, 512),
    });
  };
  document.addEventListener("focusin", onFocus, true);
  document.addEventListener("mousedown", onFocus, true);

  document.addEventListener("input", (event) => {
    if (!event.isTrusted) return;
    const el = event.composedPath ? event.composedPath()[0] : event.target;
    if (isInput(el)) userValues.set(el, el.value);
  }, true);

  // MARK: Submission

  let lastReport = { key: "", at: 0 };
  const report = (scope) => {
    if (Date.now() - lastAction > ACTION_WINDOW) return;
    const a = analyze(scope);
    if (!a.kind) return;
    const message = { type: "submit", form: a.kind, username: "", password: "", newPassword: "", usernameHint: "" };
    if (a.username) message.username = clip(a.username.value.trim());
    if (a.kind === "usernameOnly") {
      // A username the site filled in itself counts; one the page changed after the user typed
      // doesn't.
      if (!message.username || (userValues.has(a.username) && !holdsUserValue(a.username))) return;
    } else {
      // Only passwords the user typed (or iSmith filled), still as they were, are reported.
      if (a.password && holdsUserValue(a.password)) message.password = clip(a.password.value);
      if (a.newPassword && holdsUserValue(a.newPassword)) message.newPassword = clip(a.newPassword.value);
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
    if (event.isTrusted && event.target instanceof HTMLFormElement) report(event.target);
  }, true);

  // Sites that sign in by script (no real submit): Enter in a field, or a click on the form's
  // sign-in or next button.
  document.addEventListener("keydown", (event) => {
    if (!event.isTrusted) return;
    if (event.key === "Tab") lastTab = Date.now();
    if (event.key !== "Enter") return;
    lastAction = Date.now();
    const el = event.composedPath ? event.composedPath()[0] : event.target;
    if (isInput(el)) report(scopeOf(el));
  }, true);

  const buttonLike = (el) => {
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      if (node instanceof HTMLButtonElement) return node;
      if (isInput(node) && (node.type === "submit" || node.type === "button" || node.type === "image")) return node;
      if (node.getAttribute("role") === "button") return node;
      if (node instanceof HTMLFormElement || node === docBody()) return null;
    }
    return null;
  };

  document.addEventListener("click", (event) => {
    if (!event.isTrusted) return;
    lastAction = Date.now();
    const target = event.composedPath ? event.composedPath()[0] : event.target;
    const button = buttonLike(target);
    if (!button) return;
    const label = [button.textContent, button.value, button.getAttribute("aria-label"), button.id, button.name]
      .filter(Boolean).join(" ").slice(0, 200);
    const isSubmit = (button instanceof HTMLButtonElement && button.type === "submit" && formOf(button)) ||
      (isInput(button) && button.type === "submit");
    if (NOT_SUBMIT_TEXT.test(label) && !isSubmit) return;
    if (!isSubmit && !SUBMIT_TEXT.test(label)) return;
    report(formOf(button) || scopeOf(button));
  }, true);

  // MARK: Forms on the page

  // Tells the app that this frame has a login form (for ⌘\ and a key icon), once per kind set.
  let lastKinds = "";
  let scanTimer = null;
  const scan = () => {
    scanTimer = null;
    const kinds = new Set();
    for (const form of Array.from(formsOf.call(document))) {
      const a = analyze(form);
      if (a.kind) kinds.add(a.kind);
    }
    if (docBody()) {
      const a = analyze(docBody());
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
    new MutationObserver(scheduleScan).observe(rootOf.call(document), { childList: true, subtree: true, attributes: true, attributeFilter: ["type", "style", "class", "hidden"] });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startObserving, { once: true });
  else startObserving();

  // MARK: Fill (called only by the app, after the user picks a login)

  // Sets a value the way typing would be seen by frameworks: through the element's own value
  // setter (this world's, which page scripts can't patch), then input and change events.
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
  const setValue = (el, value) => {
    el.focus();
    valueSetter.call(el, value);
    userValues.set(el, el.value);
    el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };

  // A code goes in as typing would: a key down, the value through the element's own setter, an
  // `insertText` input event carrying the text, a key up, then change. Controlled inputs (React,
  // Vue) read the new value from the input event; split-box widgets that move focus on input or
  // keydown see each character arrive.
  const key = (el, type, ch) => el.dispatchEvent(new KeyboardEvent(type, {
    key: ch, code: /\d/.test(ch) ? "Digit" + ch : "Key" + ch.toUpperCase(), bubbles: true, cancelable: true, composed: true,
  }));
  const typeText = (el, text) => {
    el.focus();
    key(el, "keydown", text.slice(-1));
    valueSetter.call(el, text);
    el.dispatchEvent(new InputEvent("input", { inputType: "insertText", data: text, bubbles: true, composed: true }));
    key(el, "keyup", text.slice(-1));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };

  // Box by box, with a turn of the event loop between boxes: frameworks that keep the code in
  // state (React's `setOtp([...otp])`) re-render after each box, so the next box's handler
  // sees the digits before it. Checked again before each box, and right after the last one
  // (before the page can submit on the last digit and navigate): a code only counts as filled
  // when every box (or the field) took it, ignoring spaces and case a field may add.
  const nextTurn = () => new Promise((resolve) => setTimeout(resolve, 16));
  const fillCode = async (el, request) => {
    const code = String(request.code);
    if (!/^[A-Za-z0-9]{3,12}$/.test(code)) return "badCode";
    const field = codeFieldOf(el);
    if (!field || field.boxes[0] !== el || scopeAtFocus.get(el) !== field.scope) return "noField";
    const boxes = field.boxes;
    if (!boxes.every((b) => visibleOrScrolled(b, false, true))) return "noField";
    if (boxes.length > 1 ? code.length !== boxes.length : el.maxLength > 0 && el.maxLength < code.length) {
      return "lengthMismatch";
    }
    const parts = boxes.length > 1 ? Array.from(code) : [code];
    // Focus moving along the boxes (ours, or the page's own auto-advance) is no new focus.
    fillingCode = true;
    try {
      for (let i = 0; i < boxes.length; i++) {
        if (i > 0) {
          await nextTurn();
          if (!boxes[i].isConnected || !isRendered(boxes[i])) return "noField";
        }
        typeText(boxes[i], parts[i]);
      }
    } finally {
      fillingCode = false;
    }
    const same = (a, b) => a.replace(/\s+/g, "").toLowerCase() === b.toLowerCase();
    // A box the page already replaced (the next step) took its character.
    return boxes.every((b, i) => !b.isConnected || same(b.value, parts[i])) ? "filled" : "notAccepted";
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
      if (!el || !el.isConnected || !isVisibleToUser(el, false, request.mode === "code")) return "noField";
      if (request.mode === "code") return fillCode(el, request);
      const scope = scopeOf(el);
      if (scopeAtFocus.get(el) !== scope) return "noField";
      const a = analyze(scope);
      if (!fieldRole(el, a)) return "noField";
      const password = String(request.password);
      if (request.mode === "generated") {
        if (!a.newPassword || !visibleOrScrolled(a.newPassword, true)) return "noField";
        setValue(a.newPassword, password);
        if (a.confirm && visibleOrScrolled(a.confirm, true)) setValue(a.confirm, password);
        return "filled";
      }
      const username = String(request.username);
      if (a.kind === "usernameOnly") {
        setValue(a.username, username);
        return "filled";
      }
      const passwordField = a.password || (a.kind === "signup" ? null : a.newPassword);
      if (!passwordField) return "noField";
      const canFillUsername = a.username && !a.username.readOnly && username &&
        (a.username === el || visibleOrScrolled(a.username, false));
      const canFillPassword = passwordField === el || visibleOrScrolled(passwordField, true);
      if (!canFillPassword) {
        // The password field can't be seen (covered by a banner, say): fill only the username
        // the user clicked, and let them click the password field to finish.
        if (canFillUsername && a.username === el) {
          setValue(a.username, username);
          return "usernameOnly";
        }
        return "noField";
      }
      if (canFillUsername) setValue(a.username, username);
      setValue(passwordField, password);
      return "filled";
    },
    writable: false,
    enumerable: false,
    configurable: false,
  });
})();
