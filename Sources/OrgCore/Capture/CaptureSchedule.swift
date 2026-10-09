import Foundation

extension Capture {
    /// A filled entry scheduled on `day` (as `Days` numbers it), for capturing from an agenda
    /// day: `SCHEDULED: <2026-10-09 Fri>` goes on the planning line after the heading. Text that
    /// is not an entry, or already has an active timestamp (`%t`, `%^t`), is left as it is.
    /// `cursor` is a UTF-16 offset and moves with the text after it.
    public static func scheduling(_ text: String, cursor: Int, on day: Int) -> (text: String, cursor: Int) {
        let ns = text as NSString
        guard text.range(of: "^\\*+ ", options: .regularExpression) != nil,
              text.range(of: "<[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) == nil else { return (text, cursor) }
        let d = Days.date(day)
        let name = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][Days.weekday(day)]
        let stamp = String(format: "SCHEDULED: <%04d-%02d-%02d %@>", d.year, d.month, d.day, name)
        let headingEnd = ns.range(of: "\n").location
        let insertion: (at: Int, text: String)
        if headingEnd == NSNotFound {
            insertion = (ns.length, "\n" + stamp)
        } else {
            let rest = ns.substring(from: headingEnd + 1)
            let lineEnd = (rest as NSString).range(of: "\n").location
            let next = lineEnd == NSNotFound ? rest : (rest as NSString).substring(to: lineEnd)
            if next.range(of: "^\\s*(CLOSED|DEADLINE|SCHEDULED):", options: .regularExpression) != nil {
                insertion = (headingEnd + 1 + (next as NSString).length, " " + stamp)
            } else {
                insertion = (headingEnd + 1, stamp + "\n")
            }
        }
        let result = ns.replacingCharacters(in: NSRange(location: insertion.at, length: 0), with: insertion.text)
        let moved = cursor > insertion.at || (cursor == insertion.at && headingEnd != NSNotFound && cursor > headingEnd)
        return (result, moved ? cursor + (insertion.text as NSString).length : cursor)
    }
}
