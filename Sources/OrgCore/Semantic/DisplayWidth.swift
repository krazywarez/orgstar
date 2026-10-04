/// Columns a string occupies in a monospaced table: East Asian wide and fullwidth characters
/// and emoji take two, everything else one. Combining marks belong to their Character.
public func displayWidth(_ text: some StringProtocol) -> Int {
    text.reduce(0) { $0 + displayWidth(of: $1) }
}

func displayWidth(of character: Character) -> Int {
    guard let scalar = character.unicodeScalars.first else { return 0 }
    if scalar.properties.isEmojiPresentation { return 2 }
    switch scalar.value {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
         0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
        return 2
    default:
        return 1
    }
}
