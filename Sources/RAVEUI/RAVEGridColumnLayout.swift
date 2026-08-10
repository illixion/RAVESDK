/*
 RAVE SDK — gallery grid column sizing.

 Portable on purpose: this is arithmetic over a width, with no visionOS-only
 API in it, so it is testable on the host and reusable off-headset.
 */

#if canImport(SwiftUI)

import SwiftUI

/// Column sizing for gallery grids.
///
/// `.adaptive` fills the width but cannot express a column-count *floor* — it
/// just drops to fewer, larger columns as the window narrows. These grids want
/// the opposite: once the window is too narrow to fit the minimum count at the
/// preferred size, the cells should shrink and the count should hold.
///
/// So the count is chosen manually (the same count `.adaptive(minimum:)` would
/// pick) and the columns are `.flexible()`, which expand to fill the width like
/// `.adaptive` does. That keeps the grid hugging the window edges so resize
/// grabbers don't float, lets spacing grow smoothly within a band instead of
/// snapping, and keeps the columns array stable while only the cell size
/// changes — so the scroll position survives a resize.
public enum RAVEGridColumnLayout {
    public struct Resolution: Sendable, Equatable {
        public let columnCount: Int
        public let columnWidth: CGFloat
        public let spacing: CGFloat

        public init(columnCount: Int, columnWidth: CGFloat, spacing: CGFloat) {
            self.columnCount = columnCount
            self.columnWidth = columnWidth
            self.spacing = spacing
        }
    }

    /// The count and cell width for a container width. Pure arithmetic, so it
    /// is testable without a view.
    ///
    /// - Parameters:
    ///   - width: container width; `<= 0` falls back to `minColumns` at
    ///     `preferredCellSize`.
    ///   - preferredCellSize: target cell edge — the count is chosen to keep
    ///     cells near this size.
    ///   - minColumns: never lay out fewer than this many columns.
    ///   - spacing: inter-column spacing; must match the `LazyVGrid`'s.
    ///   - contentInset: horizontal padding on the scroll content, so the
    ///     available width is computed correctly.
    public static func resolve(
        width: CGFloat,
        preferredCellSize: CGFloat,
        minColumns: Int,
        spacing: CGFloat = 16,
        contentInset: CGFloat = 16
    ) -> Resolution {
        guard width > 0 else {
            return Resolution(
                columnCount: minColumns, columnWidth: preferredCellSize, spacing: spacing
            )
        }
        let available = Swift.max(preferredCellSize, width - contentInset * 2)
        // The same count `.adaptive(minimum: preferredCellSize)` would pick.
        let natural = Int((available + spacing) / (preferredCellSize + spacing))
        let count = Swift.max(minColumns, natural)
        let columnWidth = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return Resolution(columnCount: count, columnWidth: columnWidth, spacing: spacing)
    }

    /// `resolve`, as `GridItem`s ready for a `LazyVGrid`. Animate on
    /// `columnCount` to make add/remove-a-column slide instead of snap.
    public static func columns(
        width: CGFloat,
        preferredCellSize: CGFloat,
        minColumns: Int,
        spacing: CGFloat = 16,
        contentInset: CGFloat = 16
    ) -> (columns: [GridItem], columnWidth: CGFloat) {
        let resolution = resolve(
            width: width,
            preferredCellSize: preferredCellSize,
            minColumns: minColumns,
            spacing: spacing,
            contentInset: contentInset
        )
        return (
            Array(repeating: GridItem(.flexible(), spacing: spacing), count: resolution.columnCount),
            resolution.columnWidth
        )
    }
}

#endif
