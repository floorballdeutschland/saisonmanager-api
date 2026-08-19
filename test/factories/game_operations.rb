FactoryBot.define do
  factory :game_operation do
    sequence(:name) { |n| "Spielverband #{n}" }
    sequence(:short_name) { |n| "GO#{n}" }

    # Jeder Spielbetrieb bekommt einen eigenen Landesverband, wie in Produktion:
    # dort hat jeder der zehn genau einen. Das ist keine Kosmetik, sondern
    # Voraussetzung fuer die Zustaendigkeit: Sie laeuft vom Verein ueber dessen
    # Landesverband und die Wurzel der Verbandskette zum Spielbetrieb
    # (Club#main_game_operation_id). Ein Spielbetrieb ohne Landesverband ist fuer
    # keinen Verein zustaendig, und ein Test mit so einem Spielbetrieb pruefte
    # lautlos den leeren Fall.
    state_association

    # Bundesebene (FD): permission_hash kollabiert SBK/RSK/Ansetzer auf den
    # globalen Scope 0. Seit #180 explizit über das national-Flag, nicht mehr
    # über ein fehlendes state_association_id.
    trait :national do
      national { true }
    end
  end
end
