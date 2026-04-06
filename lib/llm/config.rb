require 'ruby_llm'

module Llm::Config
  DEFAULT_MODEL = 'llama3.1:8b'.freeze #'gpt-4.1-mini'

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    def with_api_key(api_key, api_base: nil)
      context = RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = api_base
      end

      yield context
    end

    private

    def configure_ruby_llm
      RubyLLM.configure do |config|
        config.openai_api_key = system_api_key if system_api_key.present?
        config.openai_api_base = openai_endpoint.chomp('/') if openai_endpoint.present?
        # Captain embeddings use RubyLLM's Ollama provider (OpenAI-compatible /v1 API shape).
        config.ollama_api_base = ollama_api_base_url
        config.logger = Rails.logger
      end
    end

    def ollama_api_base_url
      openai_endpoint.present? ? openai_endpoint.chomp('/') : "#{LlmConstants::OPENAI_API_ENDPOINT}/v1"
    end

    def system_api_key
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
    end

    def openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    end
  end
end
