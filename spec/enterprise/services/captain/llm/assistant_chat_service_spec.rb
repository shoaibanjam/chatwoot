require 'rails_helper'

RSpec.describe Captain::Llm::AssistantChatService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:mock_response) do
    instance_double(
      RubyLLM::Message,
      content: '{"response": "I can see the image shows a pricing table", "reasoning": "Analyzed the image"}'
    )
  end

  before do
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPEN_AI_API_KEY').tap do |c|
      c.value = 'test-key'
      c.save!
    end

    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
    allow(mock_chat).to receive(:with_tool).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:add_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_end_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_call).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_result).and_return(mock_chat)
    allow(mock_chat).to receive(:messages).and_return([])
  end

  describe 'image analysis' do
    context 'when user sends a message with an image attachment' do
      let(:message_history) do
        [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'What do you see in this image?' },
              { type: 'image_url', image_url: { url: 'https://example.com/screenshot.png' } }
            ]
          }
        ]
      end

      it 'sends the image to the LLM for analysis' do
        expect(mock_chat).to receive(:ask).with(
          'What do you see in this image?',
          with: ['https://example.com/screenshot.png']
        ).and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation_id: conversation.display_id)
        service.generate_response(message_history: message_history)
      end
    end

    context 'when user sends only an image without text' do
      let(:message_history) do
        [
          {
            role: 'user',
            content: [
              { type: 'image_url', image_url: { url: 'https://example.com/photo.jpg' } }
            ]
          }
        ]
      end

      it 'sends the image to the LLM with nil text' do
        expect(mock_chat).to receive(:ask).with(
          nil,
          with: ['https://example.com/photo.jpg']
        ).and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation_id: conversation.display_id)
        service.generate_response(message_history: message_history)
      end
    end

    context 'when user sends a plain text message' do
      let(:message_history) do
        [
          { role: 'user', content: 'Hello, how can you help me?' }
        ]
      end

      it 'sends the text without attachments' do
        expect(mock_chat).to receive(:ask).with('Hello, how can you help me?').and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation_id: conversation.display_id)
        service.generate_response(message_history: message_history)
      end
    end
  end

  describe 'conversation history with images' do
    context 'when previous messages contain images' do
      let(:message_history) do
        [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Here is my error screenshot' },
              { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
            ]
          },
          { role: 'assistant', content: 'I see the error. Try restarting.' },
          { role: 'user', content: 'It still does not work' }
        ]
      end

      it 'includes images from conversation history in context' do
        # First historical message should include the image via RubyLLM::Content
        expect(mock_chat).to receive(:add_message) do |args|
          expect(args[:role]).to eq(:user)
          expect(args[:content]).to be_a(RubyLLM::Content)
          expect(args[:content].text).to eq('Here is my error screenshot')
          expect(args[:content].attachments.first.source.to_s).to eq('https://example.com/error.png')
        end.ordered

        # Second historical message is plain text
        expect(mock_chat).to receive(:add_message).with(
          role: :assistant,
          content: 'I see the error. Try restarting.'
        ).ordered

        # Current message asked via chat.ask
        expect(mock_chat).to receive(:ask).with('It still does not work').and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation_id: conversation.display_id)
        service.generate_response(message_history: message_history)
      end
    end
  end

  describe 'structured response schema' do
    let(:message_history) { [{ role: 'user', content: 'Hi' }] }

    context 'when Captain LLM provider is OpenAI' do
      before do
        InstallationConfig.find_or_initialize_by(name: LlmConstants::CAPTAIN_LLM_PROVIDER_CONFIG_KEY).tap do |c|
          c.value = 'openai'
          c.save!
        end
      end

      it 'enforces Captain::ResponseSchema instead of generic json_object' do
        expect(mock_chat).to receive(:with_schema).with(Captain::ResponseSchema).and_return(mock_chat)
        expect(mock_chat).not_to receive(:with_params)

        allow(mock_chat).to receive(:ask).and_return(mock_response)

        described_class.new(assistant: assistant, conversation_id: conversation.display_id)
                       .generate_response(message_history: message_history)
      end
    end

    context 'when Captain LLM provider is Ollama' do
      before do
        InstallationConfig.find_or_initialize_by(name: LlmConstants::CAPTAIN_LLM_PROVIDER_CONFIG_KEY).tap do |c|
          c.value = 'ollama'
          c.save!
        end
      end

      it 'uses json_object response format' do
        expect(mock_chat).to receive(:with_params).with(response_format: { type: 'json_object' }).and_return(mock_chat)
        expect(mock_chat).not_to receive(:with_schema)

        allow(mock_chat).to receive(:ask).and_return(mock_response)

        described_class.new(assistant: assistant, conversation_id: conversation.display_id)
                       .generate_response(message_history: message_history)
      end
    end
  end
end
