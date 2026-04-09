class Captain::OpenAiMessageBuilderService
  pattr_initialize [:message!]

  # Extracts text and image URLs from multimodal content array (reverse of generate_content)
  def self.extract_text_and_attachments(content)
    return [content, []] unless content.is_a?(Array)

    text_parts = content.select { |part| part[:type] == 'text' }.pluck(:text)
    image_urls = content.select { |part| part[:type] == 'image_url' }.filter_map { |part| part.dig(:image_url, :url) }
    [text_parts.join(' ').presence, image_urls]
  end

  def generate_content
    parts = []
    parts << text_part(enrich_content_with_resolved_maps_coordinates(@message.content)) if @message.content.present?
    parts.concat(attachment_parts(@message.attachments)) if @message.attachments.any?

    return 'Message without content' if parts.blank?
    return parts.first[:text] if parts.one? && parts.first[:type] == 'text'

    parts
  end

  private

  def text_part(text)
    { type: 'text', text: text }
  end

  def image_part(image_url)
    { type: 'image_url', image_url: { url: image_url } }
  end

  def attachment_parts(attachments)
    image_attachments = attachments.where(file_type: :image)
    image_content = image_parts(image_attachments)

    transcription = extract_audio_transcriptions(attachments)
    transcription_part = text_part(transcription) if transcription.present?

    location_content = location_parts(attachments.where(file_type: :location))

    other_attachments = attachments.where.not(file_type: %i[image audio location])
    attachment_part = text_part('User has shared an attachment') if other_attachments.exists?

    [image_content, transcription_part, location_content, attachment_part].flatten.compact
  end

  def location_parts(location_attachments)
    location_attachments.map { |attachment| text_part(format_location_for_llm(attachment)) }
  end

  def format_location_for_llm(attachment)
    lat = attachment.coordinates_lat
    lng = attachment.coordinates_long
    coord_text = "latitude #{lat}, longitude #{lng}"
    label = attachment.fallback_title.presence
    if label.present?
      "User shared a location (#{label}): #{coord_text}."
    else
      "User shared a location: #{coord_text}."
    end
  end

  def image_parts(image_attachments)
    image_attachments.each_with_object([]) do |attachment, parts|
      url = get_attachment_url(attachment)
      parts << image_part(url) if url.present?
    end
  end

  def get_attachment_url(attachment)
    return attachment.download_url if attachment.download_url.present?
    return attachment.external_url if attachment.external_url.present?

    attachment.file.attached? ? attachment.file_url : nil
  end

  def extract_audio_transcriptions(attachments)
    audio_attachments = attachments.where(file_type: :audio)
    return '' if audio_attachments.blank?

    audio_attachments.map do |attachment|
      result = Messages::AudioTranscriptionService.new(attachment).perform
      result[:success] ? result[:transcriptions] : ''
    end.join
  end

  def enrich_content_with_resolved_maps_coordinates(text)
    additions = []
    extract_candidate_maps_urls(text).each do |raw_url|
      result = Messages::GoogleMapsUrlCoordinatesService.new(url: raw_url).perform
      next if result.blank?

      additions << "Google Maps link resolves to latitude #{result[:latitude]}, longitude #{result[:longitude]}."
    end
    return text if additions.empty?

    "#{text}\n#{additions.join("\n")}"
  end

  def extract_candidate_maps_urls(text)
    text.scan(%r{https?://[^\s<>\[\]()'"]+}).filter_map do |raw|
      url = raw.sub(/[.,;)\]>]+$/, '')
      url.presence if potential_google_maps_url?(url)
    end.uniq
  end

  def potential_google_maps_url?(url)
    u = url.downcase
    u.include?('goo.gl/maps') || u.include?('maps.app.goo.gl') ||
      u.include?('google.com/maps') || u.include?('maps.google.com') ||
      (u.include?('google.') && u.include?('/maps'))
  end
end
