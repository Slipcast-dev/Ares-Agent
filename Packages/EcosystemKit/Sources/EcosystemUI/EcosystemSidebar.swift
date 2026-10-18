import SwiftUI

/// Единый визуальный язык двух отдельных приложений. UI вынесен в отдельный
/// target: Foundation-контракты и фоновые исполнители не зависят от SwiftUI.
public enum EcosystemSidebarStyle {
    public static let titleSize: CGFloat = 12
    public static let labelSize: CGFloat = 16
    public static let iconSize: CGFloat = 20
    public static let iconWidth: CGFloat = 22
    public static let iconGap: CGFloat = 10
    public static let rowHeight: CGFloat = 34
    public static let horizontalInset: CGFloat = 10
    public static let selectionRadius: CGFloat = 9
    public static let selectionInset: CGFloat = 16
    public static let accent = Color(.sRGB, red: 0, green: 122.0 / 255.0, blue: 1, opacity: 1)
    public static let titleColor = Color.primary.opacity(0.7)
    public static let minimumWidth: CGFloat = 200
    public static let idealWidth: CGFloat = 220
    public static let maximumWidth: CGFloat = 280
}

public struct EcosystemSidebarItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public init(id: String, title: String, symbol: String) {
        self.id = id; self.title = title; self.symbol = symbol
    }
}

/// Компонент принимает только элементы навигации и selection. Он не знает о
/// сервисах, БД, правах и подключениях другого приложения и не запускает задачи.
public struct EcosystemSidebar: View {
    private let title: String
    private let items: [EcosystemSidebarItem]
    @Binding private var selection: String?
    public init(title: String, items: [EcosystemSidebarItem], selection: Binding<String?>) {
        self.title = title; self.items = items; _selection = selection
    }
    public var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    Button { selection = item.id } label: {
                        HStack(spacing: EcosystemSidebarStyle.iconGap) {
                            Image(systemName: item.symbol)
                                .font(.system(size: EcosystemSidebarStyle.iconSize, weight: .regular))
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(selection == item.id ? Color.white : EcosystemSidebarStyle.accent)
                                .frame(width: EcosystemSidebarStyle.iconWidth)
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(.system(size: EcosystemSidebarStyle.labelSize,
                                              weight: selection == item.id ? .bold : .regular))
                                .foregroundStyle(selection == item.id ? Color.white : Color.primary)
                                .lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: EcosystemSidebarStyle.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: EcosystemSidebarStyle.selectionRadius)
                            .fill(selection == item.id ? EcosystemSidebarStyle.accent : Color.clear)
                            .padding(.horizontal, EcosystemSidebarStyle.selectionInset)
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: EcosystemSidebarStyle.horizontalInset,
                                              bottom: 0, trailing: EcosystemSidebarStyle.horizontalInset))
                }
            } header: {
                Text(title).font(.system(size: EcosystemSidebarStyle.titleSize, weight: .semibold))
                    .foregroundStyle(EcosystemSidebarStyle.titleColor)
                    .textCase(nil).accessibilityAddTraits(.isHeader)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, EcosystemSidebarStyle.rowHeight)
        .tint(EcosystemSidebarStyle.accent)
        .navigationTitle(title)
        .onMoveCommand { direction in
            if let next = Self.destination(in: items.map(\.id), from: selection, direction: direction) {
                selection = next
            }
        }
    }
    public static func destination(in ids: [String], from selected: String?, direction: MoveCommandDirection) -> String? {
        guard !ids.isEmpty else { return nil }
        let current = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        switch direction {
        case .up: return ids[max(0, current - 1)]
        case .down: return ids[min(ids.count - 1, current + 1)]
        default: return nil
        }
    }
}
