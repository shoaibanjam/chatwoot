# Builds WhatsApp Cloud API interactive media carousel payloads from Chatwoot card messages.
# https://developers.facebook.com/docs/whatsapp/cloud-api/messages/interactive-media-carousel-messages/
class Whatsapp::InteractiveCarouselPayloadBuilder
  MIN_CARDS = 2
  MAX_CARDS = 10
  CARD_BODY_MAX = 160
  MAIN_BODY_MAX = 1024
  CTA_TEXT_MAX = 25

  def self.acceptable_header_image_url?(url)
    path = url.to_s.split('?', 2).first.to_s.downcase
    path.end_with?('.png', '.jpg', '.jpeg')
  end

  def initialize(message)
    @message = message
  end

  def build
    items = Array.wrap(@message.content_attributes&.[]('items')).presence
    return nil if items.blank?

    cards = build_cards(items.map(&:with_indifferent_access).first(MAX_CARDS))
    return nil if cards.size < MIN_CARDS

    body_text = @message.outgoing_content.to_s.strip.truncate(MAIN_BODY_MAX)
    return nil if body_text.blank?

    {
      'type' => 'carousel',
      'body' => { 'text' => body_text },
      'action' => { 'cards' => cards }
    }
  end

  private

  def build_cards(normalized_items)
    normalized_items.filter_map { |item| build_card_without_index(item) }.each_with_index.map do |card, idx|
      card.merge('card_index' => idx)
    end
  end

  def build_card_without_index(item)
    media_url = item[:media_url].to_s.strip
    return nil if media_url.blank? || !media_url.match?(%r{\Ahttps?://}i)
    return nil unless self.class.acceptable_header_image_url?(media_url)

    cta_url = extract_link_uri(item)
    return nil if cta_url.blank?

    {
      'type' => 'cta_url',
      'header' => image_header(media_url),
      'body' => { 'text' => format_card_body(item) },
      'action' => cta_url_action(cta_url, item)
    }
  end

  def image_header(media_url)
    { 'type' => 'image', 'image' => { 'link' => media_url } }
  end

  def cta_url_action(url, item)
    {
      'name' => 'cta_url',
      'parameters' => { 'display_text' => link_button_text(item), 'url' => url }
    }
  end

  def extract_link_uri(item)
    link = first_link_action(item)
    uri = link&.dig(:uri)
    return nil if uri.blank?

    uri = uri.to_s.strip
    uri if uri.match?(%r{\Ahttps?://}i)
  end

  def first_link_action(item)
    Array.wrap(item[:actions]).map(&:with_indifferent_access).find { |a| a[:type].to_s == 'link' }
  end

  def link_button_text(item)
    link = first_link_action(item)
    text = (link&.dig(:text).presence || I18n.t('conversations.messages.whatsapp.carousel_cta_default')).to_s.strip
    text.truncate(CTA_TEXT_MAX, omission: '')
  end

  def format_card_body(item)
    title = item[:title].to_s.strip
    desc = item[:description].to_s.strip
    parts = [title.presence, desc.presence].compact
    text = parts.join("\n\n")
    text = text.presence || title.presence || desc.presence || '-'
    text.truncate(CARD_BODY_MAX, omission: '…')
  end
end
