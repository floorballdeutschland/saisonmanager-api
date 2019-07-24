class User < ApplicationRecord


  def self.login(user_name, password)
    return nil if user_name.blank? || password.blank?
    hashed_password = Digest::MD5.hexdigest(password)
    user = User.where(user_name: user_name).first

    user if user && user.password == hashed_password
  end

  def self.check_token(token)
    secret = Rails.application.secrets.secret_key_base
    decoded_token = JWT.decode token, secret, true, { :algorithm => 'HS512' }

    decoded_token.first['id'] if decoded_token.present?
  rescue JWT::ExpiredSignature, JWT::VerificationError, JWT::DecodeError
    nil
  end

  def self.generate_token(user, expires_at=(Time.now + 1.days).to_i)
    payload = {
      id: user.id,
      user_name: user.user_name,
      exp: expires_at
    }
    secret = Rails.application.secrets.secret_key_base

    JWT.encode payload, secret, 'HS512'
  end
end
