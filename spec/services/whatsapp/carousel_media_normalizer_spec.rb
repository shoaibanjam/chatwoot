# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::CarouselMediaNormalizer do
  before do
    stub_request(:post, %r{\Ahttps://waba\.360dialog\.io/v1/configs/webhook\z}).to_return(status: 200, body: '{}')
  end

  let(:whatsapp_channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:contact_inbox) { create(:contact_inbox, inbox: whatsapp_channel.inbox, source_id: '123456789') }
  let(:conversation) { create(:conversation, inbox: whatsapp_channel.inbox, contact_inbox: contact_inbox) }
  let(:items) do
    [
      {
        'title' => 'A',
        'media_url' => 'https://example.com/a.webp',
        'actions' => [{ 'type' => 'link', 'text' => 'Book', 'uri' => 'https://ajarlee.om/a' }]
      },
      {
        'title' => 'B',
        'media_url' => 'https://example.com/b.jpg',
        'actions' => [{ 'type' => 'link', 'text' => 'Book', 'uri' => 'https://ajarlee.om/b' }]
      }
    ]
  end
  let(:message) do
    create(:message,
           message_type: :outgoing,
           content_type: :cards,
           content: 'Pick one',
           conversation: conversation,
           inbox: whatsapp_channel.inbox,
           content_attributes: { 'items' => items })
  end

  # rubocop:disable Metrics/AbcSize -- ENV stubs for optional S3 feature
  def stub_carousel_env
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WHATSAPP_CAROUSEL_MEDIA_S3_BUCKET').and_return('cw-carousel-test')
    allow(ENV).to receive(:[]).with('WHATSAPP_CAROUSEL_MEDIA_PUBLIC_URL_BASE').and_return('https://cdn.example.com')
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('WHATSAPP_CAROUSEL_MEDIA_S3_BUCKET').and_return('cw-carousel-test')
    allow(ENV).to receive(:fetch).with('WHATSAPP_CAROUSEL_MEDIA_PUBLIC_URL_BASE').and_return('https://cdn.example.com')
    allow(ENV).to receive(:fetch).with('WHATSAPP_CAROUSEL_MEDIA_S3_PREFIX', 'whatsapp_carousel/').and_return('whatsapp_carousel/')
    allow(ENV).to receive(:fetch).with('WHATSAPP_CAROUSEL_S3_FORCE_PATH_STYLE', 'false').and_return('false')
  end
  # rubocop:enable Metrics/AbcSize

  describe '.enabled?' do
    it 'is false without bucket or public base' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WHATSAPP_CAROUSEL_MEDIA_S3_BUCKET').and_return('')
      allow(ENV).to receive(:[]).with('WHATSAPP_CAROUSEL_MEDIA_PUBLIC_URL_BASE').and_return('')
      expect(described_class.enabled?).to be(false)
    end

    it 'is true when bucket and public base are set' do
      stub_carousel_env
      expect(described_class.enabled?).to be(true)
    end
  end

  describe '.pending?' do
    it 'is false when feature disabled' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WHATSAPP_CAROUSEL_MEDIA_S3_BUCKET').and_return(nil)
      expect(described_class.pending?(message)).to be(false)
    end

    context 'when feature enabled' do
      before { stub_carousel_env }

      it 'is false when not cards' do
        text_message = create(:message,
                              message_type: :outgoing,
                              content_type: :text,
                              conversation: conversation,
                              inbox: whatsapp_channel.inbox,
                              content: 'hi')
        expect(described_class.pending?(text_message)).to be(false)
      end

      it 'is false when already normalized' do
        message.update!(
          content_attributes: message.content_attributes.merge('whatsapp_carousel_media_normalized_at' => Time.current.iso8601)
        )
        expect(described_class.pending?(message)).to be(false)
      end

      it 'is false when all media URLs are acceptable extensions' do
        only_jpg = items.map { |i| i.merge('media_url' => 'https://ex.com/x.jpg') }
        m = create(:message,
                   message_type: :outgoing,
                   content_type: :cards,
                   content: 'x',
                   conversation: conversation,
                   inbox: whatsapp_channel.inbox,
                   content_attributes: { 'items' => only_jpg })
        expect(described_class.pending?(m)).to be(false)
      end

      it 'is true when any item needs fetch and convert' do
        expect(described_class.pending?(message)).to be(true)
      end
    end
  end

  describe '#call' do
    before { stub_carousel_env }

    it 'replaces non-jpeg/png media_url and preserves jpeg item, sets normalized timestamp' do
      allow(Resolv).to receive(:getaddress).with('example.com').and_return('8.8.8.8')
      normalizer = described_class.new(message)
      allow(normalizer).to receive(:fetch_and_convert_to_jpeg).with('https://example.com/a.webp').and_return('/tmp/carousel.jpg')
      allow(File).to receive(:binread).with('/tmp/carousel.jpg').and_return('jpeg-bytes')
      allow(normalizer).to receive(:upload_jpeg).with('jpeg-bytes').and_return('https://cdn.example.com/k.jpg')
      allow(File).to receive(:unlink)

      normalizer.call

      message.reload
      expect(message.content_attributes['whatsapp_carousel_media_normalized_at']).to be_present
      updated = message.content_attributes['items']
      expect(updated.size).to eq(2)
      expect(updated[0]['media_url']).to eq('https://cdn.example.com/k.jpg')
      expect(updated[1]['media_url']).to eq('https://example.com/b.jpg')
    end

    it 'drops items that fail conversion' do
      normalizer = described_class.new(message)
      allow(normalizer).to receive(:fetch_and_convert_to_jpeg).and_return(nil)

      normalizer.call

      message.reload
      expect(message.content_attributes['items'].size).to eq(1)
      expect(message.content_attributes['items'].first['media_url']).to eq('https://example.com/b.jpg')
    end
  end
end
