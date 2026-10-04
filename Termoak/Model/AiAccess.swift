import TermoakKit
import Foundation

/// AI errors that are fixed in Settings → AI: the plan has no server AI and
/// there is no API key of your own, or this month's credit is spent.
enum AiAccessProblem: Equatable {
    case keyRequired
    case budgetExceeded

    /// `nil` for any other error.
    init?(_ error: Error) {
        guard let e = error as? TermoakError else { return nil }
        switch e {
        case .AiKeyRequired: self = .keyRequired
        case .AiBudgetExceeded: self = .budgetExceeded
        default: return nil
        }
    }

    /// Message to show instead of the server's (English) one.
    var message: String {
        switch self {
        case .keyRequired: return String(localized: "ai.error.key_required")
        case .budgetExceeded: return String(localized: "ai.error.budget_exceeded")
        }
    }
}

/// Amount in US dollars, as the server counts the AI credit.
func formatUsd(_ value: Double) -> String {
    value.formatted(.currency(code: "USD"))
}
