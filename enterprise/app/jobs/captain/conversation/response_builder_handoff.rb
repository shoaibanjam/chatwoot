module Captain::Conversation::ResponseBuilderHandoff
  private

  def create_handoff_private_note
    Captain::HandoffPrivateNoteService.new(
      conversation: @conversation,
      sender: @assistant,
      content: handoff_private_note_content
    ).perform
  end

  def handoff_private_note_content
    if @handoff_error.present?
      reasoning = response_reasoning_for_handoff_note
      return reasoning if reasoning.present?

      return I18n.t('conversations.captain.handoff_private_note.fallback_error',
                    error_class: @handoff_error.class.name)
    end

    reasoning = response_reasoning_for_handoff_note
    return reasoning if reasoning.present?

    I18n.t('conversations.captain.handoff_private_note.fallback_no_ai_reason')
  end

  def response_reasoning_for_handoff_note
    return if @response.blank?

    @response.with_indifferent_access[:reasoning].to_s.strip.presence
  end
end
