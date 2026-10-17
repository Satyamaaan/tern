import SwiftUI
import TernCore

/// Create or edit a project: name, colour, icon and the rules that file mail into it.
struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @State var draft: ProjectDraft
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.isNew ? "New project" : "Edit project")
                .font(.ui(15, .semibold))
                .foregroundStyle(Color(Theme.text1))
                .padding(.bottom, 16)

            field("Name") {
                TextField("Acme redesign", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.ui(13))
                    .focused($nameFocused)
                    .onSubmit(save)
            }
            Hairline()
            field("Colour") {
                HStack(spacing: 8) {
                    ForEach(Theme.projectHues.indices, id: \.self) { index in
                        Circle()
                            .fill(Color(Theme.projectColor(index)))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color(Theme.text1), lineWidth: draft.colorIndex == index ? 2 : 0).padding(-3))
                            .onTapGesture { draft.colorIndex = index }
                            .help(Theme.projectColorNames[index])
                    }
                }
            }
            Hairline()
            field("Icon") {
                HStack(spacing: 4) {
                    ForEach(ProjectDraft.icons, id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(draft.icon == icon ? Theme.projectColor(draft.colorIndex) : Theme.text2))
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(Theme.selected).opacity(draft.icon == icon ? 1 : 0)))
                            .contentShape(Rectangle())
                            .onTapGesture { draft.icon = icon }
                    }
                }
            }
            Hairline()

            HStack {
                CapsLabel(text: "Rules")
                Spacer()
                Button("Add rule") { draft.rules.append(.init(field: .fromDomain, value: "")) }
                    .buttonStyle(.plain)
                    .font(.ui(12, .medium))
                    .foregroundStyle(Color(Theme.accentInk))
            }
            .padding(.top, 16)
            .padding(.bottom, 6)
            Text("Mail matching any rule joins the project, in every account.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .padding(.bottom, 8)
            ForEach($draft.rules) { $rule in
                HStack(spacing: 8) {
                    Picker("", selection: $rule.field) {
                        ForEach(ProjectDraft.ruleFields, id: \.self) { field in
                            Text(ProjectDraft.fieldTitle(field)).tag(field)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    TextField(ProjectDraft.fieldPlaceholder(rule.field), text: $rule.value)
                        .textFieldStyle(.plain)
                        .font(.ui(13))
                    Button {
                        draft.rules.removeAll { $0.id == rule.id }
                    } label: {
                        IconView(icon: .plus, size: 12, color: Color(Theme.text3)).rotationEffect(.degrees(45))
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 32)
                Hairline()
            }

            Spacer(minLength: 20)
            HStack {
                Spacer()
                Button("Cancel") { model.projectEditor = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PillButtonStyle(primary: false))
                Button(draft.isNew ? "Create project" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle(primary: true))
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .background(Color(Theme.raised))
        .onAppear { nameFocused = true }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text2))
                .frame(width: 70, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(height: 40)
    }

    private func save() { model.saveProject(draft) }
}

/// The spec's pill buttons: primary = accent fill, secondary = hairline outline.
struct PillButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, .medium))
            .foregroundStyle(Color(primary ? Theme.onAccent : Theme.text1))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                Capsule().fill(primary ? Color(Theme.primaryFill) : Color(Theme.hover).opacity(configuration.isPressed ? 1 : 0))
            )
            .overlay(Capsule().strokeBorder(Color(Theme.hairlineStrong), lineWidth: primary ? 0 : 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(Capsule())
    }
}
