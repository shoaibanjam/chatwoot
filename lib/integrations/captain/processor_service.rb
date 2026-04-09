class Integrations::Captain::ProcessorService < Integrations::BotProcessorService
  pattr_initialize [:event_name!, :hook!, :event_data!]

  private

  def get_response(_session_id, message_content)
    call_captain(message_content)
  end

  def process_response(message, response)
    if response == 'conversation_handoff'
      record_external_captain_handoff_note(message.conversation)
      message.conversation.bot_handoff!
    else
      create_conversation(message, { content: response })
    end
  end

  def record_external_captain_handoff_note(conversation)
    return unless defined?(Captain::HandoffPrivateNoteService)

    inbox = conversation.inbox
    assistant = inbox.respond_to?(:captain_assistant) ? inbox.captain_assistant : nil
    I18n.with_locale(conversation.account.locale) do
      Captain::HandoffPrivateNoteService.new(
        conversation: conversation,
        sender: assistant,
        content: I18n.t('conversations.captain.handoff_private_note.fallback_external')
      ).perform
    end
  end

  def create_conversation(message, content_params)
    return if content_params.blank?

    conversation = message.conversation
    conversation.messages.create!(
      content_params.merge(
        {
          message_type: :outgoing,
          account_id: conversation.account_id,
          inbox_id: conversation.inbox_id
        }
      )
    )
  end

  def call_captain(message_content)
    url = "#{GlobalConfigService.load('CAPTAIN_API_URL',
                                      '')}/accounts/#{hook.settings['account_id']}/assistants/#{hook.settings['assistant_id']}/chat"

    headers = {
      'X-USER-EMAIL' => hook.settings['account_email'],
      'X-USER-TOKEN' => hook.settings['access_token'],
      'Content-Type' => 'application/json'
    }

    body = {
      message: message_content,
      previous_messages: previous_messages
    }

    response = HTTParty.post(url, headers: headers, body: body.to_json)
    response.parsed_response['message']
  end

  def previous_messages
    previous_messages = []
    conversation.messages.where(message_type: [:outgoing, :incoming]).where(private: false).offset(1).find_each do |message|
      next if message.content_type != 'text'

      role = determine_role(message)
      previous_messages << { message: message.content, type: role }
    end
    previous_messages
  end

  def determine_role(message)
    message.message_type == 'incoming' ? 'User' : 'Bot'
  end
end
