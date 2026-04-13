# Parses Captain custom tool HTTP responses that include data.captainCarousel (body + items).
class Captain::Assistant::CaptainCarouselToolExtractor
  def self.call(messages)
    new(messages).extract
  end

  def initialize(messages)
    @messages = messages
  end

  def extract
    return nil if @messages.blank?

    @messages.reverse_each do |msg|
      carousel = carousel_from_tool_message(msg)
      return carousel if carousel
    end
    nil
  end

  private

  def carousel_from_tool_message(msg)
    return nil unless msg[:role].to_s == 'tool'

    parsed = parse_json_if_string(msg[:content])
    return nil if parsed.blank?

    raw = parsed.dig('data', 'captainCarousel') || parsed['captainCarousel']
    return nil if raw.blank?

    build_carousel(raw)
  end

  def build_carousel(raw)
    h = raw.with_indifferent_access
    items = h[:items]
    return nil unless items.is_a?(Array) && items.size >= 2

    normalized_items = items.filter_map { |item| normalize_item(item) }
    return nil if normalized_items.size < 2

    { 'body' => h[:body].to_s, 'items' => normalized_items }
  end

  def normalize_item(item)
    h = item.with_indifferent_access
    title = h[:title].to_s.strip
    value = first_non_blank_string(h, :value, :bookingUrl, :booking_url)
    media_url = first_non_blank_string(h, :media_url, :mediaUrl, :imageUrl, :image_url)
    return nil if title.blank? || value.blank? || media_url.blank?

    out = { 'title' => title, 'value' => value, 'media_url' => media_url }
    desc = h[:description].to_s.strip
    out['description'] = desc if desc.present?
    out
  end

  def parse_json_if_string(content)
    return content if content.is_a?(Hash)

    JSON.parse(content.to_s)
  rescue JSON::ParserError, TypeError
    nil
  end

  def first_non_blank_string(hash, *keys)
    keys.each do |key|
      s = hash[key].to_s.strip
      return s if s.present?
    end
    nil
  end
end
