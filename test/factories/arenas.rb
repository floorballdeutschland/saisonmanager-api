FactoryBot.define do
  factory :arena do
    sequence(:name) { |n| "Halle #{n}" }
    sequence(:city) { |n| "Stadt #{n}" }
  end
end
