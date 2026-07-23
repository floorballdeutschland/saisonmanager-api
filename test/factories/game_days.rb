FactoryBot.define do
  factory :game_day do
    association :league
    association :arena
    association :club
    sequence(:number) { |n| n }
    date { '2026-01-15' }
  end
end
