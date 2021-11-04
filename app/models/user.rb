class User < ApplicationRecord

  def self.login(user_name, password)
    return nil if user_name.blank? || password.blank?
    hashed_password = Digest::MD5.hexdigest(password)
    user = User.where(user_name: user_name).first



    user if user && user.password == hashed_password
  end
end
