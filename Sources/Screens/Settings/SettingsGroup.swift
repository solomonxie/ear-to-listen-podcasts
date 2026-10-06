import SwiftUI

/// A titled group of rows on one rounded panel — the Settings building block.
struct SettingsGroup<Content: View, Trailing: View>: View {
    let title: LocalizedStringKey
    var info: LocalizedStringKey?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(
        title: LocalizedStringKey, info: LocalizedStringKey? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.info = info
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: title, info: info)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 0) { content() }
                .settingsCard()
        }
    }
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Icon, title, an optional value, and a chevron — a row that opens something.
struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: icon, tint: tint)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: icon, tint: tint)
            Toggle(title, isOn: $isOn)
        }
        .padding(.vertical, 6)
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 40) }
}
