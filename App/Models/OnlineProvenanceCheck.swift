import Foundation

/// The optional online check of an original image with OpenAI. Kept in memory
/// only, apart from `status` and `inspection`, because it says nothing about
/// cleaning and isn't part of the offline checks.
struct OnlineProvenanceCheck: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case finished(ProvenanceCheckResult)
        case failed(String)
    }

    var state: State
    /// The original as it was when it was sent. A finished check of the same
    /// file isn't sent again; a changed file can be checked anew.
    let fingerprint: FileFingerprint?
    let checkedAt: Date
}
