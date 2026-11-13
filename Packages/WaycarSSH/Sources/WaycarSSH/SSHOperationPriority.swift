/// How urgently the work running in the current task needs the SSH session.
///
/// One SSH session serializes every libssh2 call behind one operation mutex
/// and admits channel opens through a bounded set of open slots. When several
/// operations wait for either, `SessionDriver` resumes `.interactive` waiters
/// before `.normal` ones and keeps first-come-first-served order within each
/// class. Nothing already running is preempted: priority only decides who
/// goes next.
///
/// Callers opt in for the work a person is watching, such as attaching a
/// terminal:
///
/// ```swift
/// try await SSHOperationPriority.$current.withValue(.interactive) {
///     try await connection.openPTY(command: command, columns: 80, rows: 24, timeout: budget)
/// }
/// ```
///
/// Background cleanup a call leaves behind (the close of a one-shot channel)
/// inherits the priority of the call that started it.
public enum SSHOperationPriority: Sendable, Equatable {
    case normal
    case interactive

    /// The priority of the SSH work started from the current task.
    @TaskLocal public static var current: SSHOperationPriority = .normal
}

/// Waiters in the order `SessionDriver` resumes them: every `.interactive`
/// waiter before any `.normal` one, first come first served within a class.
struct PriorityWaiterQueue<Element> {
    private var interactive: [Element] = []
    private var normal: [Element] = []

    var count: Int { interactive.count + normal.count }
    var isEmpty: Bool { interactive.isEmpty && normal.isEmpty }

    mutating func append(_ element: Element, priority: SSHOperationPriority) {
        switch priority {
        case .interactive: interactive.append(element)
        case .normal: normal.append(element)
        }
    }

    /// Removes and returns the waiter to resume next.
    mutating func popFirst() -> Element? {
        if !interactive.isEmpty { return interactive.removeFirst() }
        if !normal.isEmpty { return normal.removeFirst() }
        return nil
    }

    /// Removes and returns the first waiter matching `predicate`, leaving the
    /// order of the rest unchanged.
    mutating func remove(where predicate: (Element) -> Bool) -> Element? {
        if let index = interactive.firstIndex(where: predicate) {
            return interactive.remove(at: index)
        }
        if let index = normal.firstIndex(where: predicate) {
            return normal.remove(at: index)
        }
        return nil
    }

    /// Empties the queue, returning every waiter in resume order.
    mutating func removeAll() -> [Element] {
        let all = interactive + normal
        interactive.removeAll()
        normal.removeAll()
        return all
    }
}
