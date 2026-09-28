import Foundation

/// What went wrong, as a sentence: the core's own words for its errors (their generated
/// description spells out the enum case).
func words(_ error: Error) -> String {
    if case let CoreError.Failed(message) = error {
        return message
    }
    return error.localizedDescription
}
