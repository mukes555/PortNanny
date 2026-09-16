import Foundation
import PortNannyCore

/// The Workbench's own groupings, as plain functions so they can be tested
/// without a window. Sessions live in `AgentSessions`, which the popover's
/// Agents view renders too.
enum WorkbenchModel {

    struct ProjectGroup: Identifiable {
        let id: String
        let name: String
        let path: String?
        let ports: [PortInfo]
        var memoryKB: Int { ports.reduce(0) { $0 + $1.memorySizeKB } }
        var agents: [String] { Array(Set(ports.compactMap { $0.agentOwner?.name })).sorted() }
    }

    /// One group per working directory; ports without one share "No project".
    static func projects(from ports: [PortInfo]) -> [ProjectGroup] {
        let byPath = Dictionary(grouping: ports) { $0.projectPath ?? "" }
        return byPath.map { path, members in
            let name = path.isEmpty ? "No project" : (members.first?.projectName ?? (path as NSString).lastPathComponent)
            return ProjectGroup(id: path.isEmpty ? "(none)" : path, name: name, path: path.isEmpty ? nil : path,
                                ports: members.sorted { $0.port < $1.port })
        }
        .sorted { a, b in
            // Named projects first, then by size, so the busiest project is on top.
            if (a.path == nil) != (b.path == nil) { return a.path != nil }
            return a.memoryKB != b.memoryKB ? a.memoryKB > b.memoryKB : a.name < b.name
        }
    }

    /// The badge counts, without building the groups.
    static func projectCount(of ports: [PortInfo]) -> Int {
        Set(ports.map { $0.projectPath ?? "" }).count
    }

}

/// Sortable, non-optional views of a port for the table's comparators.
extension PortInfo {
    var projectLabel: String { projectName ?? "" }
    var agentLabel: String { agentOwner?.label ?? "" }
    var managedLabel: String { managedBy?.short ?? "" }
    var ageLabel: String { age ?? "" }
}
