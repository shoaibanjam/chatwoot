# TODO: Wrap the schema lib under ai-agents
# So we can extend it as Agents::Schema
class Captain::ResponseSchema < RubyLLM::Schema
  string :response, description: 'The message to send to the user'
  string :reasoning,
         description: 'Your reasoning. If handing off to a human, explain why in plain language (saved as a private note for agents).'
end
