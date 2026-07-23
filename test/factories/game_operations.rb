FactoryBot.define do
  factory :game_operation do
    sequence(:name) { |n| "Spielverband #{n}" }
    sequence(:short_name) { |n| "GO#{n}" }

    # Bundesebene (FD): permission_hash kollabiert SBK/RSK/Ansetzer auf den
    # globalen Scope 0. Seit #180 explizit über das national-Flag, nicht mehr
    # über ein fehlendes state_association_id.
    trait :national do
      national { true }
    end
  end
end
