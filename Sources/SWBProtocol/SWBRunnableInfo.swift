import SWBUtil

/// Information about a runnable target, primarily its executable path.
public struct SWBRunnableInfo: Codable, Sendable {
    public let executablePath: AbsolutePath

    public init(executablePath: AbsolutePath) {
        self.executablePath = executablePath
    }
} 