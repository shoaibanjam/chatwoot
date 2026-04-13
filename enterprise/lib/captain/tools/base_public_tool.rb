require 'agents'

class Captain::Tools::BasePublicTool < Agents::Tool
  class << self
    # RubyLLM registers tools by Tool#name. The default derives from the full constant path
    # (e.g. captain--tools--faq_lookup), while prompts and models usually emit the short id from
    # config/agents/tools.yml (e.g. faq_lookup). A mismatch yields tools[name] == nil and
    # RubyLLM raises NoMethodError: undefined method `call' for nil.
    def captain_tool_id
      demod = name.demodulize
      base = demod.delete_suffix('Tool')
      base.underscore.tr('-', '_')
    end
  end

  def name
    self.class.captain_tool_id
  end

  def initialize(assistant)
    @assistant = assistant
    super()
  end

  def active?
    # Public tools are always active
    true
  end

  def permissions
    # Override in subclasses to specify required permissions
    # Returns empty array for public tools (no permissions required)
    []
  end

  private

  def account_scoped(model_class)
    model_class.where(account_id: @assistant.account_id)
  end

  def find_conversation(state)
    conversation_id = state&.dig(:conversation, :id)
    return nil unless conversation_id

    account_scoped(::Conversation).find_by(id: conversation_id)
  end

  def find_contact(state)
    contact_id = state&.dig(:contact, :id)
    return nil unless contact_id

    account_scoped(::Contact).find_by(id: contact_id)
  end

  def log_tool_usage(action, details = {})
    Rails.logger.info do
      "#{self.class.name}: #{action} for assistant #{@assistant&.id} - #{details.inspect}"
    end
  end
end
