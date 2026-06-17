import os

public extension Logger {
    /// Unified logging, filterable in Console with
    /// `subsystem == "dev.panes.app"`.
    nonisolated static func panes(_ category: String) -> Logger {
        Logger(subsystem: "dev.panes.app", category: category)
    }
}
