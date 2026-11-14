// Serves the orgstar+ for Mac buy page and issues license keys for completed Paddle transactions.
// Both paths are matched by their last segment, so the Worker answers under any route:
// krz.sh/apps/orgstar/buy, krz.sh/apps/orgstar/sandbox/buy, or /buy under `wrangler dev`.
//
// GET …/buy shows the price from Paddle.PricePreview, localized to the visitor's country (from
// Cloudflare's request.cf, omitted when unknown so Paddle.js detects it from the IP), and opens
// Paddle Checkout as a one-page overlay. On checkout.completed it goes to …/license?txn=txn_….
//
// GET …/license?txn=txn_… looks the transaction up in Paddle, and when it is completed and
// includes PRICE_ID, returns `ORGSTAR1-<payload>.<signature>`: base64url JSON
// {"e": email, "t": transaction, "i": billed-at seconds}, signed with Ed25519. The app checks the
// signature offline (Sources/OrgApp/LicenseKey.swift). Ed25519 signatures are deterministic, so the
// same transaction always yields the same key; nothing is stored.
//
// Vars (wrangler.toml, per environment): PADDLE_ENV ("sandbox" or "production", no default), PRICE_ID.
// Secrets (`wrangler secret put NAME [--env sandbox]`; locally .dev.vars, see .dev.vars.example):
// PADDLE_CLIENT_TOKEN (test_… or live_…), PADDLE_API_KEY, LICENSE_PRIVATE_KEY (PKCS#8 PEM, from
// keygen.sh; the sandbox Worker takes the same key).

// The buy page's copy. The price comes from Paddle.
const PRODUCT = {
  name: "orgstar+ for Mac",
  description: "One payment, a license key that doesn't expire. Editing, the agenda, capture, clocking, tables and search stay free.",
  features: [
    "Run and tangle source blocks",
    "PDF, Word and other export, and publishing",
    "Encrypted entries",
    "Org-roam nodes and backlinks",
    "Widgets",
    "Calendar and Reminders",
    "Shortcuts actions",
  ],
};

const PADDLE_API = { sandbox: "https://sandbox-api.paddle.com", production: "https://api.paddle.com" };

/// Reads the settings a path needs and throws when one is missing or belongs to the other environment.
function settings(env, ...needs) {
  const api = PADDLE_API[env.PADDLE_ENV];
  if (!api) throw new Error(`PADDLE_ENV must be "sandbox" or "production", not ${JSON.stringify(env.PADDLE_ENV)}`);
  if (!/^pri_[a-z\d]{26}$/.test(env.PRICE_ID ?? "")) throw new Error(`PRICE_ID isn't a Paddle price ID: ${JSON.stringify(env.PRICE_ID)}`);
  const prefix = env.PADDLE_ENV === "sandbox" ? "test_" : "live_";
  if (needs.includes("token") && !env.PADDLE_CLIENT_TOKEN?.startsWith(prefix))
    throw new Error(`PADDLE_CLIENT_TOKEN must be a ${prefix}… client-side token for ${env.PADDLE_ENV}`);
  for (const name of ["PADDLE_API_KEY", "LICENSE_PRIVATE_KEY"])
    if (needs.includes("issuer") && !env[name]) throw new Error(`${name} is not set`);
  return { api, sandbox: env.PADDLE_ENV === "sandbox" };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.endsWith("/buy")) return buy(request, env);
    if (url.pathname.endsWith("/license")) return license(url, env);
    return new Response("Not found", { status: 404 });
  },
};

function buy(request, env) {
  const { sandbox } = settings(env, "token");
  const country = request.cf?.country;
  const config = {
    sandbox,
    token: env.PADDLE_CLIENT_TOKEN,
    priceId: env.PRICE_ID,
    // XX is Cloudflare's unknown and T1 is Tor; Paddle.js detects the country itself without one.
    country: /^[A-Z]{2}$/.test(country ?? "") && country !== "XX" && country !== "T1" ? country : null,
  };
  const features = PRODUCT.features.map((feature) => `<li>${feature}</li>`).join("");
  return page(
    `<p>${PRODUCT.description}</p><ul>${features}</ul>` +
      `<p class="price" id="price">Loading the price…</p>` +
      `<button id="buy" type="button">Buy ${PRODUCT.name}</button>` +
      `<p class="note">Checkout is by Paddle, the merchant of record. Your key shows on the next page.</p>` +
      `<script src="https://cdn.paddle.com/paddle/v2/paddle.js"></script>` +
      `<script>const config = ${JSON.stringify(config).replace(/</g, "\\u003c")};\n${BUY_SCRIPT}</script>`,
    200,
    PRODUCT.name,
  );
}

// Runs on the buy page. Shows only Paddle's formatted total; does no price arithmetic.
const BUY_SCRIPT = `
if (config.sandbox) Paddle.Environment.set("sandbox");
Paddle.Initialize({
  token: config.token,
  eventCallback(event) {
    if (event.name === "checkout.completed")
      location.href = new URL("license?txn=" + encodeURIComponent(event.data.transaction_id), location.href);
  },
});
const items = [{ priceId: config.priceId, quantity: 1 }];
const request = config.country ? { items, address: { countryCode: config.country } } : { items };
Paddle.PricePreview(request)
  .then((preview) => {
    document.getElementById("price").textContent = preview.data.details.lineItems[0].formattedTotals.total;
  })
  .catch(() => {
    document.getElementById("price").textContent = "The price shows at checkout.";
  });
document.getElementById("buy").onclick = () =>
  Paddle.Checkout.open({ items, settings: { displayMode: "overlay", variant: "one-page" } });
`;

async function license(url, env) {
  const { api } = settings(env, "issuer");
  const txn = url.searchParams.get("txn") ?? "";
  if (!/^txn_[a-z0-9]{20,40}$/.test(txn)) return page("That isn't a Paddle transaction ID.", 400);

  const response = await fetch(`${api}/transactions/${txn}?include=customer`, {
    headers: { Authorization: `Bearer ${env.PADDLE_API_KEY}` },
  });
  if (response.status === 404) return page("No purchase was found for that transaction.", 404);
  if (!response.ok) return page("Paddle can't be reached right now. Try again in a minute.", 502);
  const { data } = await response.json();
  const paid = data.status === "completed" || data.status === "paid";
  const forOrgstar = data.items?.some((item) => item.price?.id === env.PRICE_ID);
  if (!paid || !forOrgstar) return page("That transaction isn't a completed orgstar+ purchase.", 404);

  const key = await sign(
    { e: data.customer?.email ?? "", t: txn, i: Math.floor(Date.parse(data.billed_at ?? data.created_at) / 1000) },
    env.LICENSE_PRIVATE_KEY,
  );
  if (url.searchParams.get("format") === "text") return new Response(key + "\n");
  return page(
    `<p>Your orgstar+ license key:</p><pre>${key}</pre>` +
      `<p>In orgstar, open Settings ▸ orgstar+, paste the key and choose Activate. Keep this page or the key; ` +
      `the same link shows it again.</p>`,
    200,
  );
}

export async function sign(payload, pem) {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const privateKey = await crypto.subtle.importKey("pkcs8", der, { name: "Ed25519" }, false, ["sign"]);
  const body = new TextEncoder().encode(JSON.stringify(payload));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, privateKey, body));
  return `ORGSTAR1-${base64url(body)}.${base64url(signature)}`;
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function page(body, status, heading = "orgstar+") {
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
    `<title>${heading}</title><style>body{font:16px/1.5 system-ui;max-width:40rem;margin:3rem auto;padding:0 1rem}` +
    `pre{white-space:pre-wrap;word-break:break-all;background:#f4f4f4;padding:1rem;border-radius:6px}` +
    `.price{font-size:1.75rem;font-weight:600;margin:1.5rem 0 .75rem}.note{color:#666;font-size:.9rem}` +
    `button{font:inherit;font-weight:600;padding:.7rem 1.4rem;border:0;border-radius:8px;background:#d4a017;color:#fff;cursor:pointer}</style>` +
    `<h1>${heading}</h1>${body.startsWith("<") ? body : `<p>${body}</p>`}`;
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}
