# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Health API', type: :request do
  describe 'GET /health' do
    it 'returns application health' do
      get '/health'

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['status']).to eq('ok')
      expect(json['environment']).to eq('test')
    end
  end

  describe 'GET /health/sidekiq' do
    it 'returns sidekiq health when processes exist' do
      process_set = instance_double(Sidekiq::ProcessSet, to_a: [
        {
          'hostname' => 'sidekiq-test-0',
          'concurrency' => 10,
          'queues' => ['default'],
          'busy' => 0
        }
      ])

      allow(Sidekiq::ProcessSet).to receive(:new).and_return(process_set)

      get '/health/sidekiq'

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['status']).to eq('ok')
      expect(json['sidekiq']).to eq('running')
      expect(json['process_count']).to eq(1)
    end
  end
end
