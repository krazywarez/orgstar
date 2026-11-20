// Issues orgstar+ for Mac license keys to GitHub sponsors. Paths are matched by their last
// segment, so the Worker answers under any route: krz.sh/apps/orgstar/buy, or /buy under
// `wrangler dev`.
//
// GET …/buy shows what orgstar+ includes and the two sponsorships that come with a key, linking to
// github.com/sponsors/SPONSORABLE, and to …/license for a sponsor's key.
//
// GET …/license signs in with GitHub (OAuth, state in a cookie) and asks GitHub for the visitor's
// sponsorship of SPONSORABLE:
// - one-time, LIFETIME_DOLLARS or more: a key that doesn't expire, the same one each time;
// - monthly and active, MONTHLY_DOLLARS or more: a key that expires RENEW_DAYS after it is issued.
//
// POST …/renew with a monthly key as the body returns a fresh one while that sponsorship is
// still active (403 when it isn't). orgstar renews monthly keys in the background.
//
// A key is `ORGSTAR1-<payload>.<signature>`: base64url JSON {"e": GitHub login, "t": "github:" +
// the account's node ID, "i": issued, "x": expires (monthly keys only), seconds}, signed with
// Ed25519. The app checks it offline (Sources/OrgApp/LicenseKey.swift). Nothing is stored.
//
// Vars (wrangler.toml): SPONSORABLE, LIFETIME_DOLLARS, MONTHLY_DOLLARS, RENEW_DAYS,
// GITHUB_CLIENT_ID. Secrets (`wrangler secret put NAME`; locally .dev.vars, see
// .dev.vars.example): GITHUB_CLIENT_SECRET, GITHUB_TOKEN (an owner of SPONSORABLE, for renewals),
// LICENSE_PRIVATE_KEY (PKCS#8 PEM, from keygen.sh).

const FEATURES = [
  "Run and tangle source blocks",
  "PDF, Word and other export, and publishing",
  "Encrypted entries",
  "Org-roam and Denote notes, daily notes and backlinks",
  "Widgets",
  "Calendar and Reminders",
  "Shortcuts actions",
];

const STATE_COOKIE = "orgstar_state";

/// Reads the settings and throws when one is missing.
function settings(env, ...secrets) {
  for (const name of ["SPONSORABLE", ...secrets])
    if (!env[name]) throw new Error(`${name} is not set`);
  const number = (name) => {
    const value = Number(env[name]);
    if (!(value > 0)) throw new Error(`${name} must be a positive number, not ${JSON.stringify(env[name])}`);
    return value;
  };
  return {
    sponsorable: env.SPONSORABLE,
    lifetime: number("LIFETIME_DOLLARS"),
    monthly: number("MONTHLY_DOLLARS"),
    renewDays: number("RENEW_DAYS"),
  };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.endsWith("/buy")) return buy(url, env);
    if (url.pathname.endsWith("/license")) return license(request, url, env);
    if (url.pathname.endsWith("/renew") && request.method === "POST") return renew(request, env);
    return new Response("Not found", { status: 404 });
  },
};

function buy(url, env) {
  const { sponsorable, lifetime, monthly } = settings(env);
  const features = FEATURES.map((feature) => `<li>${feature}</li>`).join("");
  return page(
    `<p>orgstar+ for Mac comes with sponsoring orgstar on GitHub. Editing, the agenda, capture, ` +
      `clocking, tables and search stay free.</p><ul>${features}</ul>` +
      `<ul class="tiers"><li><b>$${lifetime} once</b>: a license key that doesn't expire.</li>` +
      `<li><b>$${monthly} a month</b>: a key that orgstar renews while you sponsor.</li></ul>` +
      `<p><a class="button" href="https://github.com/sponsors/${sponsorable}">Sponsor on GitHub</a></p>` +
      `<p>Then <a href="${new URL("license", url)}">sign in with GitHub to get your key</a>.</p>` +
      `<p class="note">Payment is through GitHub Sponsors and needs a GitHub account.</p>`,
    200,
    "orgstar+ for Mac",
  );
}

async function license(request, url, env) {
  const config = settings(env, "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "LICENSE_PRIVATE_KEY");
  const self = new URL(url.pathname, url);
  const code = url.searchParams.get("code");
  if (!code) {
    const state = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
    const authorize = new URL("https://github.com/login/oauth/authorize");
    authorize.searchParams.set("client_id", env.GITHUB_CLIENT_ID);
    authorize.searchParams.set("redirect_uri", self.href);
    authorize.searchParams.set("scope", "read:user");
    authorize.searchParams.set("state", state);
    authorize.searchParams.set("allow_signup", "true");
    return new Response(null, {
      status: 302,
      headers: {
        location: authorize.href,
        "set-cookie": `${STATE_COOKIE}=${state}; Path=${url.pathname}; Max-Age=600; HttpOnly; Secure; SameSite=Lax`,
      },
    });
  }

  const cookie = (request.headers.get("cookie") ?? "").split(/;\s*/).find((c) => c.startsWith(STATE_COOKIE + "="));
  if (!cookie || cookie.slice(STATE_COOKIE.length + 1) !== url.searchParams.get("state"))
    return page(`The sign-in expired. <a href="${self}">Sign in again</a>.`, 400);

  const exchange = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, code, redirect_uri: self.href }),
  });
  const token = exchange.ok ? (await exchange.json()).access_token : null;
  if (!token) return page(`GitHub didn't complete the sign-in. <a href="${self}">Try again</a>.`, 502);

  const data = await graphql(
    token,
    `query($login: String!) {
      viewer { id login }
      owner: repositoryOwner(login: $login) {
        ... on Sponsorable {
          sponsorshipForViewerAsSponsor(activeOnly: false) {
            isActive createdAt tier { monthlyPriceInDollars isOneTime }
          }
        }
      }
    }`,
    { login: config.sponsorable },
  );
  if (!data) return page("GitHub can't be reached right now. Try again in a minute.", 502);

  const { viewer } = data;
  const sponsorship = data.owner?.sponsorshipForViewerAsSponsor;
  const kind = entitlement(sponsorship, config);
  const sponsor = `https://github.com/sponsors/${config.sponsorable}`;
  const clear = { "set-cookie": `${STATE_COOKIE}=; Path=${url.pathname}; Max-Age=0; HttpOnly; Secure; SameSite=Lax` };
  if (!kind)
    return page(
      `${escape(viewer.login)} isn't sponsoring at a level that includes orgstar+: $${config.lifetime} once, ` +
        `or $${config.monthly} or more a month. <a href="${sponsor}">Sponsor on GitHub</a>, then come back to this page.`,
      403,
      "orgstar+",
      clear,
    );

  const t = "github:" + viewer.id;
  const payload = kind === "lifetime"
    ? { e: viewer.login, t, i: seconds(sponsorship.createdAt) }
    : monthlyPayload(viewer.login, t, config.renewDays);
  const key = await sign(payload, env.LICENSE_PRIVATE_KEY);
  const note = kind === "lifetime"
    ? "It doesn't expire, and this page shows the same key whenever you sign in again."
    : `orgstar renews it while your monthly sponsorship continues. If you stop, orgstar+ ends when the key expires.`;
  return page(
    `<p>Your orgstar+ license key:</p><pre>${key}</pre>` +
      `<p>In orgstar, open Settings ▸ orgstar+, paste the key and choose Activate. ${note}</p>`,
    200,
    "orgstar+",
    clear,
  );
}

/// "lifetime", "monthly" or null for a sponsorship from GitHub's API.
export function entitlement(sponsorship, { lifetime, monthly }) {
  const dollars = sponsorship?.tier?.monthlyPriceInDollars ?? 0;
  if (!sponsorship) return null;
  if (sponsorship.tier?.isOneTime) return dollars >= lifetime ? "lifetime" : null;
  return sponsorship.isActive && dollars >= monthly ? "monthly" : null;
}

function monthlyPayload(login, t, renewDays) {
  const now = Math.floor(Date.now() / 1000);
  return { e: login, t, i: now, x: now + renewDays * 86400 };
}

async function renew(request, env) {
  const config = settings(env, "GITHUB_TOKEN", "LICENSE_PRIVATE_KEY");
  const payload = await verify((await request.text()).replace(/\s/g, ""), env.LICENSE_PRIVATE_KEY);
  if (!payload?.x || !payload.t?.startsWith("github:")) return text("Not a monthly orgstar+ key.", 400);

  const found = await activeSponsorship(env.GITHUB_TOKEN, config.sponsorable, payload.t.slice("github:".length));
  if (found === undefined) return text("GitHub can't be reached right now.", 502);
  if (entitlement(found, config) !== "monthly") return text("The monthly sponsorship has ended.", 403);
  return text(await sign(monthlyPayload(found.sponsorEntity.login, payload.t, config.renewDays), env.LICENSE_PRIVATE_KEY), 200);
}

/// The active sponsorship of `sponsorable` by the account with node ID `id`, from the
/// sponsorable's own list (private ones too, so `token` belongs to it or an owner of it); null
/// when there is none, undefined when GitHub can't be reached.
async function activeSponsorship(token, sponsorable, id) {
  let after = null;
  for (;;) {
    const data = await graphql(
      token,
      `query($login: String!, $after: String) {
        owner: repositoryOwner(login: $login) {
          ... on Sponsorable {
            sponsorshipsAsMaintainer(first: 100, after: $after, activeOnly: true, includePrivate: true) {
              nodes {
                isActive tier { monthlyPriceInDollars isOneTime }
                sponsorEntity { ... on User { id login } ... on Organization { id login } }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }`,
      { login: sponsorable, after },
    );
    const list = data?.owner?.sponsorshipsAsMaintainer;
    if (!list) return undefined;
    const match = list.nodes.find((node) => node.sponsorEntity?.id === id);
    if (match) return match;
    if (!list.pageInfo.hasNextPage) return null;
    after = list.pageInfo.endCursor;
  }
}

async function graphql(token, query, variables) {
  const response = await fetch("https://api.github.com/graphql", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "user-agent": "orgstar-license" },
    body: JSON.stringify({ query, variables }),
  });
  if (!response.ok) return null;
  const body = await response.json();
  return body.data ?? null;
}

function seconds(iso) {
  return Math.floor(Date.parse(iso) / 1000);
}

async function keys(pem) {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s|\\n/g, "")), (c) => c.charCodeAt(0));
  const privateKey = await crypto.subtle.importKey("pkcs8", der, { name: "Ed25519" }, true, ["sign"]);
  const { x } = await crypto.subtle.exportKey("jwk", privateKey);
  const publicKey = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", x }, { name: "Ed25519" }, false, ["verify"]);
  return { privateKey, publicKey };
}

export async function sign(payload, pem) {
  const { privateKey } = await keys(pem);
  const body = new TextEncoder().encode(JSON.stringify(payload));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, privateKey, body));
  return `ORGSTAR1-${base64url(body)}.${base64url(signature)}`;
}

/// The payload of a key this issuer signed, or null.
export async function verify(key, pem) {
  const match = /^ORGSTAR1-([\w-]+)\.([\w-]+)$/.exec(key);
  if (!match) return null;
  const [body, signature] = [unbase64url(match[1]), unbase64url(match[2])];
  const { publicKey } = await keys(pem);
  if (!(await crypto.subtle.verify({ name: "Ed25519" }, publicKey, signature, body))) return null;
  try {
    return JSON.parse(new TextDecoder().decode(body));
  } catch {
    return null;
  }
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unbase64url(text) {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

function escape(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

function text(body, status) {
  return new Response(body + "\n", { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

function page(body, status, heading = "orgstar+", headers = {}) {
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
    `<title>${heading}</title><style>body{font:16px/1.5 system-ui;max-width:40rem;margin:3rem auto;padding:0 1rem}` +
    `pre{white-space:pre-wrap;word-break:break-all;background:#f4f4f4;padding:1rem;border-radius:6px}` +
    `.tiers{list-style:none;padding:0}.note{color:#666;font-size:.9rem}` +
    `.button{display:inline-block;font-weight:600;padding:.7rem 1.4rem;border-radius:8px;background:#d4a017;color:#fff;text-decoration:none}</style>` +
    `<h1>${heading}</h1>${body.startsWith("<") ? body : `<p>${body}</p>`}`;
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8", ...headers } });
}
