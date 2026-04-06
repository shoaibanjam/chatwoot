class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end

  # pgvector columns (captain_assistant_responses, article_embeddings) use vector(1536).
  STORED_EMBEDDING_DIMENSIONS = 1536

  def initialize(account_id: nil)
    Llm::Config.initialize!
    @account_id = account_id
    @embedding_model = InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  def self.embedding_model
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  def get_embedding(content, model: @embedding_model)
    return [] if content.blank?

    instrument_embedding_call(instrumentation_params(content, model)) do
      embedding = RubyLLM.embed(
        content,
        model: model,
        provider: :ollama,
        assume_model_exists: true
      ).vectors
      normalize_embedding_dimensions(embedding)
    end
  rescue RubyLLM::Error, RubyLLM::ModelNotFoundError => e
    Rails.logger.error "Embedding API Error: #{e.message}"
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def normalize_embedding_dimensions(embedding)
    return embedding if embedding.blank? || !embedding.is_a?(Array)

    dim = STORED_EMBEDDING_DIMENSIONS
    if embedding.length < dim
      embedding + Array.new(dim - embedding.length, 0.0)
    elsif embedding.length > dim
      embedding.first(dim)
    else
      embedding
    end
  end

  def instrumentation_params(content, model)
    {
      span_name: 'llm.captain.embedding',
      model: model,
      input: content,
      feature_name: 'embedding',
      account_id: @account_id
    }
  end
end
