class Player < ApplicationRecord

  belongs_to :created_at_user, class_name: "User"
  belongs_to :updated_at_user, class_name: "User"

  def nation_string
    setting = Setting.first
    nations = setting["nations"]

    nations[nation_id.to_s]["name"]
  end

  def created_by_string
    created_at_user.user_name if created_at_user.present?
  end

  def updated_by_string
    updated_at_user.user_name if updated_at_user.present?
  end
end
