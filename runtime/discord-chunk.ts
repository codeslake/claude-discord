// Splits a long Discord reply into pieces of at most `limit` characters without
// breaking markdown. The official plugin cuts at a fixed offset, which can land
// inside a `code span` or a ``` fence and leave Discord rendering the rest of
// the message as code. claude-discord swaps its chunk() for this one at start.
//
// A cut prefers a paragraph, then a line, then a space boundary. It never
// leaves an odd number of single backticks outside fences in a piece, and a
// piece cut inside a fence ends with a closing fence while the next one reopens
// it with the same language tag.

const CLOSE = "\n```"

// Fence state at the end of `piece` (the opening line, or null outside a fence)
// and the offset of its last single backtick outside fences, when their count
// is odd.
function scan(piece: string, fence: string | null) {
  let ticks = 0, last = -1, pos = 0
  for (const line of piece.split("\n")) {
    const t = line.trimStart()
    // A fence opens on ``` plus an optional tag and closes on a bare ```; a line
    // like "```x``` done" is inline code, not a fence.
    if (fence === null && /^```[^`]*$/.test(t)) fence = "```" + t.slice(3).trim()
    else if (fence !== null && /^```\s*$/.test(t)) fence = null
    else if (fence === null) {
      for (const m of line.matchAll(/`+/g)) {
        if (m[0].length === 1) { ticks++; last = pos + m.index! }
      }
    }
    pos += line.length + 1
  }
  return { fence, last: ticks % 2 ? last : -1 }
}

export function chunk(text: string, limit: number, _mode?: string): string[] {
  const out: string[] = []
  let rest = text
  let fence: string | null = null // opening line of the fence the next piece starts in
  for (;;) {
    const head = fence === null ? "" : fence + "\n"
    if (head.length + rest.length <= limit) { out.push(head + rest); return out }
    const w = Math.max(1, limit - head.length - CLOSE.length)
    const para = rest.lastIndexOf("\n\n", w)
    const line = rest.lastIndexOf("\n", w)
    const space = rest.lastIndexOf(" ", w)
    let cut = para > w / 2 ? para : line > w / 2 ? line : space > 0 ? space : w
    let s = scan(rest.slice(0, cut), fence)
    if (s.last > 0 && rest.slice(0, s.last).trim()) {
      cut = s.last
      s = scan(rest.slice(0, cut), fence)
    }
    out.push(head + rest.slice(0, cut) + (s.fence === null ? "" : CLOSE))
    fence = s.fence
    rest = rest.slice(cut).replace(/^\n+/, "")
    if (!rest) return out
  }
}
