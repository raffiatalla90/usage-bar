import Foundation

/// Typewriter cycle for the collapsed notch strip: type a word glyph by glyph, hold it,
/// backspace it, move to the next. Pure function of the frame number so the renderer
/// captures the same still twice.
public enum IdleTyper {
    public struct State: Equatable {
        public let text: String
        /// A keystroke is in flight — the cursor should sit solid, not blink.
        public let typing: Bool

        public init(text: String, typing: Bool) {
            self.text = text
            self.typing = typing
        }
    }

    public static func state(words: [String], frame: Int, hold: Int = 10) -> State {
        guard let first = words.first else { return State(text: "", typing: false) }
        let frame = max(0, frame)
        var rest = frame

        for word in words {
            let len = word.count
            let cycle = len * 2 + hold + 2
            if rest < cycle {
                if rest < len { return State(text: String(word.prefix(rest)), typing: true) }
                if rest < len + hold { return State(text: word, typing: false) }
                let back = rest - len - hold
                return State(text: String(word.prefix(max(0, len - back))), typing: true)
            }
            rest -= cycle
        }
        // Frames past the whole sequence wrap; falling back to the first word keeps the strip
        // from going blank if the word list shrinks at runtime.
        return State(text: first, typing: false)
    }
}
