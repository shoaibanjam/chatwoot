# TODO: Wrap the schema lib under ai-agents
# So we can extend it as Agents::Schema
class Captain::ResponseSchema < RubyLLM::Schema
  string :response, description: 'The message to send to the user'
  string :reasoning,
         description: 'Your reasoning. If handing off to a human, explain why in plain language (saved as a private note for agents).'

  # OpenAI structured outputs require every key to appear; use anyOf(object|null) instead of required: false.
  any_of(:interactive,
         description: 'When the user must pick between 2-10 options, return an object with body and items; otherwise null.') do
    object do
      string :body,
             description: 'Short question or intro above the choices (required when interactive is an object).'
      array :items,
            description: '2-10 choices. title is user-visible (keep under 24 characters when possible); value is internal snake_case.',
            min_items: 2,
            max_items: 10 do
        object do
          string :title, description: 'Label shown to the user.'
          string :value, description: 'Internal value: lowercase snake_case, no spaces.'
        end
      end
    end
    null
  end
end
