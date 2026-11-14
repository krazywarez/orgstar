// Issues orgstar Mac license keys for completed Paddle transactions.
//
// GET /license?txn=txn_… looks the transaction up in Paddle, and when it is completed and
// includes PRICE_ID, returns `ORGSTAR1-<payload>.<signature>`: base64url JSON
// {"e": email, "t": transaction, "i": billed-at seconds}, signed with Ed25519. The app checks the
// signature offline (Sources/OrgApp/LicenseKey.swift). Ed25519 signatures are deterministic, so the
// same transaction always yields the same key; nothing is stored.
//
// Secrets (wrangler secret put): PADDLE_API_KEY, LICENSE_PRIVATE_KEY (PKCS#8 PEM, from keygen.sh).
// Vars (wrangler.toml): PADDLE_API, PRICE_ID.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/license") return new Response("Not found", { status: 404 });
    const txn = url.searchParams.get("txn") ?? "";
    if (!/^txn_[a-z0-9]{20,40}$/.test(txn)) return page("That isn't a Paddle transaction ID.", 400);

    const response = await fetch(`${env.PADDLE_API}/transactions/${txn}?include=customer`, {
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
  },
};

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

function page(body, status) {
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
    `<title>orgstar+</title><style>body{font:16px/1.5 system-ui;max-width:40rem;margin:3rem auto;padding:0 1rem}` +
    `pre{white-space:pre-wrap;word-break:break-all;background:#f4f4f4;padding:1rem;border-radius:6px}</style>` +
    `<h1>orgstar+</h1>${body.startsWith("<") ? body : `<p>${body}</p>`}`;
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}
