# rubocop:disable Metrics/ClassLength -- Captain response paths (V2, handoff, WhatsApp carousel) live together
class Captain::Conversation::ResponseBuilderJob < ApplicationJob
  include Captain::Conversation::ResponseBuilderHandoff

  MAX_MESSAGE_LENGTH = 10_000
  MAX_INTERACTIVE_ITEMS = 10
  retry_on ActiveStorage::FileNotFoundError, attempts: 3, wait: 2.seconds
  retry_on Faraday::BadRequestError, attempts: 3, wait: 2.seconds

  def perform(conversation, assistant)
    @conversation = conversation
    @inbox = conversation.inbox
    @assistant = assistant

    Current.executed_by = @assistant

    show_whatsapp_typing_while_ai_processes

    Rails.logger.info "Captain::Conversation::ResponseBuilderJob: captain_v2_enabled? #{captain_v2_enabled?}"
    if captain_v2_enabled?
      generate_response_with_v2
    else
      ActiveRecord::Base.transaction do
        generate_and_process_response
      end
    end
  rescue StandardError => e
    raise e if e.is_a?(ActiveStorage::FileNotFoundError) || e.is_a?(Faraday::BadRequestError)

    handle_error(e)
  ensure
    Current.executed_by = nil
  end

  private

  def show_whatsapp_typing_while_ai_processes
    Whatsapp::TypingIndicatorService.new(conversation: @conversation).perform
  end

  delegate :account, :inbox, to: :@conversation

  def generate_and_process_response
    @response = Captain::Llm::AssistantChatService.new(assistant: @assistant, conversation_id: @conversation.display_id).generate_response(
      message_history: collect_previous_messages
    )
    process_response
  end

  def generate_response_with_v2
    @response = Captain::Assistant::AgentRunnerService.new(assistant: @assistant, conversation: @conversation).generate_response(
      message_history: collect_previous_messages
    )
    Rails.logger.info "Captain::Conversation::ResponseBuilderJob: @response #{@response}"
    process_response
  end

  def process_response
    return process_action('handoff') if handoff_requested?

    create_messages
    Rails.logger.info("[CAPTAIN][ResponseBuilderJob] Incrementing response usage for #{account.id}")
    account.increment_response_usage
  end

  def collect_previous_messages
    @conversation
      .messages
      .where(message_type: [:incoming, :outgoing])
      .where(private: false)
      .map do |message|
      message_hash = {
        content: prepare_multimodal_message_content(message),
        role: determine_role(message)
      }

      # Include agent_name if present in additional_attributes
      message_hash[:agent_name] = message.additional_attributes['agent_name'] if message.additional_attributes&.dig('agent_name').present?

      message_hash
    end
  end

  def determine_role(message)
    message.message_type == 'incoming' ? 'user' : 'assistant'
  end

  def prepare_multimodal_message_content(message)
    Captain::OpenAiMessageBuilderService.new(message: message).generate_content
  end

  def handoff_requested?
    @response.with_indifferent_access[:response].to_s == 'conversation_handoff'
  end

  def process_action(action)
    case action
    when 'handoff'
      I18n.with_locale(@assistant.account.locale) do
        create_handoff_private_note
        create_handoff_message
        @conversation.bot_handoff!
        send_out_of_office_message_if_applicable
      end
      @handoff_error = nil
    end
  end

  def send_out_of_office_message_if_applicable
    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(@conversation)
  end

  def create_handoff_message
    create_outgoing_message(
      @assistant.config['handoff_message'].presence || I18n.t('conversations.captain.handoff')
    )
  end

  def create_messages
    items = normalized_interactive_items
    if items.size > 1 && whatsapp_carousel_eligible?(items)
      create_whatsapp_carousel_outgoing_message(items)
    elsif items.size > 1
      create_interactive_outgoing_message(items)
    else
      text = plain_response_text
      validate_message_content!(text)
      create_outgoing_message(text, agent_name: @response.with_indifferent_access[:agent_name])
    end
  end

  def plain_response_text
    @response.with_indifferent_access[:response].to_s
  end

  def normalized_interactive_items
    interactive = @response.with_indifferent_access[:interactive]
    return [] unless interactive.is_a?(Hash)

    items = interactive.with_indifferent_access[:items]
    return [] unless items.is_a?(Array)

    items.filter_map { |entry| normalize_interactive_item(entry) }.first(MAX_INTERACTIVE_ITEMS)
  end

  def normalize_interactive_item(entry)
    return nil unless entry.is_a?(Hash)

    h = entry.with_indifferent_access
    title = h[:title].to_s.strip
    value = h[:value].to_s.strip
    return nil if title.blank? || value.blank?

    item = { 'title' => title, 'value' => value }
    %w[media_url description].each do |key|
      str = h[key].to_s.strip
      item[key] = str if str.present?
    end
    item
  end

  def whatsapp_carousel_eligible?(items)
    return false unless @inbox.whatsapp?

    return false if items.size < Whatsapp::InteractiveCarouselPayloadBuilder::MIN_CARDS

    items.all? do |i|
      i['media_url'].present? &&
        i['value'].to_s.match?(%r{\Ahttps?://}i)
    end
  end

  def create_whatsapp_carousel_outgoing_message(items)
    body_text = interactive_body_text
    validate_message_content!(body_text)
    card_items = build_captain_carousel_items(items)

    additional_attrs = {}
    agent_name = @response.with_indifferent_access[:agent_name]
    additional_attrs[:agent_name] = agent_name if agent_name.present?

    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: body_text,
      content_type: :cards,
      content_attributes: { 'items' => card_items },
      additional_attributes: additional_attrs
    )
  end

  def build_captain_carousel_items(items)
    cta_label = I18n.t('conversations.messages.whatsapp.carousel_cta_default')
    items.map do |i|
      {
        'title' => i['title'],
        'description' => i['description'].to_s,
        'media_url' => i['media_url'],
        'actions' => [
          { 'type' => 'link', 'text' => cta_label, 'uri' => i['value'] }
        ]
      }
    end
  end

  def create_interactive_outgoing_message(items)
    body_text = interactive_body_text
    validate_message_content!(body_text)

    additional_attrs = {}
    agent_name = @response.with_indifferent_access[:agent_name]
    additional_attrs[:agent_name] = agent_name if agent_name.present?

    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: body_text,
      content_type: :input_select,
      content_attributes: { 'items' => items },
      additional_attributes: additional_attrs
    )
  end

  def interactive_body_text
    r = @response.with_indifferent_access
    interactive = r[:interactive]
    return r[:response].to_s unless interactive.is_a?(Hash)

    interactive.with_indifferent_access[:body].presence || r[:response].to_s
  end

  def validate_message_content!(content)
    raise ArgumentError, 'Message content cannot be blank' if content.blank?
  end

  def create_outgoing_message(message_content, agent_name: nil)
    additional_attrs = {}
    additional_attrs[:agent_name] = agent_name if agent_name.present?

    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: message_content,
      additional_attributes: additional_attrs
    )
  end

  def handle_error(error)
    log_error(error)
    @handoff_error = error
    process_action('handoff')
    true
  end

  def log_error(error)
    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  def captain_v2_enabled?
    account.feature_enabled?('captain_integration_v2')
  end
end
# rubocop:enable Metrics/ClassLength
