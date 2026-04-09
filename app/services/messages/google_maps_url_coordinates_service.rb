require 'ipaddr'

# Resolves Google Maps share/short URLs by following redirects (allowlisted hosts only)
# and extracts latitude/longitude from the final URL when present.
class Messages::GoogleMapsUrlCoordinatesService
  pattr_initialize [:url!]

  MAX_REDIRECTS = 5
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 8
  SHORT_LINK_HOSTS = %w[goo.gl maps.app.goo.gl].freeze
  USER_AGENT = 'Chatwoot/1.0 (+https://github.com/chatwoot/chatwoot)'.freeze

  def perform
    uri = parse_http_uri(url)
    return nil if uri.blank?
    return nil unless allowed_fetch_uri?(uri)

    coords = extract_coordinates(uri.to_s)
    return coordinate_result(coords) if coords

    final_uri = follow_redirects(uri)
    return nil if final_uri.blank?

    coords = extract_coordinates(final_uri.to_s)
    coordinate_result(coords)
  rescue StandardError => e
    Rails.logger.warn("[GoogleMapsUrlCoordinatesService] #{e.class}: #{e.message}")
    nil
  end

  private

  def coordinate_result(pair)
    return nil if pair.blank?

    lat, lng = pair
    return nil unless valid_lat_lon?(lat, lng)

    { latitude: lat, longitude: lng }
  end

  def parse_http_uri(raw)
    cleaned = raw.to_s.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
    uri = URI.parse(cleaned)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    return nil unless %w[http https].include?(uri.scheme.downcase)

    uri
  rescue URI::InvalidURIError
    nil
  end

  def follow_redirects(start_uri)
    uri = start_uri
    MAX_REDIRECTS.times do
      return nil unless allowed_fetch_uri?(uri)

      response = http_head(uri)
      response = http_get(uri) if response.is_a?(Net::HTTPNotFound) || response.code == '405'

      case response
      when Net::HTTPRedirection
        location = response['location']
        return nil if location.blank?

        uri = URI.join(uri.to_s, location)
      when Net::HTTPSuccess
        return uri
      else
        return nil
      end
    end
    nil
  end

  def http_head(uri)
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    ) do |http|
      request = Net::HTTP::Head.new(uri.request_uri)
      request['User-Agent'] = USER_AGENT
      http.request(request)
    end
  end

  def http_get(uri)
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    ) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = USER_AGENT
      request['Range'] = 'bytes=0-0'
      http.request(request)
    end
  end

  def allowed_fetch_uri?(uri)
    host = uri.host&.downcase
    return false if host.blank?
    return false if disallowed_ip_or_localhost?(host)

    allowed_google_maps_host?(uri)
  end

  def disallowed_ip_or_localhost?(host)
    return true if host == 'localhost'

    addr = IPAddr.new(host)
    addr.loopback? || addr.private? || addr.link_local?
  rescue IPAddr::InvalidAddressError
    false
  end

  def allowed_google_maps_host?(uri)
    host = uri.host&.downcase
    path = uri.path.to_s.downcase
    query = uri.query.to_s.downcase

    return true if short_link_maps_host?(host)
    return true if host == 'maps.google.com'
    return true if canonical_google_maps_path?(host, path)
    return true if google_url_redirect_wrapper?(host, path, query)

    google_regional_maps_host?(host, path, query)
  end

  def short_link_maps_host?(host)
    SHORT_LINK_HOSTS.include?(host)
  end

  def canonical_google_maps_path?(host, path)
    %w[www.google.com google.com].include?(host) && path.start_with?('/maps')
  end

  def google_url_redirect_wrapper?(host, path, query)
    host == 'www.google.com' && path == '/url' &&
      (query.include?('maps') || query.include?('google.com%2fmaps'))
  end

  def google_regional_maps_host?(host, path, query)
    return false unless host&.match?(/\A(www\.)?google\.[a-z0-9.]+/i)

    path.include?('/maps') || query.include?('/maps') || query.include?('maps.google.com')
  end

  def extract_coordinates(url_string)
    try_at_pattern(url_string) ||
      try_bang_3d_4d(url_string) ||
      try_query_latlng(url_string)
  end

  def try_at_pattern(url_str)
    m = url_str.match(%r{@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)(?:[,/]|\z|\?)})
    return nil unless m

    lat = m[1].to_f
    lng = m[2].to_f
    [lat, lng] if valid_lat_lon?(lat, lng)
  end

  def try_bang_3d_4d(url_str)
    if (m = url_str.match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/i))
      lat = m[1].to_f
      lng = m[2].to_f
      return [lat, lng] if valid_lat_lon?(lat, lng)
    end
    if (m = url_str.match(/!4d(-?\d+(?:\.\d+)?)!3d(-?\d+(?:\.\d+)?)/i))
      lng = m[1].to_f
      lat = m[2].to_f
      return [lat, lng] if valid_lat_lon?(lat, lng)
    end
    nil
  end

  def try_query_latlng(url_string)
    uri = URI.parse(url_string)
    return nil unless uri.query

    params = URI.decode_www_form(uri.query).to_h
    %w[q query center ll].each do |key|
      val = params[key]
      next if val.blank?

      pair = parse_comma_latlng(val)
      next unless pair && valid_lat_lon?(pair[0], pair[1])

      return pair
    end
    nil
  rescue URI::InvalidURIError, ArgumentError, URI::InvalidComponentError
    nil
  end

  def parse_comma_latlng(val)
    m = val.to_s.match(/\A(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\z/)
    return nil unless m

    [m[1].to_f, m[2].to_f]
  end

  def valid_lat_lon?(lat, lng)
    lat.abs <= 90 && lng.abs <= 180
  end
end
