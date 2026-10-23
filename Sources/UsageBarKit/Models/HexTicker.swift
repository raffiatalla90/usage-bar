import Foundation

/// Scrolling hex stream for the collapsed notch strip: a fixed-width window over an endless
/// deterministic hex sequence, advanced one glyph per frame. Reads as a live memory dump
/// without allocating or storing anything.
public enum HexTicker {
    private static let alphabet = Array("0123456789abcdef")

    /// Glyph at absolute position `i`. Deterministic and cheap: xorshift-multiply then mask,
    /// so the same frame always renders the same strip (the renderer captures stills).
    static func glyph(at i: Int) -> Character {
        var x = UInt32(truncatingIfNeeded: i &* 2_654_435_761 &+ 0x9E37_79B9)
        x ^= x >> 15
        x = x &* 2_246_822_519
        x ^= x >> 13
        return alphabet[Int(x & 0xF)]
    }

    /// `count` glyphs starting at `frame`, so the window slides left by one per frame.
    public static func line(frame: Int, count: Int) -> String {
        guard count > 0 else { return "" }
        var out = ""
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(glyph(at: max(0, frame) &+ i))
        }
        return out
    }
}
