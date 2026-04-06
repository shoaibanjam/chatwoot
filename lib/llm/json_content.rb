# Strips markdown code fences from LLM message bodies before JSON.parse.
# Local models often ignore json_object response_format and wrap output in ```json.
module Llm::JsonContent
  module_function

  def payload_from_llm_message(content)
    text = content.to_s.strip
    return text unless text.start_with?('`')

    text = text.sub(/\A```(?:json)?\s*/i, '')
    text = text.sub(/\s*```\s*\z/, '')
    text.strip
  end
end
