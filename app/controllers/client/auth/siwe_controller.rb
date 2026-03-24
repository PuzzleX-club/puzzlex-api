# frozen_string_literal: true

class Client::Auth::SiweController < ::Client::PublicController
  require 'securerandom'
  require 'jwt'
  require 'eth'

  # GET /api/nonce
  def nonce
    nonce_str = SecureRandom.hex(16)
    Redis.current.set("nonce:#{nonce_str}", "1", ex: 5 * 60)
    render plain: nonce_str
  end

  # POST /api/verify
  # body: { message, signature }
  def verify
    message = params[:message]
    signature = params[:signature]

    Rails.logger.info "[SIWE] verify接收到的参数:"
    Rails.logger.info "[SIWE] Message: #{message.inspect}"
    Rails.logger.info "[SIWE] Message length: #{message&.length || 0}"
    Rails.logger.info "[SIWE] Signature: #{signature&.first(20)}..." if signature

    if message.blank? || signature.blank?
      render json: { error: 'Missing message or signature' }, status: :bad_request
      return
    end

    address = parse_address_from_message(message)
    if address.blank?
      render json: { error: "No valid address found in message" }, status: :bad_request
      return
    end

    chain_id = parse_chainid_from_message(message)
    if chain_id == 0
      render json: { error: "No valid chainId found in message" }, status: :bad_request
      return
    end

    nonce_str = parse_nonce_from_message(message)
    if nonce_str.blank?
      render json: { error: "No nonce found in message" }, status: :bad_request
      return
    end

    redis_key = "nonce:#{nonce_str}"
    if Redis.current.get(redis_key).nil?
      render json: { error: "Invalid or used nonce" }, status: :unauthorized
      return
    end

    is_valid = verify_signature(address, message, signature, chain_id)
    unless is_valid
      render json: { error: 'Invalid signature' }, status: :unauthorized
      return
    end

    Redis.current.del(redis_key)

    user = if Rails.application.config.x.auth.allow_unregistered_login
             Accounts::User.find_or_create_by!(address: address.downcase)
           else
             Accounts::User.find_by(address: address.downcase)
           end

    if user.nil?
      render json: { error: "Address is not whitelisted!" }, status: :unauthorized
      return
    end

    exp_time = 72.hour.from_now.to_i
    session_chain_id = Rails.env.test? ? 31_338 : chain_id
    payload = { user_id: user.id, address: address, chain_id: session_chain_id, exp: exp_time }
    token = JWT.encode(payload, Rails.application.config.x.auth.jwt_secret, 'HS256')

    render json: { token: token }, status: :ok
  rescue StandardError => e
    render json: { error: e.message }, status: :internal_server_error
  end

  private

  def parse_address_from_message(message)
    match = message.match(ETH_ADDRESS_PATTERN)
    match ? match[0].downcase : ""
  end

  def parse_chainid_from_message(message)
    if (match = message.match(ETH_CHAIN_ID_IN_SIWE_PATTERN))
      match[1].to_i
    else
      0
    end
  end

  def parse_nonce_from_message(message)
    if (match = message.match(ETH_NONCE_PATTERN))
      match[1]
    else
      ""
    end
  end

  def verify_signature(address, message, signature, chain_id)
    prefixed = Eth::Signature.prefix_message(message)
    Rails.logger.info "prefix_message => #{prefixed}"
    hashed_msg = Eth::Util.keccak256(prefixed)

    sig = signature.start_with?("0x") ? signature[2..] : signature
    pubkey = Eth::Signature.recover(hashed_msg, sig)
    rec_addr = Eth::Util.public_key_to_address(pubkey).to_s.downcase

    rec_addr == address.downcase.to_s
  rescue StandardError
    false
  end
end
