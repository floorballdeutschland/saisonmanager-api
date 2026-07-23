FactoryBot.define do
  factory :game do
    association :game_day
    officiating_referee_ids { [] }
    referee_ids { [] }
    events { [] }
    players { { 'home' => [], 'guest' => [] } }
    forfait { 0 }
    overtime { false }
    legacy { false }
    started { false }

    # Ein gestartetes Spiel mit Endergebnis (aus JSONB-Events berechnet).
    trait :with_result do
      transient do
        home_goals { 3 }
        guest_goals { 1 }
      end
      started { true }
      events do
        [{ 'row' => 1, 'period' => 1, 'home_goals' => home_goals, 'guest_goals' => guest_goals }]
      end
    end
  end
end
