# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Client::Auth::SiweController, type: :request, redis: :real do
  let(:test_nonce) { SecureRandom.hex(16) }
  let(:test_address) { "0x" + "a1b2c3d4e5" * 4 }
  let(:valid_message) do
    "puzzlex.io wants you to sign in with your Ethereum account:\n" \
      "#{test_address}\n\n" \
      "Sign in with Ethereum\n\n" \
      "Chain ID: 31338\n" \
      "Nonce: #{test_nonce}\n" \
      "Issued At: 2026-01-01T00:00:00.000Z"
  end
  let(:valid_signature) { "0x" + "ab" * 65 }

  before do
    Redis.current.del("nonce:#{test_nonce}")
  end

  after do
    Redis.current.del("nonce:#{test_nonce}")
  end

  describe "GET /api/nonce" do
    it "returns a 32-hex-length string in body" do
      get "/api/nonce"

      expect(response).to have_http_status(:ok)
      nonce_str = response.body

      expect(nonce_str.size).to eq(32)
      expect(nonce_str).to match(/\A[0-9a-fA-F]{32}\z/)
    end
  end

  describe "POST /api/verify" do
    context "when params are missing" do
      it "returns 400 if message is missing" do
        post "/api/verify", params: { signature: "0xsome" }
        expect(response).to have_http_status(:bad_request)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("Missing message or signature")
      end

      it "returns 400 if signature is missing" do
        post "/api/verify", params: { message: "some message" }
        expect(response).to have_http_status(:bad_request)
      end
    end

    context "when signature is invalid" do
      before do
        Redis.current.set("nonce:#{test_nonce}", "1", ex: 300)
        allow_any_instance_of(Client::Auth::SiweController).to receive(:verify_signature).and_return(false)
      end

      it "returns 401 unauthorized" do
        post "/api/verify", params: { message: valid_message, signature: valid_signature }
        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("Invalid signature")
      end
    end

    context "when signature is valid" do
      before do
        Redis.current.set("nonce:#{test_nonce}", "1", ex: 300)
        allow_any_instance_of(Client::Auth::SiweController).to receive(:verify_signature).and_return(true)
      end

      it "creates a user record and returns a JWT token" do
        expect {
          post "/api/verify", params: { message: valid_message, signature: valid_signature }
        }.to change { Accounts::User.count }.by(1)

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["token"]).to be_present

        secret = Rails.application.config.x.auth.jwt_secret
        payload, _ = JWT.decode(json["token"], secret, true, { algorithm: 'HS256' })
        expect(payload["user_id"]).to be_present
        expect(payload["address"]).to eq(test_address.downcase)
        expect(payload["chain_id"]).to eq(31_338)
        expect(payload["exp"]).to be_present
      end
    end
  end
end
