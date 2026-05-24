FactoryBot.define do
  factory :league do
    association :game_operation
    sequence(:name) { |n| "Liga #{n}" }
    season_id { '18' }                  # aktuelle Saison; per Trait änderbar
    table_modus { 'classic' }
    league_category_id { '1' }
    league_class_id { '1' }

    # Mit Trait klare Saison-Semantik im Test ablesbar:
    trait :current_season do
      season_id { '18' }
    end

    trait :previous_season do
      season_id { '17' }
    end

    trait :archived_season do
      # Saison vor langer Zeit, deren Teams in der Live-DB nicht mehr sind.
      season_id { '10' }
    end
  end
end
