import Foundation

public struct KeyvaultCLIErrorOutput {
    public let exitCode: Int32
    public let message: String

    public init(error: Error) {
        exitCode = 1
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }
    }
}
