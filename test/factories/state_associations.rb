FactoryBot.define do
  factory :state_association do
    sequence(:name) { |n| "Landesverband #{n}" }
    sequence(:short_name) { |n| "LV#{n}" }

    # Die drei Ansetzungs-Optionen sind gestaffelt: die Personenebene
    # (referee_assignment_enabled) setzt den Hauptschalter voraus. In echten Daten
    # gilt das ausnahmslos – die Migration hat den Hauptschalter überall
    # nachgezogen, wo die Personenebene an war, und
    # Admin::StateAssociationsController räumt widersprüchliche Kombinationen beim
    # Speichern auf. Damit `referee_assignment_enabled: true` im Test denselben
    # Verband beschreibt wie in Produktion, wird der Hauptschalter mitgesetzt.
    #
    # Für den Vereins-Modus (Weg 3) nur `referee_assignment_external_enabled: true`
    # setzen. Den ungültigen Zustand „Personenebene ohne Hauptschalter" muss ein
    # Test bewusst per update_column herstellen.
    after(:build) do |sa|
      sa.referee_assignment_external_enabled = true if sa.referee_assignment_enabled
    end
  end
end
