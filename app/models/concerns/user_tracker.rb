# (concern) e.g. for User model
# https://gist.github.com/kule/9425fb7d4c2a13e556ef
module UserTracker
  extend ActiveSupport::Concern

  included do
    def self.current_user=(user)
      RequestStore.store[:ut_current_user] = user
    end

    def self.current_user
      RequestStore.store[:ut_current_user]
    end
  end
end
