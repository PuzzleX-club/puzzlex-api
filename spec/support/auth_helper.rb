module AuthHelper
  def generate_jwt_for(user)
    payload = {
      user_id: user.id,
      address: user.address,
      chain_id: "1",
      exp: 1.hour.from_now.to_i
    }
    JWT.encode(payload, Rails.application.config.x.auth.jwt_secret, 'HS256')
  end
end