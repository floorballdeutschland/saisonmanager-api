FactoryBot.define do
  factory :api_key do
    sequence(:name) { |n| "Testkey #{n}" }
    # Der Klartext-Key wird nie gespeichert; für Tests genügt ein eindeutiger
    # Digest. Wer den Klartext braucht, nutzt ApiKey.generate.
    sequence(:key_digest) { |n| Digest::SHA256.hexdigest("test-api-key-#{n}") }
    active { true }
  end

  factory :api_key_application do
    sequence(:organisation) { |n| "Testverein #{n}" }
    contact_name { 'Test Person' }
    sequence(:email) { |n| "antrag#{n}@example.com" }
    project_description { 'Widget mit Spielplan und Tabelle für die Vereinswebsite.' }
    purpose { 'Einbindung auf der eigenen Website, nicht-kommerziell.' }
    commercial { false }
    terms_version { ApiTerms::VERSION }
    accepted_terms_at { Time.current }
    status { 'pending' }
  end
end
