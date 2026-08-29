FactoryBot.define do
  factory :referee_observation do
    association :game
    association :coach, factory: :referee
    game_operation_id { game.league&.game_operation_id || 1 }
    created_by_user_id { 1 }
    submitted_at { Time.current }
    status { 'visible' }

    match_description { 'Enges Spiel mit hoher Intensität.' }
    stick_play_comment { 'Stocklinie durchgehend einheitlich.' }
    physical_play_comment { 'Körperspiel früh eingefangen.' }
    penalty_line_comment { 'Strafen nachvollziehbar.' }
    game_management_comment { 'Ruhige Spielleitung.' }
    other_matters { 'Keine besonderen Vorkommnisse.' }
    final_comments { 'Weiter an der Kommunikation im Gespann arbeiten.' }

    pair_stick_play_rating { 5 }
    pair_physical_play_rating { 5 }
    pair_penalty_line_rating { 4 }
    pair_game_management_rating { 5 }
    pair_overall_rating { 5 }

    # Bewertung einer Person; ohne sie ist der Bogen ungültig
    # (RefereeObservation#must_rate_at_least_one_referee).
    trait :with_rating do
      transient do
        rated_referee { nil }
      end
      after(:build) do |observation, evaluator|
        observation.ratings.build(
          referee: evaluator.rated_referee || create(:referee),
          position: 1,
          stick_play_rating: 5,
          physical_play_rating: 4,
          penalty_line_rating: 5,
          game_management_rating: 6,
          overall_rating: 5
        )
      end
    end
  end
end
