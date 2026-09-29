// Prints the next build number for DiPo: one above the highest build ever
// uploaded to App Store Connect for this app (any version, any state).
//
// App Store Connect rejects an upload whose build number it has already seen,
// and the number in the project file drifts from what was really uploaded
// (Fahmi bumps it locally when archiving from Xcode). Asking Apple is the only
// source that can't be stale.
//
// Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8), BUNDLE_ID, and
// FLOOR (the project's CURRENT_PROJECT_VERSION) — the answer is never below
// FLOOR + 1, so a first upload or an empty listing still gets a sane number.
import { readFileSync } from "node:fs";
import { sign } from "node:crypto";

const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, FLOOR = "0" } = process.env;
for (const [k, v] of Object.entries({ ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID })) {
  if (!v) { console.error(`${k} is not set`); process.exit(2); }
}

const b64url = (v) => Buffer.from(typeof v === "string" ? v : JSON.stringify(v)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const unsigned = `${b64url({ alg: "ES256", kid: ASC_KEY_ID, typ: "JWT" })}.${b64url({
  iss: ASC_ISSUER_ID, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1",
})}`;
const signature = sign("sha256", Buffer.from(unsigned), {
  key: readFileSync(ASC_KEY_PATH, "utf8"),
  dsaEncoding: "ieee-p1363", // JWS wants r||s, not DER
}).toString("base64url");
const auth = { Authorization: `Bearer ${unsigned}.${signature}` };

async function get(path) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, { headers: auth });
  if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${await res.text()}`);
  return res.json();
}

const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}&fields[apps]=bundleId&limit=1`);
const appId = apps.data?.[0]?.id;
if (!appId) throw new Error(`no app with bundle id ${BUNDLE_ID} in this team`);

const builds = await get(`/v1/builds?filter[app]=${appId}&sort=-uploadedDate&fields[builds]=version&limit=200`);
const seen = (builds.data || []).map((b) => Number.parseInt(b.attributes?.version, 10)).filter(Number.isFinite);
const highest = Math.max(Number.parseInt(FLOOR, 10) || 0, ...seen);
console.log(highest + 1);
