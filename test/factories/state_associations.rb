FactoryBot.define do
  factory :state_association do
    sequence(:name) { |n| "Landesverband #{n}" }
    sequence(:short_name) { |n| "LV#{n}" }
  end
end
