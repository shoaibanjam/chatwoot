require 'rails_helper'

RSpec.describe Messages::GoogleMapsUrlCoordinatesService do
  describe '#perform' do
    it 'extracts coordinates from @lat,lng in the URL without HTTP' do
      url = 'https://www.google.com/maps/place/Test/@25.2048,55.2708,17z/data=!3m1!4b1'
      result = described_class.new(url: url).perform
      expect(result).to eq(latitude: 25.2048, longitude: 55.2708)
    end

    it 'extracts coordinates from q=lat,lng' do
      url = 'https://www.google.com/maps?q=1.3521,103.8198'
      result = described_class.new(url: url).perform
      expect(result).to eq(latitude: 1.3521, longitude: 103.8198)
    end

    it 'extracts coordinates from !3d!4d encoding' do
      url = 'https://www.google.com/maps/place/x/data=!3m1!1e3!4m5!3m4!1s0x0:0x0!8m2!3d12.9716!4d77.5946'
      result = described_class.new(url: url).perform
      expect(result).to eq(latitude: 12.9716, longitude: 77.5946)
    end

    it 'returns nil for non-http schemes' do
      expect(described_class.new(url: 'ftp://www.google.com/maps?q=1,2').perform).to be_nil
    end

    it 'returns nil for disallowed hosts' do
      expect(described_class.new(url: 'https://example.com/maps/@1,2').perform).to be_nil
    end

    it 'returns nil for loopback IP hosts' do
      expect(described_class.new(url: 'http://127.0.0.1/maps/@1,2').perform).to be_nil
    end

    context 'when following redirects from a short link' do
      let(:final_maps_url) { 'https://www.google.com/maps/place/Here/@24.8607,67.0011,12z' }

      before do
        stub_request(:head, 'https://goo.gl/maps/abc123')
          .to_return(status: 302, headers: { 'Location' => final_maps_url })
        stub_request(:head, final_maps_url).to_return(status: 200)
      end

      it 'resolves Location headers on allowlisted hosts only' do
        result = described_class.new(url: 'https://goo.gl/maps/abc123').perform
        expect(result).to eq(latitude: 24.8607, longitude: 67.0011)
      end
    end

    context 'when HEAD is not allowed' do
      let(:final_maps_url) { 'https://www.google.com/maps/place/X/@10.0,20.0,10z' }

      before do
        stub_request(:head, 'https://goo.gl/maps/xyz')
          .to_return(status: 405)
        stub_request(:get, 'https://goo.gl/maps/xyz')
          .with(headers: { 'Range' => 'bytes=0-0' })
          .to_return(status: 302, headers: { 'Location' => final_maps_url })
        stub_request(:head, final_maps_url).to_return(status: 200)
      end

      it 'falls back to ranged GET' do
        result = described_class.new(url: 'https://goo.gl/maps/xyz').perform
        expect(result).to eq(latitude: 10.0, longitude: 20.0)
      end
    end

    context 'when redirect targets a non-allowlisted host' do
      before do
        stub_request(:head, 'https://goo.gl/maps/bad')
          .to_return(status: 302, headers: { 'Location' => 'https://evil.example/phish' })
      end

      it 'returns nil' do
        expect(described_class.new(url: 'https://goo.gl/maps/bad').perform).to be_nil
      end
    end
  end
end
