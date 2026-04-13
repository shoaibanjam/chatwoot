# frozen_string_literal: true

# Async step for WhatsApp card carousels: re-hosts non-PNG/JPEG media_url images to S3 as JPEG,
# then re-enqueues SendReplyJob. See Whatsapp::CarouselMediaNormalizer.
class Whatsapp::NormalizeCarouselMediaJob < ApplicationJob
  queue_as :high

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank?
    return unless Whatsapp::CarouselMediaNormalizer.enabled?
    return unless message.cards?
    return if carousel_already_normalized?(message)

    Whatsapp::CarouselMediaNormalizer.new(message).call
    SendReplyJob.perform_later(message.id)
  rescue StandardError => e
    handle_failure(Message.find_by(id: message_id), e)
  end

  private

  def carousel_already_normalized?(message)
    message.content_attributes&.with_indifferent_access&.dig(:whatsapp_carousel_media_normalized_at).present?
  end

  def handle_failure(message, error)
    return if message.blank?

    Rails.logger.error("[NormalizeCarouselMedia] message=#{message.id} #{error.class}: #{error.message}")
    ChatwootExceptionTracker.new(error, account: message.account).capture_exception

    attrs = JSON.parse((message.content_attributes || {}).to_json)
    attrs['whatsapp_carousel_media_normalized_at'] = Time.current.iso8601
    attrs['whatsapp_carousel_media_normalization_error'] = error.message.to_s.truncate(500)
    message.update_columns(content_attributes: attrs, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

    SendReplyJob.perform_later(message.id)
  end
end
