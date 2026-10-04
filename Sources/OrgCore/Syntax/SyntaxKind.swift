public enum SyntaxKind: String, Sendable {
    // Tokens
    case text, newline, whitespace
    case stars, todoKeyword, priority, title, tags

    // Nodes
    case document, zerothSection, section, heading
    case planning, propertyDrawer, nodeProperty, drawer, clock
    case paragraph, plainList, item, table, tableRow, tableFormula
    case block, dynamicBlock, keyword, affiliatedKeyword
    case comment, fixedWidth, horizontalRule, footnoteDefinition
}
