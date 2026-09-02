import Foundation

/// Todo item matching Claude Code's shape exactly.
struct Todo: Codable, Sendable, Equatable {
    /// Task description — past/present tense noun form.
    var content: String
    /// Imperative / active form ("Writing X", "Fixing Y"). Shown while
    /// the task is in progress.
    var activeForm: String
    /// One of: "pending", "in_progress", "completed".
    var status: String
}

/// Persistent, singleton todo list. Replaced in-place by each todo_write
/// call (same semantics as Claude Code's TodoWrite). Persisted to
/// ~/.local/share/briglia/todos.json so the list
/// survives /newsession and app restarts.
actor TodoStore {
    static let shared = TodoStore()

    private var todos: [Todo] = []
    private var loaded = false

    private var storeURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("todos.json")
    }

    private init() {}

    // MARK: - API

    func current() -> [Todo] {
        loadIfNeeded()
        return todos
    }

    /// Replace the todo list in its entirety. Matches TodoWrite contract:
    /// callers send the full desired state every time, not incremental diffs.
    func replace(with newTodos: [Todo]) throws -> [Todo] {
        loadIfNeeded()
        try validate(newTodos)
        todos = newTodos
        persist()
        return todos
    }

    /// Wipe all todos (in-memory and on-disk). Used by Settings ▸ Delete Memory.
    func clearAll() {
        loadIfNeeded()
        todos.removeAll()
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Reload todos after a Mind restore replaces the backing JSON file.
    func reloadFromDisk() {
        todos.removeAll()
        loaded = false
        loadIfNeeded()
    }

    // MARK: - Private

    private func loadIfNeeded() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? JSONDecoder().decode([Todo].self, from: data) {
            todos = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(todos) {
            try? PrivateStorage.writeAtomically(data, to: storeURL)
        }
    }

    private func validate(_ todos: [Todo]) throws {
        for (i, t) in todos.enumerated() {
            guard ["pending", "in_progress", "completed"].contains(t.status) else {
                throw TodoError.invalidStatus(index: i, got: t.status)
            }
            guard !t.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TodoError.emptyContent(index: i)
            }
            guard !t.activeForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TodoError.emptyActiveForm(index: i)
            }
        }
        let inProgress = todos.filter { $0.status == "in_progress" }.count
        guard inProgress <= 1 else {
            throw TodoError.multipleInProgress(count: inProgress)
        }
    }
}

enum TodoError: Error, CustomStringConvertible {
    case invalidStatus(index: Int, got: String)
    case emptyContent(index: Int)
    case emptyActiveForm(index: Int)
    case multipleInProgress(count: Int)

    var description: String {
        switch self {
        case .invalidStatus(let i, let got):
            return "todo[\(i)]: status must be 'pending', 'in_progress', or 'completed' — got '\(got)'"
        case .emptyContent(let i):
            return "todo[\(i)]: content must not be empty"
        case .emptyActiveForm(let i):
            return "todo[\(i)]: activeForm must not be empty"
        case .multipleInProgress(let count):
            return "only one todo may be 'in_progress' at a time — got \(count)"
        }
    }
}
