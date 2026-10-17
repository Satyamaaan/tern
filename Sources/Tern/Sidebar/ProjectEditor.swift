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
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color(Theme.selected).opacity(draft.icon == icon ? 1 : 0)))
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
                    .buttonStyle(LinkButtonStyle())
                    .font(.ui(12, .medium))
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
                            .frame(width: Theme.Control.small, height: Theme.Control.small)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Remove rule")
                }
                .frame(height: 32)
                Hairline()
            }

            Spacer(minLength: 20)
            HStack {
                Spacer()
                Button("Cancel") { model.projectEditor = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(TernButtonStyle(.secondary))
                Button(draft.isNew ? "Create project" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(TernButtonStyle(.primary))
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
