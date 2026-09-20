import SwiftUI

extension Caprine {
    public enum Models {
        public static let spacing: CGFloat = 8
        public static let compactSpacing: CGFloat = 6
        public static let tightSpacing: CGFloat = 3
        public static let sectionSpacing: CGFloat = 16
        public static let inset: CGFloat = 16
        public static let compactInset: CGFloat = 10
        public static let controlInset: CGFloat = 4
        public static let rowInset: CGFloat = 8
        public static let cornerRadius: CGFloat = 10
        public static let rowCornerRadius: CGFloat = 8
        public static let controlHeight: CGFloat = 30
        public static let iconSize: CGFloat = 24
        public static let listMinWidth: CGFloat = 220
        public static let listIdealWidth: CGFloat = 250
        public static let detailMinWidth: CGFloat = 260
        public static let reportMinWidth: CGFloat = 480
        public static let reportMinHeight: CGFloat = 220
        public static let detailLabelWidth: CGFloat = 150
        public static let editableValueWidth: CGFloat = 96
        public static let dropdownMinHeight: CGFloat = 170
        public static let dropdownHeight: CGFloat = 310
        public static let dropdownOffset: CGFloat = 38
        public static let popoverMinWidth: CGFloat = 210
        public static let borderWidth: CGFloat = 1
        public static let shadowRadius: CGFloat = 14
        public static let shadowOffset: CGFloat = 6
        public static let badgeOpacity = 0.15
        public static let borderOpacity = 0.25
        public static let dropdownBorderOpacity = 0.28
        public static let selectionOpacity = 0.16
        public static let hoverOpacity = 0.06
        public static let unavailableOpacity = 0.72
        public static let shadowOpacity = 0.24
        public static let titleFont: Font = .title2.weight(.semibold)
        public static let iconFont: Font = .title2
        public static let rowTitleFont: Font = .body.weight(.medium)
        public static let detailFont: Font = .callout.monospaced()
        public static let metadataFont: Font = .caption
        public static let badgeFont: Font = .caption2.weight(.medium)
        public static let sectionFont: Font = .caption.weight(.semibold)
    }

    public enum ModelMenu {
        public static let width: CGFloat = 290
        public static let horizontalInset: CGFloat = 12
        public static let verticalInset: CGFloat = 4
        public static let spacing: CGFloat = 6
        public static let maxListHeight: CGFloat = 360
        public static let titleFont: Font = .callout
        public static let detailFont: Font = .caption
        public static let sectionFont: Font = .caption2
        public static let labelFont: Font = .system(size: 12, weight: .medium)
        public static let rowTitleFont: Font = .system(size: 13, weight: .semibold)
        public static let rowDetailFont: Font = .system(size: 11)
        public static let rowIconFont: Font = .system(size: 11, weight: .semibold)
        public static let dividerInset: CGFloat = 4
        public static let systemRowSpacing: CGFloat = 8
        public static let rowSpacing: CGFloat = 9
        public static let rowDetailSpacing: CGFloat = 1
        public static let rowSpacer: CGFloat = 12
        public static let selectedRowSpacer: CGFloat = 16
        public static let iconSize: CGFloat = 16
    }
}
