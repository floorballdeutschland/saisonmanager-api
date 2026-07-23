FactoryBot.define do
  factory :referee_feedback do
    association :game
    association :team
    line_rating { 7 }
    communication_rating { 8 }
    status { 'visible' }
  end
end
