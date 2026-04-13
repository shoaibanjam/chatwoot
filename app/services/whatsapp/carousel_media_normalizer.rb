# frozen_string_literal: true

require 'aws-sdk-s3'
require 'image_processing/vips'
require 'image_processing/mini_magick'

# Downloads non-PNG/JPEG carousel card images, converts to JPEG, uploads to S3, and rewrites
# message content_attributes item media_url values to public HTTPS URLs (for WhatsApp Cloud API).
#
# Requires WHATSAPP_CAROUSEL_MEDIA_S3_BUCKET and WHATSAPP_CAROUSEL_MEDIA_PUBLIC_URL_BASE.
# Objects must be publicly readable (bucket policy or ACL) so Meta can fetch image links.
class Whatsapp::CarouselMediaNormalizer
  MAX_DOWNLOAD_BYTES = 5.megabytes
  JPEG_QUALITY = 88

  PRIVATE_IP_RANGES = [
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('169.254.0.0/16'),
    IPAddr.new('::1'),
    IPAddr.new('fc00::/7'),
    IPAddr.new('fe80::/10')
  ].freeze

  def self.enabled?
    ENV['WHATSAPP_CAROUSEL_MEDIA_S3_BUCKET'].present? &&
      ENV['WHATSAPP_CAROUSEL_MEDIA_PUBLIC_URL_BASE'].present?
  end

  def self.pending?(message) # rubocop:disable Metrics/CyclomaticComplexity -- feature gate branches
    return false unless enabled?
    return false unless message&.cards?

    attrs = message.content_attributes&.with_indifferent_access || {}
    return false if attrs[:whatsapp_carousel_media_normalized_at].present?

    items = attrs[:items]
    Array.wrap(items).any? { |item| needs_fetch_and_convert?(item) }
  end

  def self.needs_fetch_and_convert?(item)
    url = item.with_indifferent_access[:media_url].to_s.strip
    return false if url.blank?

    !Whatsapp::InteractiveCarouselPayloadBuilder.acceptable_header_image_url?(url)
  end

  def initialize(message)
    @message = message
  end

  def call
    attrs = deep_stringify_content_attributes
    items = Array.wrap(attrs['items'])
    new_items = items.filter_map { |item| process_item(item) }
    attrs['items'] = new_items
    attrs['whatsapp_carousel_media_normalized_at'] = Time.current.iso8601
    @message.update!(content_attributes: attrs)
  end

  private

  def deep_stringify_content_attributes
    raw = @message.content_attributes || {}
    JSON.parse(raw.to_json)
  end

  def process_item(item) # rubocop:disable Metrics/CyclomaticComplexity -- download/convert/upload pipeline
    jpeg_path = nil
    h = item.stringify_keys
    url = h['media_url'].to_s.strip
    return nil if url.blank? || !url.match?(%r{\Ahttps://}i)

    return h if Whatsapp::InteractiveCarouselPayloadBuilder.acceptable_header_image_url?(url)

    jpeg_path = fetch_and_convert_to_jpeg(url)
    return nil if jpeg_path.blank?

    body = File.binread(jpeg_path)
    public_url = upload_jpeg(body)
    return nil if public_url.blank?

    h.merge('media_url' => public_url)
  ensure
    File.unlink(jpeg_path) if jpeg_path.present? && File.exist?(jpeg_path)
  end

  def fetch_and_convert_to_jpeg(url)
    uri = URI.parse(url)
    raise URI::InvalidURIError, 'missing host' if uri.host.blank?

    check_private_ip!(uri.host)
    downloaded = Down.download(url, max_size: MAX_DOWNLOAD_BYTES)
    path = downloaded.respond_to?(:path) ? downloaded.path : downloaded.to_path
    convert_source_to_jpeg_file(path)
  rescue Down::Error, URI::InvalidURIError, SocketError, SystemCallError, ArgumentError => e
    Rails.logger.warn("[CarouselMedia] skip url=#{url} error=#{e.class}: #{e.message}")
    nil
  end

  def convert_source_to_jpeg_file(source_path)
    ImageProcessing::Vips.source(source_path).convert('jpeg').saver(quality: JPEG_QUALITY).call
  rescue StandardError => e
    Rails.logger.warn("[CarouselMedia] Vips convert failed: #{e.message}; trying MiniMagick")
    ImageProcessing::MiniMagick.source(source_path).convert('jpeg').saver(quality: JPEG_QUALITY).call
  end

  def upload_jpeg(body)
    bucket = ENV.fetch('WHATSAPP_CAROUSEL_MEDIA_S3_BUCKET')
    prefix = ENV.fetch('WHATSAPP_CAROUSEL_MEDIA_S3_PREFIX', 'whatsapp_carousel/')
    prefix = "#{prefix.chomp('/')}/"

    key = "#{prefix}#{@message.account_id}/#{@message.id}/#{SecureRandom.hex(12)}.jpg"
    put_options = {
      bucket: bucket,
      key: key,
      body: body,
      content_type: 'image/jpeg'
    }
    put_options[:acl] = 'public-read' if ENV['WHATSAPP_CAROUSEL_S3_PUBLIC_ACL'] == 'true'

    s3_client.put_object(put_options)
    public_object_url(key)
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("[CarouselMedia] S3 upload failed: #{e.class}: #{e.message}")
    nil
  end

  def public_object_url(key)
    base = ENV.fetch('WHATSAPP_CAROUSEL_MEDIA_PUBLIC_URL_BASE').delete_suffix('/')
    "#{base}/#{key}"
  end

  def s3_client
    @s3_client ||= begin
      opts = { region: s3_region }
      opts[:endpoint] = ENV['WHATSAPP_CAROUSEL_S3_ENDPOINT'] if ENV['WHATSAPP_CAROUSEL_S3_ENDPOINT'].present?
      opts[:force_path_style] = ActiveModel::Type::Boolean.new.cast(
        ENV.fetch('WHATSAPP_CAROUSEL_S3_FORCE_PATH_STYLE', 'false')
      )
      Aws::S3::Client.new(opts)
    end
  end

  def s3_region
    ENV['WHATSAPP_CAROUSEL_S3_REGION'].presence ||
      ENV['AWS_REGION'].presence ||
      ENV['STORAGE_REGION'].presence ||
      'us-east-1'
  end

  def check_private_ip!(hostname)
    return if hostname.blank?

    ip_address = IPAddr.new(Resolv.getaddress(hostname))
    raise SocketError, 'URL resolves to a private or loopback address' if PRIVATE_IP_RANGES.any? { |range| range.include?(ip_address) }
  rescue Resolv::ResolvError => e
    raise SocketError, "DNS resolution failed: #{e.message}"
  end
end
