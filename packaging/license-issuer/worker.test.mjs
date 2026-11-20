// node --test packaging/license-issuer
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test } from "node:test";
import worker, { entitlement, sign, verify } from "./worker.js";

const pem = generateKeyPairSync("ed25519").privateKey.export({ type: "pkcs8", format: "pem" });
const env = {
  SPONSORABLE: "maintainer",
  LIFETIME_DOLLARS: "60",
  MONTHLY_DOLLARS: "5",
  RENEW_DAYS: "40",
  GITHUB_CLIENT_ID: "client",
  GITHUB_CLIENT_SECRET: "secret",
  GITHUB_TOKEN: "maintainer-token",
  LICENSE_PRIVATE_KEY: pem,
};
const config = { lifetime: 60, monthly: 5 };

/// Replaces fetch with `respond(url, init)` for the length of `body`.
async function withFetch(respond, body) {
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => respond(String(url), init);
  try {
    return await body();
  } finally {
    globalThis.fetch = original;
  }
}

const json = (data) => new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } });
const sponsorship = (dollars, { oneTime = false, active = true } = {}) => ({
  isActive: active,
  createdAt: "2026-11-01T12:00:00Z",
  tier: { monthlyPriceInDollars: dollars, isOneTime: oneTime },
});

test("keys verify and tampered keys don't", async () => {
  const key = await sign({ e: "octo", t: "github:U_1", i: 1 }, pem);
  assert.deepEqual(await verify(key, pem), { e: "octo", t: "github:U_1", i: 1 });
  const other = generateKeyPairSync("ed25519").privateKey.export({ type: "pkcs8", format: "pem" });
  assert.equal(await verify(await sign({ e: "octo", t: "github:U_1", i: 1 }, other), pem), null);
  assert.equal(await verify("ORGSTAR1-abc", pem), null);
});

test("one-time $60 is lifetime, active monthly $5 is monthly, anything else is nothing", () => {
  assert.equal(entitlement(sponsorship(60, { oneTime: true, active: false }), config), "lifetime");
  assert.equal(entitlement(sponsorship(100, { oneTime: true }), config), "lifetime");
  assert.equal(entitlement(sponsorship(40, { oneTime: true }), config), null);
  assert.equal(entitlement(sponsorship(5), config), "monthly");
  assert.equal(entitlement(sponsorship(5, { active: false }), config), null);
  assert.equal(entitlement(sponsorship(2), config), null);
  assert.equal(entitlement(null, config), null);
});

test("/license without a code redirects to GitHub with a state cookie", async () => {
  const response = await worker.fetch(new Request("https://krz.sh/apps/orgstar/license"), env);
  assert.equal(response.status, 302);
  const location = new URL(response.headers.get("location"));
  assert.equal(location.origin + location.pathname, "https://github.com/login/oauth/authorize");
  assert.equal(location.searchParams.get("redirect_uri"), "https://krz.sh/apps/orgstar/license");
  assert.match(response.headers.get("set-cookie"), new RegExp(`orgstar_state=${location.searchParams.get("state")};`));
});

/// The callback, with GitHub answering `sponsor` for the signed-in visitor.
async function callback(sponsor, { state = "abc", cookie = "abc" } = {}) {
  return withFetch(
    (url) => url.includes("access_token")
      ? json({ access_token: "visitor-token" })
      : json({ data: { viewer: { id: "U_1", login: "octo" }, owner: { sponsorshipForViewerAsSponsor: sponsor } } }),
    () => worker.fetch(
      new Request(`https://krz.sh/apps/orgstar/license?code=c&state=${state}`, { headers: { cookie: `orgstar_state=${cookie}` } }),
      env,
    ),
  );
}

const keyIn = async (response) => /<pre>([^<]+)<\/pre>/.exec(await response.text())?.[1];

test("a one-time sponsor gets the same lifetime key each time", async () => {
  const first = await keyIn(await callback(sponsorship(60, { oneTime: true, active: false })));
  const second = await keyIn(await callback(sponsorship(60, { oneTime: true, active: false })));
  assert.equal(first, second);
  assert.deepEqual(await verify(first, pem), { e: "octo", t: "github:U_1", i: Date.parse("2026-11-01T12:00:00Z") / 1000 });
});

test("a monthly sponsor gets a key that expires", async () => {
  const payload = await verify(await keyIn(await callback(sponsorship(5))), pem);
  assert.equal(payload.x - payload.i, 40 * 86400);
});

test("a visitor who isn't sponsoring enough gets no key", async () => {
  const response = await callback(sponsorship(1));
  assert.equal(response.status, 403);
  assert.equal(await keyIn(response), undefined);
});

test("a callback whose state doesn't match the cookie is refused", async () => {
  assert.equal((await callback(sponsorship(5), { cookie: "other" })).status, 400);
});

/// …/renew with `key`, GitHub listing the maintainer's sponsors in `pages`, with `sponsor` as
/// U_1's sponsorship on the last page.
async function renewal(key, sponsor, pages = 1) {
  const asked = [];
  const response = await withFetch(
    (url, init) => {
      const { variables } = JSON.parse(init.body);
      asked.push(variables);
      const page = asked.length;
      const nodes = [{ ...sponsorship(5), sponsorEntity: { id: `U_other${page}`, login: "someone" } }];
      if (page === pages && sponsor) nodes.push({ ...sponsor, sponsorEntity: { id: "U_1", login: "octo-renamed" } });
      const pageInfo = { hasNextPage: page < pages, endCursor: `cursor${page}` };
      return json({ data: { owner: { sponsorshipsAsMaintainer: { nodes, pageInfo } } } });
    },
    () => worker.fetch(new Request("https://krz.sh/apps/orgstar/renew", { method: "POST", body: key }), env),
  );
  return { response, asked };
}

test("renewal extends a monthly key while the sponsorship is active", async () => {
  const old = await sign({ e: "octo", t: "github:U_1", i: 1, x: 2 }, pem);
  const { response, asked } = await renewal(old, sponsorship(5), 2);
  assert.equal(response.status, 200);
  assert.deepEqual(asked, [{ login: "maintainer", after: null }, { login: "maintainer", after: "cursor1" }]);
  const fresh = await verify((await response.text()).trim(), pem);
  assert.equal(fresh.e, "octo-renamed");
  assert.ok(fresh.x > Date.now() / 1000 + 39 * 86400);
});

test("renewal refuses ended sponsorships, lifetime keys and forged keys", async () => {
  const monthly = await sign({ e: "octo", t: "github:U_1", i: 1, x: 2 }, pem);
  assert.equal((await renewal(monthly, null)).response.status, 403);
  assert.equal((await renewal(await sign({ e: "octo", t: "github:U_1", i: 1 }, pem), sponsorship(5))).response.status, 400);
  const other = generateKeyPairSync("ed25519").privateKey.export({ type: "pkcs8", format: "pem" });
  assert.equal((await renewal(await sign({ e: "octo", t: "github:U_1", i: 1, x: 2 }, other), sponsorship(5))).response.status, 400);
});
