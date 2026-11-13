import Foundation
import Testing

@testable import WaycarSSH

@Test("interactive waiters resume before normal ones, in arrival order within each")
func interactiveWaitersResumeFirstInArrivalOrder() {
    var queue = PriorityWaiterQueue<String>()
    queue.append("normal-1", priority: .normal)
    queue.append("interactive-1", priority: .interactive)
    queue.append("normal-2", priority: .normal)
    queue.append("interactive-2", priority: .interactive)
    #expect(queue.count == 4)

    var resumed: [String] = []
    while let next = queue.popFirst() { resumed.append(next) }
    #expect(resumed == ["interactive-1", "interactive-2", "normal-1", "normal-2"])
    #expect(queue.isEmpty)
}

@Test("a waiter removed early leaves the others in their resume order")
func removingAWaiterKeepsTheRestInOrder() {
    var queue = PriorityWaiterQueue<Int>()
    for id in 1...3 { queue.append(id, priority: .normal) }
    queue.append(4, priority: .interactive)

    #expect(queue.remove(where: { $0 == 2 }) == 2)
    #expect(queue.remove(where: { $0 == 9 }) == nil)
    #expect(queue.removeAll() == [4, 1, 3])
    #expect(queue.popFirst() == nil)
}

@Test("the task-local priority defaults to normal and scopes to its block")
func operationPriorityIsTaskLocal() async {
    #expect(SSHOperationPriority.current == .normal)
    await SSHOperationPriority.$current.withValue(.interactive) {
        #expect(SSHOperationPriority.current == .interactive)
        // Background work a call leaves behind inherits its priority.
        let inherited = await Task { SSHOperationPriority.current }.value
        #expect(inherited == .interactive)
    }
    #expect(SSHOperationPriority.current == .normal)
}

@Test("line matching scans each complete line once and skips a partial one")
func lineMatchingScansCompleteLinesOnce() {
    var scanned = 0
    var seen: [String] = []
    let first = Data("banner\nMOSH CONNECT 60001 ke".utf8)
    let none = SessionDriver.firstMatchingLine(in: first, after: &scanned) { line in
        seen.append(line)
        return line.hasPrefix("MOSH CONNECT ")
    }
    #expect(none == nil)
    #expect(scanned == "banner\n".utf8.count)

    let complete = first + Data("y\nafter\n".utf8)
    let match = SessionDriver.firstMatchingLine(in: complete, after: &scanned) { line in
        seen.append(line)
        return line.hasPrefix("MOSH CONNECT ")
    }
    #expect(match == "MOSH CONNECT 60001 key")
    #expect(seen == ["banner", "MOSH CONNECT 60001 key"])
    #expect(scanned == "banner\nMOSH CONNECT 60001 key\n".utf8.count)
}
