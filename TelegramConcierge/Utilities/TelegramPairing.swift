import Foundation

/// Telegram pairing is private-chat-only by design: Briglia pairs with one
/// human's private chat, whose chat id equals that user's id. This type is
/// the single place that turns the assumption into a rule — at setup time
/// (wizard and setup-api) and on every polled update (ConversationManager).
///
/// Group or channel support would need full per-sender enforcement and is
/// deliberately not offered (AGENTS.md).
enum TelegramPairing {
    enum ChatIdError: Error, Equatable {
        /// Not an integer — usually a @username pasted instead of the id.
        case notNumeric
        /// Zero or negative — Telegram groups, supergroups and channels have
        /// negative ids; a private chat id is the (positive) user id.
        case notPrivate
    }

    static let privateChatExplanation =
        "Briglia pairs with your private chat only, so the chat ID must be your own positive user ID. "
        + "Negative IDs belong to Telegram groups and channels, which are not supported."

    /// Parse a chat id typed by the user or supplied by the companion app.
    static func parseChatId(_ raw: String) -> Result<Int64, ChatIdError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int64(trimmed) else { return .failure(.notNumeric) }
        guard value > 0 else { return .failure(.notPrivate) }
        return .success(value)
    }

    /// Poll gate, fail-closed: a message is processed only when it arrives in
    /// the paired chat, that chat is a private chat, and the sender is the
    /// paired user. Messages without a sender (anonymous admins, `sender_chat`
    /// posts) are dropped. In a genuine private chat all three conditions
    /// always hold, so existing pairings see no behaviour change.
    static func acceptsPolledMessage(chatId: Int, chatType: String, fromId: Int?, pairedChatId: Int?) -> Bool {
        guard let pairedChatId, pairedChatId > 0 else { return false }
        guard chatId == pairedChatId else { return false }
        guard chatType == "private" else { return false }
        guard let fromId, fromId == pairedChatId else { return false }
        return true
    }
}
