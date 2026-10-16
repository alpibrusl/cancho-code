// The pure logic of docs/board.html (the block between the graph-logic markers): layers, critical path, the graph's geometry,
// the timeline's rows and the estimate. No browser and no DOM: scripts/test-board.sh extracts the block and runs this under node.
//
//   node page-logic.test.js <block.js> <dir with <fixture>.json boards and <fixture>.layout.json oracle files> <expected/page-logic.json>
//
// Two kinds of check: hand-written expectations for the small fixtures (expected/page-logic.json), and agreement with the oracle
// (tests/reference/board_ref.py --layout, a second implementation) on every fixture, the real runs included.
"use strict";
const fs = require("fs"), path = require("path");
const [blockFile, dir, expectFile] = process.argv.slice(2);
const L = new Function(fs.readFileSync(blockFile, "utf8") +
  "; return { isNum, dagLayout, unitMs, criticalPath, graphModel, placeGraph, timelineModel, estimateOf, graphSummary, runOrder };")();
const want = JSON.parse(fs.readFileSync(expectFile, "utf8"));
let bad = 0;
function fail(m) { console.error("FAIL: page logic: " + m); bad = 1; }
function same(label, got, w) {
  const a = JSON.stringify(got), b = JSON.stringify(w);
  if (a !== b) fail(label + ": wanted " + b + ", got " + a);
}
const boards = {};
for (const f of fs.readdirSync(dir)) {
  if (f.endsWith(".layout.json")) continue;
  if (!f.endsWith(".json")) continue;
  const n = f.slice(0, -5);
  if (!fs.existsSync(path.join(dir, n + ".layout.json"))) continue;
  boards[n] = { b: JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")), o: JSON.parse(fs.readFileSync(path.join(dir, n + ".layout.json"), "utf8")) };
}

// ---- agreement with the oracle, on every board given -----------------------------------------------------------------------
for (const n of Object.keys(boards)) {
  const { b, o } = boards[n];
  const m = L.graphModel(b.units);
  const lay = m.lay;
  same(n + ": ok", lay.ok, o.ok);
  const layers = {};
  lay.ids.forEach((id, i) => { if (lay.layer[i] !== null) layers[id] = lay.layer[i]; });
  same(n + ": layers", Object.keys(layers).sort().map(k => [k, layers[k]]), Object.keys(o.layers).sort().map(k => [k, o.layers[k]]));
  same(n + ": unplaced", lay.unplaced, o.unplaced);
  same(n + ": unknown deps", lay.unknown.map(u => [u.unit, u.dep]), o.unknown);
  if (o.critical) {
    same(n + ": critical basis", m.crit && m.crit.basis, o.critical.basis);
    same(n + ": critical total", m.crit && m.crit.total, o.critical.total);
    same(n + ": critical path", m.crit && m.crit.path, o.critical.path);
  } else if (m.crit) fail(n + ": a critical path for a plan that is not a DAG");
  // the layering invariant, from the board itself: every edge goes to a later layer; a root is in layer 0
  if (lay.ok) {
    lay.deps.forEach((ds, i) => {
      ds.forEach(d => { if (!(lay.layer[d] < lay.layer[i])) fail(n + ": " + lay.ids[d] + " is not in an earlier layer than " + lay.ids[i]); });
      if (!ds.length && lay.layer[i] !== 0) fail(n + ": root " + lay.ids[i] + " is not in layer 0");
    });
  }
  // geometry: nothing overlaps, everything is inside the drawing
  const g = L.placeGraph(lay);
  const boxes = Object.keys(g.nodes).map(k => g.nodes[k]);
  if (boxes.length !== lay.ids.length) fail(n + ": " + boxes.length + " nodes placed for " + lay.ids.length + " units");
  for (let i = 0; i < boxes.length; i++) {
    const a = boxes[i];
    if (a.x < 0 || a.y < 0 || a.x + g.nodeW > g.width || a.y + g.nodeH > g.height) fail(n + ": a node is outside the drawing");
    for (let j = i + 1; j < boxes.length; j++) {
      const c = boxes[j];
      if (a.x < c.x + g.nodeW && c.x < a.x + g.nodeW && a.y < c.y + g.nodeH && c.y < a.y + g.nodeH) fail(n + ": two nodes overlap");
    }
  }
  // the estimate, when there is a journal
  if (o.estimate) {
    const e = L.estimateOf(b.journal.events, b.units);
    same(n + ": estimate agent ms", e.agent_ms, o.estimate.agent_ms);
    same(n + ": estimate critical ms", e.critical_ms, o.estimate.critical_ms);
    same(n + ": estimate path", e.path, o.estimate.path);
  }
}

// ---- the hand-written expectations -----------------------------------------------------------------------------------------
for (const n of Object.keys(want.graphs)) {
  const w = want.graphs[n];
  if (!boards[n]) { fail(n + ": no board for this expectation"); continue; }
  const b = boards[n].b, m = L.graphModel(b.units);
  same(n + ": layers as lists", m.lay.layers.map(l => l.map(i => m.lay.ids[i])), w.layers);
  same(n + ": ok", m.lay.ok, w.ok);
  same(n + ": critical", m.crit && [m.crit.basis, m.crit.total, m.crit.path], w.critical);
  same(n + ": summary", L.graphSummary(m), w.summary);
}
// a run with no per-unit times counts units; a plan with no dependencies recorded is not drawn as one
{
  const b = JSON.parse(JSON.stringify(boards["graph-diamond"].b));
  b.units.forEach(u => { u.trail = null; u.column = "verified"; });
  const m = L.graphModel(b.units);
  same("no times: critical", [m.crit.basis, m.crit.total, m.crit.path], ["units", 3, ["a", "b", "d"]]);
  same("no times: summary", L.graphSummary(m), want.noTimesSummary);
  const nodeps = JSON.parse(JSON.stringify(b.units)); nodeps.forEach(u => { u.deps = null; });
  same("no plan: summary", L.graphSummary(L.graphModel(nodeps)), want.noPlanSummary);
}

// ---- the timeline ------------------------------------------------------------------------------------------------------------
function rowsOf(t) {
  return t.rows.map(r => ({ label: r.label, missing: !!r.missing, bars: r.bars.map(x => x.kind + ":" + x.good + ":" + x.x0 + "-" + x.x1 + (x.kind === "attempt" ? "#" + x.n : "")) }));
}
for (const n of Object.keys(want.timelines)) {
  const w = want.timelines[n], b = boards[n].b;
  const t = L.timelineModel(b.journal.events, b.units);
  same(n + ": rows", rowsOf(t), w.rows);
  same(n + ": total", t.total, w.total);
  same(n + ": ticks", [t.step, t.ticks], w.ticks);
  same(n + ": breaks", t.breaks, w.breaks);
  same(n + ": not run", t.notRun, w.notRun);
  same(n + ": run order", t.order, w.order);
  same(n + ": estimate", L.estimateOf(b.journal.events, b.units).text, w.estimate);
}
// what is missing is said, not guessed
{
  const b = boards["graph-journal"].b;
  const ev = JSON.parse(JSON.stringify(b.journal.events));
  ev.filter(e => e.kind === "attempt")[2].ms = undefined;
  same("an attempt without ms", L.estimateOf(ev, b.units).text, want.noMs);
  same("no plan", L.estimateOf(b.journal.events, b.units.map(u => Object.assign({}, u, { deps: null }))).text, want.noPlanEstimate);
  const cyc = b.units.map(u => Object.assign({}, u)); cyc[0].deps = ["d"];
  same("a cycle", L.estimateOf(b.journal.events, cyc).text, want.cycleEstimate);
  const t = L.timelineModel(ev, b.units);
  const bar = t.rows[2].bars.filter(x => x.kind === "attempt")[1];
  same("an attempt without ms is a point, not a bar", [bar.x0, bar.x1, bar.good], [32500, 32500, true]);
  const none = L.timelineModel([{ t_ms: 5, kind: "run_start" }], []);
  same("no plan stage: the first row says so", [none.rows[0].label, none.rows[0].missing], ["plan", true]);
}

// ---- robustness: nothing hangs, nothing throws ---------------------------------------------------------------------------
function mk(n, f) { const us = []; for (let i = 0; i < n; i++) us.push({ id: "u" + i, deps: f(i), column: "waiting", trail: [], attempts: 0, function: "f" + i }); return us; }
const t0 = Date.now();
const odd = [
  [],
  [{ id: "a", deps: ["a"] }],
  [{ id: "a", deps: ["b"] }, { id: "b", deps: ["a"] }],
  [{ id: "a" }, { id: "a", deps: [] }],
  [{ id: "__proto__", deps: ["constructor"] }, { id: "constructor", deps: ["__proto__", "toString"] }],
  [{ id: "a", deps: "b" }, { id: "b", deps: [null, 3, "a"] }],
  mk(256, i => (i ? ["u" + (i - 1)] : [])),                       // the deepest chain the tool keeps
  mk(256, () => []),                                              // the widest
  mk(256, i => { const d = []; for (let k = 1; k <= 8 && k <= i; k++) d.push("u" + (i - k)); return d; }),
  mk(256, i => ["u" + ((i + 1) % 256)]),                          // one big cycle
];
odd.forEach((us, k) => {
  try {
    const m = L.graphModel(us), g = L.placeGraph(m.lay);
    L.graphSummary(m);
    if (!(g.width > 0 && g.height > 0)) fail("odd plan " + k + ": empty drawing");
  } catch (e) { fail("odd plan " + k + " threw: " + e.message); }
});
const hang = Date.now() - t0;
if (hang > 3000) fail("the layout of the odd plans took " + hang + " ms");
{
  const m = L.graphModel(mk(256, i => (i ? ["u" + (i - 1)] : [])));
  same("a chain of 256", [m.lay.layers.length, m.crit.path.length, m.lay.ok], [256, 256, true]);
  const w = L.graphModel(mk(256, () => []));
  same("256 independent units", [w.lay.layers.length, w.lay.layers[0].length], [1, 256]);
  const c = L.graphModel(mk(256, i => ["u" + ((i + 1) % 256)]));
  same("a cycle of 256", [c.lay.ok, c.lay.unplaced.length, c.crit], [false, 256, null]);
}
{
  // a hostile journal: no throw, whatever the events hold
  const junk = [null, 3, "x", { kind: "attempt" }, { kind: "attempt", unit: "a", t_ms: "x", ms: "y" }, { t_ms: 1, kind: "attempt", unit: 5 },
                { t_ms: 1, kind: "unit_end", unit: "zz" }, { t_ms: 0, kind: "run_start" }, { t_ms: -5, kind: "sweep", after_unit: "q" }];
  try { L.timelineModel(junk, [{ id: "a", deps: [] }]); L.estimateOf(junk, [{ id: "a", deps: [] }]); L.runOrder(junk); }
  catch (e) { fail("a hostile journal threw: " + e.message); }
}
process.exit(bad);
