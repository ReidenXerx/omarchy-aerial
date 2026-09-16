// Where every window goes when the overview opens.
//
// Mission Control's trick is that the spread is *readable*: a window ends up
// roughly where it was, at roughly its own shape, and nothing overlaps. Three
// rules get that, and they are the whole algorithm:
//
//   Reading order. Windows are sorted by where they actually are on screen —
//   top to bottom, then left to right — so your eye finds the one you want
//   where it expects to.
//
//   Own shape. Every thumbnail keeps its window's aspect ratio. A tall
//   terminal stays tall; a browser stays wide. Squaring everything off is what
//   makes cheap overviews unreadable.
//
//   Justified rows. Rows are filled greedily and then stretched to the full
//   width, the way a photo gallery justifies a row. The row height is found by
//   bisection so the whole set fills the area without overflowing it.
//
// Pure functions over plain objects: no QML, no compositor, so the behaviour is
// tested in node rather than by looking at it.

/** A window as the compositor reports it. Only the rectangle matters here. */
function normalise(windows) {
  return windows
    .filter(w => w && w.w > 0 && w.h > 0)
    .map(w => ({
      key: w.key,
      x: Number(w.x) || 0,
      y: Number(w.y) || 0,
      w: Number(w.w),
      h: Number(w.h),
      aspect: Number(w.w) / Number(w.h),
    }));
}

/** Top to bottom, then left to right, with a band so a slightly higher window
 *  on the same row does not jump ahead of its neighbours. */
function inReadingOrder(windows, band) {
  return windows.slice().sort((a, b) => {
    const rowA = Math.round(a.y / band);
    const rowB = Math.round(b.y / band);
    if (rowA !== rowB) return rowA - rowB;
    if (a.x !== b.x) return a.x - b.x;
    return String(a.key).localeCompare(String(b.key));
  });
}

/** Fill rows greedily at a given row height; returns the rows and the total
 *  height they need. Each row is then stretched towards `width`, but never past
 *  `ceiling` — without that, stretching a lone window undoes the size cap and
 *  it fills the screen. */
function rowsAt(windows, width, rowHeight, gap, ceiling, rowGap) {
  const rows = [];
  let row = [];
  let rowWidth = 0;

  for (const win of windows) {
    const itemWidth = rowHeight * win.aspect;
    const withItem = rowWidth + itemWidth + (row.length ? gap : 0);
    if (row.length && withItem > width) {
      rows.push(row);
      row = [win];
      rowWidth = itemWidth;
    } else {
      row.push(win);
      rowWidth = withItem;
    }
  }
  if (row.length) rows.push(row);

  // A row narrower than the area is only stretched so far: one window on a row
  // of its own should not become a banner.
  let total = 0;
  const measured = rows.map(items => {
    const natural = items.reduce((sum, w) => sum + rowHeight * w.aspect, 0) + gap * (items.length - 1);
    const stretch = Math.min(width / natural, 1.35);
    const height = Math.min(rowHeight * stretch, ceiling);
    total += height;
    return { items, height, stretch };
  });
  total += rowGap * Math.max(0, rows.length - 1);
  return { rows: measured, total };
}

/**
 * Lay windows out inside an area.
 *
 * @param windows [{key, x, y, w, h}] as they are on screen
 * @param area    {width, height} the space the spread may use
 * @param options {gap, rowGap, maxScale} — gap separates windows on a row and
 *                rowGap separates the rows, which needs to be larger when
 *                something is written underneath each thumbnail. maxScale caps
 *                how far a small window grows, so one alone does not fill the
 *                screen.
 * @returns [{key, x, y, w, h}] slots in the area's coordinates
 */
function spread(windows, area, options) {
  const opts = Object.assign({ gap: 24, maxScale: 0.86 }, options || {});
  if (typeof opts.rowGap !== "number") opts.rowGap = opts.gap;
  const items = normalise(windows);
  if (items.length === 0) return [];

  const band = Math.max(1, area.height / 6);
  const ordered = inReadingOrder(items, band);

  // No thumbnail may be taller than this, however few there are.
  const ceiling = area.height * opts.maxScale;

  // Bisect the row height: the largest that still fits the area's height.
  let low = 8;
  let high = area.height;
  for (let step = 0; step < 40; step++) {
    const mid = (low + high) / 2;
    const { total } = rowsAt(ordered, area.width, mid, opts.gap, ceiling, opts.rowGap);
    if (total <= area.height) low = mid;
    else high = mid;
  }

  const { rows } = rowsAt(ordered, area.width, low, opts.gap, ceiling, opts.rowGap);

  const laid = [];
  const usedHeight = rows.reduce((sum, r) => sum + r.height, 0) + opts.rowGap * (rows.length - 1);
  let y = Math.max(0, (area.height - usedHeight) / 2);

  for (const row of rows) {
    const widths = row.items.map(w => row.height * w.aspect);
    const rowWidth = widths.reduce((a, b) => a + b, 0) + opts.gap * (row.items.length - 1);
    let x = Math.max(0, (area.width - rowWidth) / 2);
    row.items.forEach((win, i) => {
      laid.push({ key: win.key, x, y, w: widths[i], h: row.height });
      x += widths[i] + opts.gap;
    });
    y += row.height + opts.rowGap;
  }
  return laid;
}

/**
 * The slot an arrow key lands on, going (dx, dy) from `fromKey`.
 *
 * Geometric rather than by index: pressing right from the last window of a row
 * should not wrap to the start of the next one, and pressing down should find
 * whatever is actually below, whichever row it belongs to. Candidates must lie
 * in the direction pressed; among those, straight ahead beats far off to one
 * side, which is what `across * 2` buys.
 */
function nextIn(slots, fromKey, dx, dy) {
  if (slots.length === 0) return null;
  const from = slots.find(s => s.key === fromKey);
  if (!from) return slots[0].key;

  const cx = from.x + from.w / 2;
  const cy = from.y + from.h / 2;
  let best = null;
  let bestScore = Infinity;

  for (const slot of slots) {
    if (slot.key === fromKey) continue;
    const sx = slot.x + slot.w / 2;
    const sy = slot.y + slot.h / 2;
    const along = (sx - cx) * dx + (sy - cy) * dy;
    if (along <= 1) continue;
    const across = Math.abs((sx - cx) * dy - (sy - cy) * dx);
    const score = along + across * 2;
    if (score < bestScore) {
      bestScore = score;
      best = slot.key;
    }
  }
  return best;
}

/** Windows gathered by some key, with the groups in key order. */
function groupBy(windows, keyOf) {
  const buckets = {};
  for (const win of windows) {
    const key = keyOf(win);
    if (!buckets[key]) buckets[key] = [];
    buckets[key].push(win);
  }
  return Object.keys(buckets)
    .map(key => ({ key: Number(key), windows: buckets[key] }))
    .sort((a, b) => a.key - b.key);
}

/**
 * Lay several groups out as columns, one per group.
 *
 * This is what "show me everything" needs: spreading every window from every
 * workspace into one pile would answer "where is it" with "somewhere". Kept in
 * columns, the answer is still "on that desktop".
 *
 * Columns rather than rows because of the shape of the problem. Windows are
 * usually taller than they are wide and screens are wider than they are tall,
 * so a group given a short, full-width band can only grow until it hits the
 * band's height — which leaves most of the width empty. Given a tall, narrow
 * column instead, the same windows fill it.
 *
 * @returns [{key, x, width, slots}] — x is relative to the area's left, and
 *          each group's slots are relative to its own column.
 */
const LABEL_SPACE = 30;

function columns(groups, area, options) {
  const opts = Object.assign({ columnGap: 34, labelSpace: LABEL_SPACE }, options || {});
  if (groups.length === 0) return [];

  const each = (area.width - opts.columnGap * (groups.length - 1)) / groups.length;
  const width = Math.max(60, each);
  const height = Math.max(60, area.height - opts.labelSpace);

  const out = [];
  let x = 0;
  for (const group of groups) {
    out.push({
      key: group.key,
      x: x,
      width: width,
      height: height,
      slots: spread(group.windows, { width: width, height: height }, opts),
    });
    x += each + opts.columnGap;
  }
  return out;
}

/** Do any two slots overlap? Used by the tests, and cheap enough to assert. */
function overlaps(slots) {
  for (let i = 0; i < slots.length; i++) {
    for (let j = i + 1; j < slots.length; j++) {
      const a = slots[i];
      const b = slots[j];
      if (a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h) {
        return [a.key, b.key];
      }
    }
  }
  return null;
}

if (typeof module !== "undefined") {
  module.exports = { spread, overlaps, inReadingOrder, normalise, nextIn, groupBy, columns, LABEL_SPACE };
}
