/**
 * The only page this service serves: paste the in-game code, get the finished
 * `claude mcp add` line once. Self-contained by requirement — no external
 * asset, no CDN, no font, so the CSP can stay `default-src 'none'`.
 */

export interface PairingPageOptions {
  publicUrl: string;
  nonce: string;
}

export function renderPairingPage({ publicUrl, nonce }: PairingPageOptions): string {
  const url = escapeHtml(publicUrl);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Sceatorio — link Claude to the server</title>
<style nonce="${nonce}">
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body {
  margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
  background: #14161a; color: #e8e6e1; padding: 24px;
  font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
main { width: 100%; max-width: 620px; }
h1 { font-size: 21px; margin: 0 0 6px; letter-spacing: .2px; }
p { margin: 0 0 18px; color: #a7a49d; }
form { display: flex; gap: 10px; flex-wrap: wrap; }
input, button {
  font: inherit; border-radius: 8px; border: 1px solid #3a3d44; padding: 11px 14px;
}
input {
  flex: 1 1 240px; background: #1c1f24; color: #e8e6e1;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: 1.5px;
  text-transform: uppercase; min-width: 0;
}
input:focus-visible, button:focus-visible { outline: 2px solid #e8b04b; outline-offset: 2px; }
button { background: #e8b04b; color: #14161a; border-color: #e8b04b; font-weight: 600; cursor: pointer; }
button[disabled] { opacity: .55; cursor: progress; }
button.ghost { background: transparent; color: #e8e6e1; border-color: #3a3d44; font-weight: 400; }
pre {
  background: #1c1f24; border: 1px solid #3a3d44; border-radius: 8px; padding: 14px;
  overflow-x: auto; margin: 16px 0 10px; white-space: pre-wrap; word-break: break-all;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px;
}
.msg { margin-top: 16px; color: #f08a7a; min-height: 1.2em; }
.hint { color: #a7a49d; font-size: 13px; margin: 0; }
[hidden] { display: none !important; }
</style>
</head>
<body>
<main>
  <h1>Link Claude to Sceatorio</h1>
  <p>Open the AI Uplink in game, click <strong>Create pairing code</strong>, and paste it here.</p>
  <form id="pair-form" autocomplete="off">
    <input id="code" name="code" maxlength="15" spellcheck="false" required
           placeholder="XXXXX-XXXX-XXXX" aria-label="Pairing code">
    <button id="submit" type="submit">Pair</button>
  </form>
  <p class="msg" id="message" role="status" aria-live="polite"></p>
  <section id="result" hidden>
    <p class="hint">Run this once in your terminal. It is shown one time only — the secret is never stored.</p>
    <pre id="command"></pre>
    <button class="ghost" id="copy" type="button">Copy command</button>
    <p class="hint" id="expiry"></p>
    <p class="hint">Then check it with <code>/mcp</code> inside Claude Code. Endpoint: ${url}/mcp</p>
  </section>
</main>
<script nonce="${nonce}">
(function () {
  var form = document.getElementById('pair-form');
  var input = document.getElementById('code');
  var submit = document.getElementById('submit');
  var message = document.getElementById('message');
  var result = document.getElementById('result');
  var command = document.getElementById('command');
  var expiry = document.getElementById('expiry');

  form.addEventListener('submit', function (event) {
    event.preventDefault();
    var code = input.value.trim().toUpperCase();
    message.textContent = '';
    result.hidden = true;
    submit.disabled = true;
    fetch('/pair', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code: code })
    }).then(function (response) {
      return response.json().then(function (body) { return { status: response.status, body: body }; });
    }).then(function (outcome) {
      if (outcome.status !== 200) {
        message.textContent = outcome.body && outcome.body.message
          ? outcome.body.message
          : 'Pairing failed. Create a fresh code at the Uplink and try again.';
        return;
      }
      command.textContent = outcome.body.command;
      var minutes = Math.max(0, Math.round((outcome.body.expiresAtMs - Date.now()) / 60000));
      expiry.textContent = 'This binding expires in about ' + minutes + ' minutes of server time.';
      result.hidden = false;
      input.value = '';
    }).catch(function () {
      message.textContent = 'The pairing service is unreachable right now.';
    }).then(function () {
      submit.disabled = false;
    });
  });

  document.getElementById('copy').addEventListener('click', function () {
    var text = command.textContent;
    var done = function () { message.textContent = ''; };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {
        message.textContent = 'Copy failed — select the command manually.';
      });
    } else {
      message.textContent = 'Copy is unavailable here — select the command manually.';
    }
  });
})();
</script>
</body>
</html>
`;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/gu, (character) => {
    switch (character) {
      case "&": return "&amp;";
      case "<": return "&lt;";
      case ">": return "&gt;";
      case '"': return "&quot;";
      default: return "&#39;";
    }
  });
}
