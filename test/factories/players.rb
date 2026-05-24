FactoryBot.define do
  factory :player do
    sequence(:first_name) { |n| "Vorname#{n}" }
    sequence(:last_name)  { |n| "Nachname#{n}" }
    birthdate { '1990-01-01' }
    nation_id { '1' }
    gender { 'm' }
    clubs { [] }
    licenses { [] }

    # Lizenz-Helper: bauen einen License-Hash so wie er in Player#licenses
    # (JSONB) liegt. Status-IDs sind:
    #   1 APPROVED · 2 REQUESTED · 3 DENIED · 4 DELETED · 8 WITHDRAWN
    transient do
      with_licenses { [] }
    end

    after(:build) do |player, evaluator|
      next if evaluator.with_licenses.blank?

      player.licenses = evaluator.with_licenses.map do |spec|
        team_id = spec.fetch(:team)&.id
        status_id = spec.fetch(:status, License::APPROVED)
        season_id = spec.fetch(:season_id, spec[:team]&.league&.season_id)
        league_class_id = spec.fetch(:league_class_id, spec[:team]&.league&.league_class_id)

        {
          'team_id' => team_id,
          'season_id' => season_id,
          'league_class_id' => league_class_id,
          'history' => [
            {
              'license_status_id' => status_id,
              # 1 Tag in der Vergangenheit, damit nachträglich appendete
              # History-Einträge (Saisonwechsel-Routine, Mailer etc.) klar
              # später sind als der Initial-Eintrag — relevant für
              # `max_by { |h| h['created_at'] }` über JSONB-String-Timestamps.
              'created_at' => spec.fetch(:created_at, 1.day.ago.iso8601),
              'created_by' => spec.fetch(:created_by, nil)
            }
          ]
        }
      end
    end
  end
end
