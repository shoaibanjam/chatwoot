# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ResponseSchema do
  describe 'JSON schema shape' do
    let(:schema) { described_class.new.to_json_schema[:schema] }
    let(:properties) { schema[:properties] }

    it 'requires response, reasoning, and interactive' do
      expect(schema[:required]).to contain_exactly(:response, :reasoning, :interactive)
    end

    it 'declares interactive as anyOf object or null' do
      interactive = properties[:interactive]
      expect(interactive[:anyOf].map { |s| s[:type] }).to contain_exactly('object', 'null')
    end

    it 'constrains interactive items to 2-10 entries when an object' do
      object_branch = properties[:interactive][:anyOf].find { |s| s[:type] == 'object' }
      items = object_branch[:properties][:items]
      expect(items[:minItems]).to eq(2)
      expect(items[:maxItems]).to eq(10)
    end
  end
end
