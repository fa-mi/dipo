// Writes DiPo/HourglassArt.json: the hourglass art.mjs draws, as data the app
// can paint.
//
//   node tools/hourglass/build.mjs
//
// Swift has no Anatomy kit, so this writes what the kit draws as plain shapes,
// each tagged with its material and role, and DiPo/Hourglass.swift paints them
// with the app's own colour tokens (so they follow light and dark mode).
//
// Each shape is { m: material, r: role, d: path } plus, where it applies,
// t: line tone, l: 1 for the lit (money) solid, s: 1 for a smooth solid whose
// tone regions are stroked in their own colour, c: [cx, cy, r] for a dot,
// a: opacity. Paths use only M, L and Z. The sand is drawn at 21 levels, from
// empty to full in steps of 5%; the app picks the nearest.
//
// Don't edit the JSON by hand: change art.mjs, run this, and HourglassTests
// checks the result.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as B from "./art.mjs";

const out = process.argv[2] || join(dirname(fileURLToPath(import.meta.url)), "..", "..", "DiPo", "HourglassArt.json");

const MATERIALS = ["m-brass", "m-plinth", "m-glass", "m-today"];

// The kit samples curves finely for a big page; at icon size most of those
// points sit on a straight line. Drop every point within TOLERANCE of the
// line through its neighbours (Ramer-Douglas-Peucker), per subpath.
const TOLERANCE = 0.12;
function simplify(points) {
  if (points.length < 3) return points;
  const [ax, ay] = points[0], [bx, by] = points[points.length - 1];
  const len = Math.hypot(bx - ax, by - ay) || 1e-9;
  let worst = 0, at = 0;
  for (let i = 1; i < points.length - 1; i++) {
    const [px, py] = points[i];
    const dist = Math.abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len;
    if (dist > worst) { worst = dist; at = i; }
  }
  if (worst <= TOLERANCE) return [points[0], points[points.length - 1]];
  return [...simplify(points.slice(0, at + 1)).slice(0, -1), ...simplify(points.slice(at))];
}
const tidy = (d) => d.split(/(?=M)/).filter(Boolean).map((sub) => {
  const closed = /Z\s*$/.test(sub);
  const pts = [...sub.matchAll(/(-?[\d.]+) (-?[\d.]+)/g)].map((m) => [+m[1], +m[2]]);
  // A closed ring is cut at its farthest point from the start, so neither half
  // begins and ends on the same point (whose "line" has no direction).
  let kept;
  if (closed && pts.length > 3) {
    let far = 1;
    for (let i = 1; i < pts.length; i++) if (Math.hypot(pts[i][0] - pts[0][0], pts[i][1] - pts[0][1]) > Math.hypot(pts[far][0] - pts[0][0], pts[far][1] - pts[0][1])) far = i;
    kept = [...simplify(pts.slice(0, far + 1)).slice(0, -1), ...simplify([...pts.slice(far), pts[0]]).slice(0, -1)];
  } else kept = simplify(pts);
  return kept.map(([x, y], i) => `${i ? "L" : "M"}${+x.toFixed(1)} ${+y.toFixed(1)}`).join("") + (closed ? "Z" : "");
}).join("");
const attrsOf = (text) => Object.fromEntries([...text.matchAll(/([\w-]+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));

// Walk the kit's markup: groups carry material, lit and seamless flags; paths
// and circles become shapes.
function shapesOf(svg) {
  const shapes = [];
  const stack = [];
  const inherited = (key) => { for (let i = stack.length - 1; i >= 0; i--) if (stack[i][key] !== undefined) return stack[i][key]; return undefined; };
  for (const m of svg.matchAll(/<(\/?)(g|path|circle|defs|linearGradient|stop)\b([^>]*?)(\/?)>/g)) {
    const [, closing, tag, rest, selfClosing] = m;
    if (tag === "g") {
      if (closing) { stack.pop(); continue; }
      const a = attrsOf(rest);
      const classes = (a.class || "").split(/\s+/);
      const frame = {};
      const material = classes.find((c) => MATERIALS.includes(c));
      if (material) frame.m = material.slice(2);
      if (classes.includes("coin")) frame.m = "left";
      if (classes.includes("sand")) frame.m = "spent";
      if (classes.includes("iso-solid")) { frame.l = "data-lit" in a ? 1 : 0; frame.s = "data-seamless" in a ? 1 : 0; }
      if (classes.includes("iso-dots")) frame.dots = a["data-tone"] || "mid";
      if (classes.includes("iso-fade")) frame.fade = 1;
      stack.push(frame);
      if (selfClosing) stack.pop();
      continue;
    }
    if (closing || tag === "defs" || tag === "linearGradient" || tag === "stop") continue;
    const a = attrsOf(rest);
    const base = { m: inherited("m") || "plain" };
    if (tag === "circle") {
      shapes.push({ ...base, r: "dot", t: inherited("dots") || "mid", c: [+a.cx, +a.cy, +a.r] });
      continue;
    }
    const classes = (a.class || "").split(/\s+/);
    const d = a.d;
    if (!d) continue;
    let r;
    if (classes.includes("iso-halo")) r = "halo";
    else if (classes.includes("pg-glass")) r = "glass";
    else if (classes.includes("iso-fill")) r = "fill";
    else if (classes.includes("iso-shade")) r = "shade" + a["data-shade"];
    else if (classes.includes("iso-top")) r = "top";
    else r = "line";
    const shape = { ...base, r, d: tidy(d) };
    if (r === "line") {
      shape.t = a["data-tone"] || (inherited("fade") ? "mid" : "lo");
      if (classes.includes("iso-edge")) shape.e = 1;
      if (inherited("fade")) shape.a = 0.45;
    }
    if (inherited("l")) shape.l = 1;
    if (inherited("s") && (r === "top" || r.startsWith("shade"))) shape.s = 1;
    shapes.push(shape);
  }
  return shapes;
}

const levels = Array.from({ length: 21 }, (_, i) => i / 20);
const art = {
  back: shapesOf(B.hourglassHalo() + B.hourglassBack()),
  front: shapesOf(B.hourglassFront()),
  top: levels.map((share) => shapesOf(B.sandTopSvg(share * B.SALARY_COINS))),
  bottom: levels.map((share) => shapesOf(B.sandBottomSvg(share * B.SALARY_COINS))),
};

// A tight box round everything the app will ever draw.
let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
const grow = (x, y) => { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); };
for (const list of [art.back, art.front, ...art.top, ...art.bottom]) for (const s of list) {
  if (s.r === "halo") continue;
  if (s.c) grow(s.c[0], s.c[1]);
  else for (const [, x, y] of s.d.matchAll(/[ML](-?[\d.]+) (-?[\d.]+)/g)) grow(+x, +y);
}
const pad = 3;
art.viewBox = [x0 - pad, y0 - pad, x1 - x0 + pad * 2, y1 - y0 + pad * 2].map((v) => Math.round(v * 10) / 10);

writeFileSync(out, JSON.stringify(art));
const count = (list) => list.length;
console.log(`wrote ${out}: ${count(art.back)} back, ${count(art.front)} front, ${art.top.length}+${art.bottom.length} sand levels, viewBox ${art.viewBox.join(" ")}`);
