FactoryBot.define do
  factory :arena do
    sequence(:name) { |n| "Halle #{n}" }
    sequence(:city) { |n| "Stadt #{n}" }
    # Der Spaltendefault ist false. Ohne diese Zeile baut jeder Test einen
    # Spielort, den Arena.active nicht sieht, und Tests rund um Spielplan,
    # Importvorlage und Spielplan-Import prüfen still den kaputten Pfad (#449).
    active { true }
  end
end
