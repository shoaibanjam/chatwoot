# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::NormalizeCarouselMediaJob, type: :job do
  include ActiveJob::TestHelper

  let(:whatsapp_channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let(:contact_inbox) { create(:contact_inbox, inbox: whatsapp_channel.inbox, source_id: '123456789') }
  let(:conversation) { create(:conversation, inbox: whatsapp_channel.inbox, contact_inbox: contact_inbox) }

  before do
    stub_request(:post, %r{\Ahttps://waba\.360dialog\.io/v1/configs/webhook\z}).to_return(status: 200, body: '{}')
  end

  it 'returns when message is missing' do
    clear_enqueued_jobs
    expect { described_class.perform_now(0) }.not_to have_enqueued_job(SendReplyJob)
  end

  context 'with a cards message' do
    let!(:message) do
      create(:message,
             message_type: :outgoing,
             content_type: :cards,
             content: 'Pick',
             conversation: conversation,
             inbox: whatsapp_channel.inbox,
             content_attributes: {
               'items' => [
                 { 'title' => 'A', 'media_url' => 'https://example.com/a.webp',
                   'actions' => [{ 'type' => 'link', 'text' => 'Book', 'uri' => 'https://ajarlee.om/a' }] },
                 { 'title' => 'B', 'media_url' => 'https://example.com/b.webp',
                   'actions' => [{ 'type' => 'link', 'text' => 'Book', 'uri' => 'https://ajarlee.om/b' }] }
               ]
             })
    end

    before { clear_enqueued_jobs }

    context 'when normalizer is disabled' do
      it 'does not run normalization or enqueue SendReplyJob' do
        allow(Whatsapp::CarouselMediaNormalizer).to receive(:enabled?).and_return(false)
        expect(Whatsapp::CarouselMediaNormalizer).not_to receive(:new)
        expect do
          described_class.perform_now(message.id)
        end.not_to have_enqueued_job(SendReplyJob)
      end
    end

    context 'when normalizer is enabled' do
      before do
        allow(Whatsapp::CarouselMediaNormalizer).to receive(:enabled?).and_return(true)
      end

      it 'skips when already normalized' do
        message.update!(
          content_attributes: message.content_attributes.merge('whatsapp_carousel_media_normalized_at' => Time.current.iso8601)
        )
        expect(Whatsapp::CarouselMediaNormalizer).not_to receive(:new)
        expect do
          described_class.perform_now(message.id)
        end.not_to have_enqueued_job(SendReplyJob)
      end

      it 'invokes normalizer and enqueues SendReplyJob' do
        normalizer = instance_double(Whatsapp::CarouselMediaNormalizer, call: true)
        allow(Whatsapp::CarouselMediaNormalizer).to receive(:new).with(an_instance_of(Message)).and_return(normalizer)
        expect do
          described_class.perform_now(message.id)
        end.to have_enqueued_job(SendReplyJob).with(message.id)
      end

      it 'on failure marks normalized and still enqueues SendReplyJob' do
        allow(Whatsapp::CarouselMediaNormalizer).to receive(:new).and_raise(StandardError, 'boom')
        allow(ChatwootExceptionTracker).to receive(:new).and_return(instance_double(ChatwootExceptionTracker, capture_exception: true))

        expect do
          described_class.perform_now(message.id)
        end.to have_enqueued_job(SendReplyJob).with(message.id)

        expect(message.reload.content_attributes['whatsapp_carousel_media_normalized_at']).to be_present
        expect(message.content_attributes['whatsapp_carousel_media_normalization_error']).to include('boom')
      end
    end
  end
end
