import Foundation

struct Message: Identifiable, Codable, Hashable {
    enum Speaker: String, Codable {
        case user, assistant
    }

    let id: UUID
    var speaker: Speaker
    var text: String
    var timestamp: Date
    
    // Performance metrics for assistant responses
    var timeToFirstToken: TimeInterval?
    var tokensPerSecond: Double?
    var totalTokens: Int?

    init(id: UUID = UUID(),
         speaker: Speaker,
         text: String,
         timestamp: Date = Date(),
         timeToFirstToken: TimeInterval? = nil,
         tokensPerSecond: Double? = nil,
         totalTokens: Int? = nil) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.timeToFirstToken = timeToFirstToken
        self.tokensPerSecond = tokensPerSecond
        self.totalTokens = totalTokens
    }
}
