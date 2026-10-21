import Foundation
import TernCore

/// A project being created or edited in the project sheet.
struct ProjectDraft: Identifiable {
    struct Rule: Identifiable, Hashable {
        let id = UUID()
        var field: ProjectRule.Field
        var value: String
    }

    var id: String
    var name: String
    var colorIndex: Int
    var icon: String
    var rules: [Rule]
    var isNew: Bool

    static let icons = ["folder", "paperplane", "paintpalette", "house", "briefcase", "hammer", "book", "heart", "airplane", "cart", "graduationcap", "leaf"]

    /// Fields offered in the rule editor.
    static let ruleFields: [ProjectRule.Field] = [.from, .fromDomain, .subjectContains, .label, .account]

    static func fieldTitle(_ field: ProjectRule.Field) -> String {
        switch field {
        case .from: "From"
        case .fromDomain: "Domain"
        case .to: "To"
        case .subjectContains: "Subject contains"
        case .label: "Label"
        case .account: "Account"
        case .query: "Search"
        }
    }

    static func fieldPlaceholder(_ field: ProjectRule.Field) -> String {
        switch field {
        case .from: "maya@acme.com"
        case .fromDomain: "acme.com"
        case .to: "team@acme.com"
        case .subjectContains: "Invoice"
        case .label: "Clients"
        case .account: "you@work.com"
        case .query: "from:acme has:attachment"
        }
    }
}

extension AppModel {
    func newProject() {
        projectEditor = ProjectDraft(
            id: UUID().uuidString, name: "", colorIndex: projects.count % Theme.projectHues.count, icon: "folder",
            rules: [], isNew: true)
    }

    func editProject(_ project: Project) {
        let rules = (try? store.projectRules(project.id)) ?? []
        projectEditor = ProjectDraft(
            id: project.id, name: project.name, colorIndex: project.colorIndex, icon: project.icon ?? "folder",
            rules: rules.map { ProjectDraft.Rule(field: $0.field, value: $0.value) }, isNew: false)
    }

    func saveProject(_ draft: ProjectDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existing = project(draft.id)
        let project = Project(
            id: draft.id, name: name, colorIndex: draft.colorIndex, icon: draft.icon,
            sortOrder: existing?.sortOrder ?? (projects.map(\.sortOrder).max() ?? -1) + 1,
            createdAt: existing?.createdAt ?? Date())
        let rules = draft.rules
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ProjectRule(projectId: draft.id, field: $0.field, value: $0.value.trimmingCharacters(in: .whitespaces)) }
        let store = self.store
        let changed = services.projectRulesChanged
        writes.async {
            // Name, icon and colour edits keep the rules; only a rule change re-runs them over every thread.
            let stored = try? store.projectRules(project.id)
            do { try store.saveProject(project, rules: rules) } catch { NSLog("Tern: saving project failed: \(error)") }
            if let stored, ProjectRules.sameRules(stored, rules) { return }
            DispatchQueue.main.async { changed(project.id) }
        }
        projectEditor = nil
    }

    func setProjectColor(_ project: Project, _ colorIndex: Int) {
        var updated = project
        updated.colorIndex = colorIndex
        let store = self.store
        writes.async {
            let rules = (try? store.projectRules(project.id)) ?? []
            try? store.saveProject(updated, rules: rules)
        }
    }

    func deleteProject(_ project: Project) {
        if case .project(let id) = kind, id == project.id { show(.inbox) }
        let store = self.store
        writes.async {
            do { try store.deleteProject(project.id) } catch { NSLog("Tern: deleting project failed: \(error)") }
        }
    }
}
