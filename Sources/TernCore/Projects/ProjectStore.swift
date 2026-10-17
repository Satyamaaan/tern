import Foundation
import GRDB

/// Creates and edits projects, their rules, and manual thread assignments. Rule edits recompute
/// membership in the same transaction, so lists never show a stale project.
public struct ProjectStore: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    // MARK: Projects

    /// Adds a project at the end of the sidebar.
    @discardableResult
    public func create(name: String, colorIndex: Int = 0, icon: String? = nil) throws -> Project {
        try database.writer.write { db in
            let last = try Int.fetchOne(db, sql: "SELECT max(sortOrder) FROM project") ?? -1
            let project = Project(name: name, colorIndex: colorIndex, icon: icon, sortOrder: last + 1)
            try project.insert(db)
            return project
        }
    }

    public func rename(_ id: String, to name: String) throws {
        try update(id) { $0.name = name }
    }

    public func recolor(_ id: String, colorIndex: Int) throws {
        try update(id) { $0.colorIndex = colorIndex }
    }

    public func setIcon(_ id: String, icon: String?) throws {
        try update(id) { $0.icon = icon }
    }

    /// Sets the sidebar order to `ids`; projects not listed keep their relative order after them.
    public func reorder(_ ids: [String]) throws {
        try database.writer.write { db in
            let all = try Project.order(Column("sortOrder"), Column("name")).fetchAll(db)
            let listed = ids.compactMap { id in all.first { $0.id == id } }
            let rest = all.filter { !ids.contains($0.id) }
            for (index, var project) in (listed + rest).enumerated() where project.sortOrder != index {
                project.sortOrder = index
                try project.update(db)
            }
        }
    }

    /// Deletes the project with its rules and thread assignments.
    public func delete(_ id: String) throws {
        try database.writer.write { db in _ = try Project.deleteOne(db, key: id) }
    }

    private func update(_ id: String, _ change: @Sendable (inout Project) -> Void) throws {
        try database.writer.write { db in
            guard var project = try Project.fetchOne(db, key: id) else { return }
            change(&project)
            try project.update(db)
        }
    }

    // MARK: Rules

    public func rules(projectId: String) throws -> [ProjectRule] {
        try database.reader.read { db in
            try ProjectRule.filter(Column("projectId") == projectId).order(Column("id")).fetchAll(db)
        }
    }

    /// Adds a rule and pulls in every thread it matches.
    @discardableResult
    public func addRule(projectId: String, field: ProjectRule.Field, value: String) throws -> ProjectRule {
        try database.writer.write { db in
            var rule = ProjectRule(projectId: projectId, field: field, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
            try rule.insert(db)
            rule.id = db.lastInsertedRowID
            try ProjectRules.recomputeAll(db, projectId: projectId)
            return rule
        }
    }

    /// Replaces a rule's field and value and recomputes its project.
    public func updateRule(_ rule: ProjectRule) throws {
        try database.writer.write { db in
            var rule = rule
            rule.value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            try rule.update(db)
            try ProjectRules.recomputeAll(db, projectId: rule.projectId)
        }
    }

    /// Removes a rule; threads only it matched leave the project.
    public func removeRule(id: Int64) throws {
        try database.writer.write { db in
            guard let rule = try ProjectRule.fetchOne(db, key: id) else { return }
            try rule.delete(db)
            try ProjectRules.recomputeAll(db, projectId: rule.projectId)
        }
    }

    // MARK: Threads

    /// Puts threads in a project by hand. Manual assignments survive rule changes.
    public func assign(_ keys: [ThreadKey], to projectId: String) throws {
        try database.writer.write { db in
            for key in keys {
                try ThreadProject(accountId: key.accountId, threadId: key.threadId, projectId: projectId, source: .manual).upsert(db)
            }
        }
    }

    /// Takes threads out of a project, whatever put them there. A matching rule adds them back the
    /// next time it is evaluated for those threads.
    public func unassign(_ keys: [ThreadKey], from projectId: String) throws {
        try database.writer.write { db in
            for key in keys {
                try db.execute(sql: """
                    DELETE FROM thread_project WHERE accountId = ? AND threadId = ? AND projectId = ?
                    """, arguments: [key.accountId, key.threadId, projectId])
            }
        }
    }

    /// Drops every AI-suggested assignment, e.g. when the user turns off automatic projects.
    public func removeAIAssignments() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM thread_project WHERE source = ?", arguments: [ThreadProject.Source.ai])
        }
    }
}
