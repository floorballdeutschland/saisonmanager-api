FactoryBot.define do
  factory :game_operation do
    sequence(:name) { |n| "Spielverband #{n}" }
    sequence(:short_name) { |n| "GO#{n}" }
  end
end
