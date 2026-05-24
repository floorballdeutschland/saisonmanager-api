FactoryBot.define do
  factory :club do
    sequence(:name) { |n| "Club #{n}" }
    sequence(:short_name) { |n| "C#{n}" }
  end
end
