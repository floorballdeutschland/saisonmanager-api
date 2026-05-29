FactoryBot.define do
  factory :referee do
    sequence(:lizenznummer) { |n| 100_000 + n }
    sequence(:vorname)  { |n| "Vor#{n}" }
    sequence(:nachname) { |n| "Nach#{n}" }
    geburtsdatum { Date.new(1990, 1, 1) }
    guest { false }
  end
end
