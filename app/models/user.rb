class User < ApplicationRecord

  
  def self.login(user_name, password)
    hashed_password = Digest::MD5.hexdigest password
    user = User.where(user_name: user_name).first

    generate_token(user.id, user.user_name) if user.password == hashed_password
  end

  def self.check_token(token)
    secret = Rails.application.secrets.secret_key_base
    decoded_token = JWT.decode token, secret, true, { :algorithm => 'HS512' }

    decoded_token.first['id'] if decoded_token.present?
  rescue JWT::ExpiredSignature, JWT::VerificationError, JWT::DecodeError
    nil
  end

  def self.generate_token(number, user_name, expires_at=(Time.now.to_i + 1.days))
    payload = {
      id: number,
      user_name: user_name,
      exp: expires_at
    }
    secret = Rails.application.secrets.secret_key_base

    JWT.encode payload, secret, 'HS512'
  end
end
