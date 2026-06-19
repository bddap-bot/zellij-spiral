#!/usr/bin/env node
// Render a zellij-spiral `dump-layout` as ASCII boxes.
//
// Input  (stdin): the full `zellij action dump-layout` output.
// Output (stdout): an ASCII drawing of the live tab's tiled split tree, each leaf
//                  box labelled with its pane name (the harness names panes by MRU
//                  rank: "1" = dominant … "N" = innermost corner).
//
// Why we don't use the dump's `size="…%"`: under the headless pty the sizes read
// back as a flat 50% regardless of the real master share (dump-layout reconstructs
// from live geometry, and the headless geometry isn't faithful — see
// test/headless-test.sh header). So we ignore the dump's sizes and re-derive
// proportions from the *topology*: at every split the dominant (trailing) child
// gets MASTER and the recursion (leading) child gets the rest, which is exactly
// what the plugin emits and what a real terminal would render.

const MASTER = parseFloat(process.env.MASTER || '0.62'); // dominant share per split
const COLS = parseInt(process.env.COLS || '48', 10);     // drawing width  (chars)
const ROWS = parseInt(process.env.ROWS || '19', 10);     // drawing height (chars)

// ---------------------------------------------------------------------------
// 1. Isolate the live tab and tokenize its KDL into a split tree.
// ---------------------------------------------------------------------------

function liveTabLines(dump) {
  // dump-layout emits the live tab first, then new_tab_template + swap_* templates
  // we must ignore. Keep lines from `tab name=…` until the live tab's siblings.
  const out = [];
  let inTab = false;
  for (const raw of dump.split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (/^\s*tab name=/.test(line)) { inTab = true; continue; }
    if (inTab && /^\s*(floating_panes|new_tab_template|swap_tiled_layout|swap_floating_layout)\b/.test(line)) break;
    if (inTab) out.push(line);
  }
  return out;
}

// A node is either { leaf: true, name } or { split: 'vertical'|'horizontal', children: [...] }.
// We parse only what the spiral emits: `pane [name=".."] [size=".."] [split_direction=".."] [{ … }]`.
// Plugin/ui panes (tab-bar/status-bar/borderless/plugin) never appear in the live
// spiral tab here (the plugin hides itself and drops tiled ui bars), but guard anyway.
function parseTree(lines) {
  let i = 0;
  function parseChildren() {
    const children = [];
    while (i < lines.length) {
      const line = lines[i];
      const t = line.trim();
      if (t === '}') { i++; return children; }      // close current block
      if (t === '') { i++; continue; }
      if (!t.startsWith('pane')) { i++; continue; } // skip anything non-pane defensively
      const name = (t.match(/name="([^"]*)"/) || [])[1];
      const dir = (t.match(/split_direction="(vertical|horizontal)"/) || [])[1];
      const opensBlock = t.endsWith('{');
      i++;
      if (opensBlock) {
        const kids = parseChildren();
        // A split with an explicit direction; zellij defaults an omitted
        // split_direction to horizontal.
        children.push({ split: dir || 'horizontal', children: kids });
      } else {
        children.push({ leaf: true, name: name || '?' });
      }
    }
    return children;
  }
  const top = parseChildren();
  // The live tab body is a single root pane; unwrap a lone wrapper.
  return top.length === 1 ? top[0] : { split: 'horizontal', children: top };
}

// ---------------------------------------------------------------------------
// 2. Lay the tree out into fractional rectangles, then snap to the char grid.
// ---------------------------------------------------------------------------
// zellij split semantics: a `vertical` split stacks its children left→right
// (side by side); a `horizontal` split stacks them top→bottom. The spiral always
// emits exactly two children per split: [recursion (leading), dominant (trailing)].
// So for `vertical`  the dominant child is on the RIGHT and gets MASTER width;
//    for `horizontal` the dominant child is on the BOTTOM and gets MASTER height.
//
// We carry rectangles as fractional canvas coordinates [x0,y0,x1,y1] (0..1) so a
// split's boundary is a single shared coordinate: the lead child's far edge IS the
// dom child's near edge. Snapping both to the same grid line at draw time makes
// neighbours share one border line instead of drawing two adjacent ones.

function leafCount(node) {
  if (!node) return 0;
  if (node.leaf) return 1;
  return node.children.reduce((n, c) => n + leafCount(c), 0);
}

function layout(node, x0, y0, x1, y1, boxes) {
  if (!node) return; // defensive: a malformed/empty dump yields holes — skip them
  if (node.leaf) {
    boxes.push({ name: node.name, x0, y0, x1, y1 });
    return;
  }
  const kids = node.children;
  if (kids.length === 1) { layout(kids[0], x0, y0, x1, y1, boxes); return; }
  // Which child is the dominant master? NOT always the trailing one: for a Top/Left
  // start the dominant leads. The dump's `size="…%"` is unreliable under a headless
  // pty (reads back a flat 50%), so we infer dominance from the *structure*: the
  // spiral is a caterpillar { dominant_leaf, remainder_subtree }, so the dominant is
  // the child with fewer leaves (a single leaf) and the remainder has the rest. This
  // gives the dominant MASTER on whichever side it sits. (At the innermost split,
  // both children are single leaves — a tie; we then keep textual order, which only
  // affects the two smallest boxes.)
  const [a, b] = kids;
  const aDom = leafCount(a) <= leafCount(b); // dominant = fewer leaves; tie -> first
  const domShare = MASTER;
  if (node.split === 'vertical') {
    // left|right. The dominant (a or b) gets domShare of the width on its own side.
    const cut = aDom ? x0 + (x1 - x0) * domShare : x0 + (x1 - x0) * (1 - domShare);
    layout(a, x0, y0, cut, y1, boxes);
    layout(b, cut, y0, x1, y1, boxes);
  } else {
    const cut = aDom ? y0 + (y1 - y0) * domShare : y0 + (y1 - y0) * (1 - domShare);
    layout(a, x0, y0, x1, cut, boxes);
    layout(b, x0, cut, x1, y1, boxes);
  }
}

// ---------------------------------------------------------------------------
// 3. Draw the boxes into a character grid.
// ---------------------------------------------------------------------------
// Each fractional rectangle snaps to integer grid lines. Because sibling rectangles
// share a fractional boundary, their snapped borders coincide — one shared line.

function draw(boxes, cols, rows) {
  const grid = Array.from({ length: rows }, () => Array(cols).fill(' '));
  const set = (r, c, ch) => { if (r >= 0 && r < rows && c >= 0 && c < cols) grid[r][c] = ch; };
  // A corner '+' must survive a later edge write, so draw edges first, corners last.
  const corners = [];
  for (const b of boxes) {
    const cx0 = Math.round(b.x0 * (cols - 1));
    const cy0 = Math.round(b.y0 * (rows - 1));
    const cx1 = Math.round(b.x1 * (cols - 1));
    const cy1 = Math.round(b.y1 * (rows - 1));
    for (let c = cx0; c <= cx1; c++) { set(cy0, c, '-'); set(cy1, c, '-'); }
    for (let r = cy0; r <= cy1; r++) { set(r, cx0, '|'); set(r, cx1, '|'); }
    corners.push([cy0, cx0], [cy0, cx1], [cy1, cx0], [cy1, cx1]);
    // Centre the label within the box interior.
    const label = b.name;
    const cr = Math.floor((cy0 + cy1) / 2);
    const cc = Math.floor((cx0 + cx1) / 2) - Math.floor(label.length / 2);
    for (let k = 0; k < label.length; k++) set(cr, cc + k, label[k]);
  }
  for (const [r, c] of corners) set(r, c, '+');
  return grid.map((row) => row.join('').replace(/\s+$/, '')).join('\n');
}

// ---------------------------------------------------------------------------

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => (input += d));
process.stdin.on('end', () => {
  const lines = liveTabLines(input);
  if (lines.length === 0) {
    // No live tab in the dump — usually a session that didn't relayout (flaky
    // headless start). Emit a clear marker instead of a blank/garbled box.
    process.stdout.write('(no live tab in dump — relayout did not run)\n');
    return;
  }
  const tree = parseTree(lines);
  const boxes = [];
  layout(tree, 0, 0, 1, 1, boxes);
  process.stdout.write(draw(boxes, COLS, ROWS) + '\n');
});
