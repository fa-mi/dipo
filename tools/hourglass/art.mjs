// The hourglass on Home's "This period" card, drawn with the Anatomy kit
// (./anatomy, MIT licence): brass caps and posts, a glass, and the sand.
// build.mjs turns what this draws into DiPo/HourglassArt.json, which
// DiPo/Hourglass.swift paints with the app's colour tokens.
//
// It began as the figure in dipo.info's hero; the site has since gone back to
// showing the app itself, and the drawing lives here with the only screen that
// uses it. The camera is fitted to the glass and its caps at about the size of
// an icon, so the kit samples curves for that size and the data stays small.
import * as k from "./anatomy/iso-kit.mjs";
import * as G from "./anatomy/lathe.mjs";

const AZ = 40;

// The sand is measured in units of a full glass. 50 is the scale the drawing
// was first made at (a Rp 5.000.000 salary in Rp 100.000 grains); it only sets
// the arithmetic, and keeping it keeps the art identical to the shipped JSON.
export const SALARY_COINS = 50;

// World layout, in units of about a pixel: z up.
const AXIS = [0, -10];
const CAP_R = 29.5;
const CAP_H = 7;
const Z0 = CAP_H;                        // glass bottom
const HALF = 46;                         // each bulb's height
const NECK_Z = Z0 + HALF;
const TOP_Z = NECK_Z + HALF;             // glass top
const GLASS_R = 21;
const NECK_R = 2.4;
const WALL = 0.9;
const POST_AT = 26;
const FULL_U = 0.86;                     // how high a full glass of sand stands in the top bulb

const rad = (deg) => (deg * Math.PI) / 180;
const up = (z) => G.frameOf([AXIS[0], AXIS[1], z], [0, 0, 1], [1, 0, 0], [0, 1, 0]);
const around = (deg, r) => [AXIS[0] + Math.cos(rad(deg)) * r, AXIS[1] + Math.sin(rad(deg)) * r];
// Four posts at the corners, none straight behind the glass or across the
// sand: from this side each back post stands just above a front one.
const POSTS = { backLeft: around(AZ + 118, POST_AT), backRight: around(AZ - 118, POST_AT), left: around(AZ + 62, POST_AT), right: around(AZ - 62, POST_AT) };

const P = k.fitProjection(k.boxCorners({ x: AXIS[0] - CAP_R, y: AXIS[1] - CAP_R, w: CAP_R * 2, d: CAP_R * 2 }, 0, TOP_Z + CAP_H + 3.4), 120, 150, { pad: 4, azimuth: AZ });

const at = (p) => k.iso(p, P);
const D = (points, style) => k.dotsSvg(points, style);
const byDepth = (pts) => [...pts].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));

// ---- The glass. `u` runs from the neck (0) to a cap (1); the bulb leaves the
// neck smoothly and meets the cap with a vertical wall.
const glassR = (u) => NECK_R + (GLASS_R - NECK_R) * Math.pow(Math.sin((Math.PI / 2) * Math.min(1, Math.max(0, u))), 1.6);
const glassSlope = (u) => {
  const t = (Math.PI / 2) * Math.min(1, Math.max(1e-6, u));
  return ((GLASS_R - NECK_R) * 1.6 * Math.pow(Math.sin(t), 0.6) * Math.cos(t) * (Math.PI / 2)) / HALF;
};
// The whole glass along z, from the bottom cap to the top cap.
const glassAt = (s) => glassR(Math.abs(s - HALF) / HALF);
const glassSlopeAt = (s) => (s < HALF ? -1 : 1) * glassSlope(Math.abs(s - HALF) / HALF);

// Sand volume in a bulb filled from the neck (top bulb) up to `u`, or from the
// cap (bottom bulb) up to `v` of its height, in cubic units.
const inner = (u) => Math.max(0.5, glassR(u) - WALL);
const volume = (a, b) => {
  let v = 0;
  const n = 120;
  for (let i = 0; i < n; i++) { const u = a + ((b - a) * (i + 0.5)) / n; v += Math.PI * inner(u) ** 2 * ((b - a) / n) * HALF; }
  return v;
};
const FULL = volume(0, FULL_U);
const solve = (want, f) => { let lo = 0, hi = 1; for (let i = 0; i < 40; i++) { const mid = (lo + hi) / 2; if (f(mid) < want) lo = mid; else hi = mid; } return (lo + hi) / 2; };
// How far up the top bulb `coins` of sand reach, as u from the neck.
const topLevel = (coins) => (coins <= 0 ? 0 : solve((coins / SALARY_COINS) * FULL, (u) => volume(0, u)));
// How high `coins` of spent sand stand in the bottom bulb, as v from the cap,
// plus the cone the falling sand heaps in its middle.
const PEAK = 7;
const bottomLevel = (coins) => {
  if (coins <= 0) return { v: 0, peak: 0 };
  const want = (coins / SALARY_COINS) * FULL;
  const v = solve(want, (x) => volume(1 - x, 1) + (Math.PI * inner(1 - x) ** 2 * Math.min(PEAK, x * HALF)) / 3);
  return { v, peak: Math.min(PEAK, v * HALF) };
};

const sampled = (s0, s1, r, n = 24) => Array.from({ length: n + 1 }, (_, i) => { const s = s0 + ((s1 - s0) * i) / n; return [s, r(s), 1]; });

/** What is left: green sand from the neck up to its level. Lit: it is the money. */
export const sandTopSvg = (coins) => {
  if (coins <= 0.02) return "";
  const u = topLevel(coins);
  const F = up(NECK_Z);
  const profile = sampled(0, u * HALF, (s) => inner(s / HALF));
  return k.solidSvg(G.solidOf(profile, F, P, { smooth: { slope: (s) => glassSlope(s / HALF), radius: (s) => inner(s / HALF) } }), { tone: "hi", lit: true, className: "coin" });
};

/** What was spent: grey sand from the bottom cap up, heaped in the middle. */
export const sandBottomSvg = (coins) => {
  if (coins <= 0.02) return "";
  const { v, peak } = bottomLevel(coins);
  const F = up(Z0);
  const top = v * HALF;
  const profile = [...sampled(0, top, (s) => inner(1 - s / HALF), 16), [top + peak, 0.01]];
  return k.solidSvg(G.solidOf(profile, F, P), { tone: "mid", className: "sand" });
};

// The glass's far wall, drawn before the sand: it dims what stands behind.
function glassBack() {
  const F = up(Z0);
  const profile = sampled(0, HALF * 2, glassAt, 72);
  return `<path class="pg-glass" d="${G.outlineOf([[0, 0], ...profile, [HALF * 2, 0]], F, P, { fill: "surface", smooth: { slope: glassSlopeAt, radius: glassAt } }).fill}"/>`;
}

function glass() {
  const F = up(Z0);
  const profile = sampled(0, HALF * 2, glassAt, 72);
  const sides = G.silhouetteOf(profile, F, P, { radius: glassAt, slope: glassSlopeAt, samples: 140 });
  const out = [`<g class="m-glass">`, k.lineSvg(sides, { tone: "mid" })];
  // A short highlight on the wide part of the top bulb, near its left edge,
  // fading in and out.
  for (const [s0, s1] of [[HALF * 1.58, HALF * 1.9]]) {
    const pts = sampled(s0, s1, glassAt, 12).map(([s, r]) => at(G.pointOf(F, s, r + 0.05, rad(AZ + 62))));
    out.push(k.fadeLineSvg(pts, { fade: [10, 10], tone: "mid" }));
  }
  // A brass collar round the neck.
  out.push(`</g><g class="m-brass">`, k.solidSvg(G.ringBand(HALF - 2.2, HALF + 2.2, NECK_R, NECK_R + 1.6, F, P), { tone: "mid" }), `</g>`);
  return out.join("");
}

function cap(which) {
  const top = which === "top";
  const F = up(top ? TOP_Z : 0);
  const profile = top ? [[0, CAP_R - 2.5], [2.6, CAP_R - 2.5], [2.6, CAP_R], [CAP_H, CAP_R]] : [[0, CAP_R], [CAP_H - 2.6, CAP_R], [CAP_H - 2.6, CAP_R - 2.5], [CAP_H, CAP_R - 2.5]];
  const out = [k.solidSvg(G.solidOf(profile, F, P, { bevel: top ? 0.8 : 0 }), { tone: "mid", inner: k.lineSvg(G.arcOf(F, top ? CAP_H - 2 : 2, CAP_R, P), { tone: "faint" }) })];
  const z = top ? TOP_Z + CAP_H : CAP_H;
  if (top) {
    // The post heads and a turned boss on the top cap.
    out.push(D(Object.values(POSTS).map(([x, y]) => at([x, y, z])), { size: 0.55 }));
    out.push(k.lineSvg(Object.values(POSTS).map(([x, y]) => k.ring(x, y, 2.4, z, P, 16)).join(""), { tone: "lo" }));
    out.push(k.lineSvg(k.ring(AXIS[0], AXIS[1], 9, z, P, 48), { tone: "faint" }));
    out.push(k.solidSvg(G.solidOf([[0, 5], [1.6, 5], [2.6, 3.6, 1], [3.2, 1.6, 1], [3.4, 0.4, 1]], up(z), P), { tone: "mid" }));
  }
  return out.join("");
}

// A turned spindle from cap to cap, with a bead in the middle.
function post(key) {
  const [x, y] = POSTS[key];
  const F = G.frameOf([x, y, CAP_H], [0, 0, 1], [1, 0, 0], [0, 1, 0]);
  const Lp = TOP_Z - CAP_H, m = Lp / 2;
  const profile = [[0, 3], [3, 3], [3, 1.9], [m - 7, 1.9], [m - 4, 2.5, 1], [m - 1.6, 2.9, 1], [m, 3, 1], [m + 1.6, 2.9, 1], [m + 4, 2.5, 1], [m + 7, 1.9], [Lp - 3, 1.9], [Lp - 3, 3], [Lp, 3]];
  return k.solidSvg(G.solidOf(profile, F, P), { tone: "mid" });
}

/** Behind the sand: the bottom cap, the two back posts and the glass's far wall. */
export const hourglassBack = () => [
  `<g class="m-brass">`,
  cap("bottom"),
  ...byDepth([POSTS.backLeft, POSTS.backRight]).map((p) => post(p === POSTS.backLeft ? "backLeft" : "backRight")),
  `</g>`,
  `<g class="m-glass">${glassBack()}</g>`,
].join("");

/** In front of the sand: the glass, the two front posts and the top cap. */
export const hourglassFront = () => [
  glass(),
  `<g class="m-brass">`,
  ...byDepth([POSTS.left, POSTS.right]).map((p) => post(p === POSTS.left ? "left" : "right")),
  cap("top"),
  `</g>`,
].join("");

/** The soft shadow under the glass. */
export const hourglassHalo = () => `<path class="iso-halo" d="${k.haloOf({ x: AXIS[0] - CAP_R, y: AXIS[1] - CAP_R, w: CAP_R * 2, d: CAP_R * 2, r: CAP_R }, 0, 0.1, P)}"/>`;
