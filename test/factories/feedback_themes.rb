FactoryBot.define do
  factory :feedback_theme do
    sequence(:name) { |n| "Thema #{n}" }
  end
end
