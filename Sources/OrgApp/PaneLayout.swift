import Foundation

/// Identifies a pane for as long as it exists.
public struct PaneID: Hashable, Sendable {
    private let raw = UUID()
    public init() {}
}

/// How a window divides its editor area: one pane, or two layouts side by side (`horizontal`)
/// or one above the other (`vertical`), with the first's share of the space.
public indirect enum PaneLayout: Equatable, Sendable {
    public enum Axis: Equatable, Sendable { case horizontal, vertical }

    case pane(PaneID)
    case split(axis: Axis, first: PaneLayout, second: PaneLayout, fraction: Double)

    /// Panes in reading order: left before right, top before bottom.
    public var panes: [PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, let first, let second, _): first.panes + second.panes
        }
    }

    /// `id` halved along `axis`, with `new` after it.
    public func splitting(_ id: PaneID, axis: Axis, new: PaneID) -> PaneLayout {
        switch self {
        case .pane(id): .split(axis: axis, first: .pane(id), second: .pane(new), fraction: 0.5)
        case .pane: self
        case .split(let a, let first, let second, let fraction):
            .split(axis: a, first: first.splitting(id, axis: axis, new: new), second: second.splitting(id, axis: axis, new: new), fraction: fraction)
        }
    }

    /// The layout without `id`; its sibling takes the space. Nil when `id` was the only pane.
    public func removing(_ id: PaneID) -> PaneLayout? {
        switch self {
        case .pane(id): nil
        case .pane: self
        case .split(let axis, let first, let second, let fraction):
            switch (first.removing(id), second.removing(id)) {
            case (nil, let rest?), (let rest?, nil): rest
            case (let a?, let b?): .split(axis: axis, first: a, second: b, fraction: fraction)
            case (nil, nil): nil
            }
        }
    }

    /// The split whose first pane in reading order is `id`, with `fraction` for its first side.
    public func settingFraction(_ fraction: Double, ofSplitStartingWith id: PaneID) -> PaneLayout {
        switch self {
        case .pane: self
        case .split(let axis, let first, let second, let old):
            if first.panes.first == id {
                .split(axis: axis, first: first, second: second, fraction: min(max(fraction, 0.1), 0.9))
            } else {
                .split(axis: axis, first: first.settingFraction(fraction, ofSplitStartingWith: id), second: second.settingFraction(fraction, ofSplitStartingWith: id), fraction: old)
            }
        }
    }

    /// Only `id`, filling the window.
    public func only(_ id: PaneID) -> PaneLayout { .pane(id) }

    /// The pane after `id` in reading order, wrapping; the first when `id` isn't here.
    public func next(after id: PaneID) -> PaneID {
        let all = panes
        guard let index = all.firstIndex(of: id) else { return all[0] }
        return all[(index + 1) % all.count]
    }
}
