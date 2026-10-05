// Keeps the release workflow from piling up development certificates.
//
// `xcodebuild archive -allowProvisioningUpdates` signs the archive with an
// Apple Development certificate. The runner starts with an empty keychain, so
// Xcode creates a new one through the API key on every run ("Created via API"),
// and its private key dies with the runner. After a dozen releases the team hits
// Apple's certificate limit and archiving fails ("Your account has reached the
// maximum number of certificates").
//
// So the workflow records the development certificates before archiving and,
// once the run is over, revokes the ones that appeared during it. Only those:
// a certificate that existed before the run — Fahmi's own from Xcode on his
// Mac — is never touched, and neither is any distribution certificate.
//
//   node ci/asc-dev-certs.mjs snapshot <file>   write the current ids to <file>
//   node ci/asc-dev-certs.mjs revoke-new <file> revoke ids not in <file>
//
// Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8).
import { readFileSync, writeFileSync } from "node:fs";
import { sign } from "node:crypto";

const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH } = process.env;
for (const [k, v] of Object.entries({ ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH })) {
  if (!v) { console.error(`${k} is not set`); process.exit(2); }
}
const [mode, file] = process.argv.slice(2);
if (!["snapshot", "revoke-new"].includes(mode) || !file) {
  console.error("usage: asc-dev-certs.mjs snapshot|revoke-new <file>");
  process.exit(2);
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
const api = "https://api.appstoreconnect.apple.com";

/// Development certificates only (DEVELOPMENT, IOS_DEVELOPMENT, …).
async function developmentCerts() {
  const res = await fetch(`${api}/v1/certificates?fields[certificates]=certificateType,displayName,name&limit=200`,
                          { headers: auth });
  if (!res.ok) throw new Error(`GET certificates: ${res.status} ${await res.text()}`);
  const body = await res.json();
  return (body.data || []).filter((c) => /DEVELOPMENT/.test(c.attributes?.certificateType || ""));
}

if (mode === "snapshot") {
  const ids = (await developmentCerts()).map((c) => c.id);
  writeFileSync(file, JSON.stringify(ids));
  console.log(`${ids.length} development certificate(s) before archiving`);
} else {
  const before = new Set(JSON.parse(readFileSync(file, "utf8")));
  // Xcode names the ones it makes through an API key "Created via API"; a
  // certificate someone made by hand mid-run is left alone.
  const fresh = (await developmentCerts())
    .filter((c) => !before.has(c.id) && /Created via API/.test(c.attributes?.displayName || c.attributes?.name || ""));
  for (const c of fresh) {
    const res = await fetch(`${api}/v1/certificates/${c.id}`, { method: "DELETE", headers: auth });
    if (!res.ok) throw new Error(`revoke ${c.id}: ${res.status} ${await res.text()}`);
    console.log(`Revoked ${c.attributes?.name || c.id}`);
  }
  if (fresh.length === 0) console.log("No development certificate was created by this run");
}
