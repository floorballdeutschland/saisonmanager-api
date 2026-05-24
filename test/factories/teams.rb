FactoryBot.define do
  factory :team do
    association :league
    association :club
    sequence(:name) { |n| "Team #{n}" }
  end
end
