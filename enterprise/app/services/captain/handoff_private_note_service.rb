# Creates a private note on the conversation. Prefer AI-authored text passed as +content+;
# callers supply short i18n fallbacks only when the model or integration provides nothing.
class Captain::HandoffPrivateNoteService
  pattr_initialize [:conversation!, :content!, { sender: nil }]

  def perform
    return if conversation.blank?

    text = content.to_s.strip
    return if text.blank?

    conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      sender: sender,
      content: text
    )
  end
end
