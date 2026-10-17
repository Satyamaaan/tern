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
                .font(.display(18))
                .tracking(-0.2)
                .foregroundStyle(Color(Theme.text1))
                .padding(.bottom, 14)

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
                HStack(spacing: 2) {
                    ForEach(ProjectDraft.icons, id: \.self) { name in
                        let chosen = draft.icon == name
                        let color = Theme.projectColor(draft.colorIndex)
                        Button { draft.icon = name } label: {
                            IconView(icon: .project(name), size: 15, color: Color(chosen ? color : Theme.text2))
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .fill(Color(color).opacity(chosen ? 0.14 : 0)))
                        }
                        .buttonStyle(IconButtonStyle())
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
                    RuleFieldMenu(field: $rule.field)
                    TextField(ProjectDraft.fieldPlaceholder(rule.field), text: $rule.value)
                        .textFieldStyle(.plain)
                        .font(.ui(13))
                    Button {
                        draft.rules.removeAll { $0.id == rule.id }
                    } label: {
                        IconView(icon: .close, size: 14, color: Color(Theme.text3))
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

/// The field a rule matches on: a quiet bordered menu button instead of the stock pop-up.
private struct RuleFieldMenu: View {
    @Binding var field: ProjectRule.Field

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Menu {
            Picker("", selection: $field) {
                ForEach(ProjectDraft.ruleFields, id: \.self) { field in
                    Text(ProjectDraft.fieldTitle(field)).tag(field)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(ProjectDraft.fieldTitle(field)).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                Spacer(minLength: 4)
                // Menu labels drop custom views, so the chevron is a template image.
                Image(nsImage: Icon.chevronDown.image(size: 12)).foregroundStyle(Color(Theme.text3))
            }
            .padding(.horizontal, 10)
            .frame(width: 150, height: Theme.Control.regular)
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(shape.strokeBorder(Color(Theme.hairlineStrong)))
        .fixedSize()
    }
}
