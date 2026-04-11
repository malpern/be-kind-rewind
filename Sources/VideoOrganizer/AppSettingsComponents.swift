import SwiftUI

struct AppSettingsPaneContainer<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Form {
                content
            }
            .formStyle(.grouped)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AppSettingsSection<Content: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.vertical, 4)
        } header: {
            Text(title)
                .font(.headline)
        } footer: {
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AppSettingsStatusRow: View {
    let title: String
    let message: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.body)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AppSettingsMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(.body.monospacedDigit())
        }
    }
}

struct AppSettingsButtonRow: View {
    let buttons: [AppSettingsButtonSpec]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(buttons) { button in
                Button(button.title, role: button.role, action: button.action)
                    .disabled(button.isDisabled)
            }

            Spacer()
        }
    }
}

struct AppSettingsButtonSpec: Identifiable {
    let id = UUID()
    let title: String
    let role: ButtonRole?
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        role: ButtonRole? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.isDisabled = isDisabled
        self.action = action
    }
}

struct AppSettingsMessageRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AppSettingsEventRow: View {
    let title: String
    let detail: String
    let trailing: String
    let success: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(success ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(trailing)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
