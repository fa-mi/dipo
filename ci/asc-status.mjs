// Prints where DiPo stands on the App Store: each App Store version with its
// state and the build attached to it, then the latest uploaded builds.
//
// Answers "which build do people actually have?", e.g. before tightening a
// backend rule that older builds can't follow. Run it from Actions → App
// Store status → Run workflow; the table lands in the run's summary.
//
// Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8), BUNDLE_ID.
// Reads only; prints only versions, states, build numbers and dates.
import { readFileSync } from "node:fs";
import { sign } from "node:crypto";

const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID } = process.env;
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
  dsaEncoding: "ieee-p1363",
}).toString("base64url");
const auth = { Authorization: `Bearer ${unsigned}.${signature}` };

async function get(path) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, { headers: auth });
  if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${await res.text()}`);
  return res.json();
}

const day = (iso) => (iso ? iso.slice(0, 10) : "–");

const apps = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}&fields[apps]=bundleId&limit=1`);
const appId = apps.data?.[0]?.id;
if (!appId) throw new Error(`no app with bundle id ${BUNDLE_ID} in this team`);

// App Store versions, newest first, each with the build chosen for it.
const versions = await get(`/v1/apps/${appId}/appStoreVersions?include=build&limit=10`);
const buildsById = new Map((versions.included || [])
  .filter((x) => x.type === "builds")
  .map((b) => [b.id, b.attributes]));
const rows = (versions.data || [])
  .map((v) => {
    const a = v.attributes || {};
    const buildId = v.relationships?.build?.data?.id;
    const b = buildId ? buildsById.get(buildId) : undefined;
    return {
      version: a.versionString,
      state: a.appVersionState || a.appStoreState || "?",
      build: b?.version || "–",
      created: a.createdDate,
    };
  })
  .sort((x, y) => (y.created || "").localeCompare(x.created || ""));

console.log("### App Store versions\n");
console.log("| Version | State | Build | Created |");
console.log("|---|---|---|---|");
for (const r of rows) console.log(`| ${r.version} | ${r.state} | ${r.build} | ${day(r.created)} |`);

const live = rows.find((r) => ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION"].includes(r.state));
console.log(`\n**Live on the App Store:** ${live ? `${live.version} (build ${live.build})` : "none found"}`);

// The latest uploads, for TestFlight.
const builds = await get(`/v1/builds?filter[app]=${appId}&sort=-uploadedDate&fields[builds]=version,uploadedDate,processingState,expired&limit=5`);
console.log("\n### Latest uploads\n");
console.log("| Build | Uploaded | Processing | Expired |");
console.log("|---|---|---|---|");
for (const b of builds.data || []) {
  const a = b.attributes || {};
  console.log(`| ${a.version} | ${day(a.uploadedDate)} | ${a.processingState || "?"} | ${a.expired ? "yes" : "no"} |`);
}
