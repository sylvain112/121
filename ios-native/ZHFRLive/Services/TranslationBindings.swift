import Foundation

struct TranslationTicket: Sendable {
    let lineID: UUID
    let generation: UUID
    let attemptID: UUID
}

/// Protect both clear/restart and retry from late callbacks, without guessing
/// which sentence a response belongs to from its content or arrival order.
struct TranslationBindings {
    private var generation = UUID()
    private var attempts: [UUID: UUID] = [:]

    mutating func begin(lineID: UUID) -> TranslationTicket {
        let attempt = UUID()
        attempts[lineID] = attempt
        return TranslationTicket(lineID: lineID, generation: generation, attemptID: attempt)
    }

    func accepts(_ ticket: TranslationTicket) -> Bool {
        ticket.generation == generation && attempts[ticket.lineID] == ticket.attemptID
    }

    mutating func finish(_ ticket: TranslationTicket) {
        if accepts(ticket) { attempts.removeValue(forKey: ticket.lineID) }
    }

    mutating func clear() {
        generation = UUID()
        attempts.removeAll()
    }
}
