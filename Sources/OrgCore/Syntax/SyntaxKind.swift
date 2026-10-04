public enum SyntaxKind: String, Sendable {
    // Tokens
    case text, newline, whitespace
    case stars, todoKeyword, priority, tags
    case marker, linkPath, bullet, checkbox

    // Elements
    case document, zerothSection, section, heading, title
    case planning, propertyDrawer, nodeProperty, drawer, clock
    case paragraph, plainList, item, table, tableRow, tableCell, tableFormula
    case block, dynamicBlock, keyword, affiliatedKeyword
    case comment, fixedWidth, horizontalRule, footnoteDefinition

    // Objects
    case bold, italic, underline, strikeThrough, verbatim, code
    case link, linkDescription, timestamp, footnoteReference, statisticsCookie
    case target, macro, inlineSourceBlock, latexFragment, lineBreak, superscript
}
