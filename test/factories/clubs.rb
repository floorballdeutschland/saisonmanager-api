FactoryBot.define do
  factory :club do
    sequence(:name) { |n| "Club #{n}" }
    # Modulo, damit die Sequenz die Vier-Zeichen-Grenze (Club::SHORT_NAME_MAX)
    # auch in langen Laeufen nicht reisst.
    sequence(:short_name) { |n| "C#{n % 1000}" }

    # Kurzform fuer „dieser Spielbetrieb ist fuer den Verein zustaendig".
    # Gesetzt wird der Landesverband des Spielbetriebs, denn daraus leitet sich
    # die Zustaendigkeit ab (Club#main_game_operation_id). Ohne die Uebersetzung
    # muesste jeder Test die Kette Verein, Landesverband, Spielbetrieb selbst
    # legen.
    #
    # Wer die Kette bewusst pruefen will (untergeordneter Verband, Verbund ohne
    # Spielbetrieb), setzt `state_association:` direkt; dieser Wert gewinnt.
    transient do
      game_operation { nil }
    end

    state_association { game_operation&.state_association }

    # Ein Verein, dessen Stammdaten vollstaendig sind. Seit #641 blockieren
    # fehlende Pflichtangaben jedes Speichern ueber die Vereinsmaske
    # (ClubsController::REQUIRED_CLUB_FIELDS); Tests, die etwas ANDERES an der
    # Maske pruefen, brauchen deshalb einen vollstaendigen Ausgangszustand.
    #
    # Nicht im Grundbaukasten, sondern als Merkmal: Der Bestand auf Produktion
    # ist unvollstaendig, und ein Verein ohne Anschrift muss ein moeglicher
    # Testfall bleiben. `contact_email` gehoert aus demselben Grund hierher --
    # gesetzt entscheidet es mit darueber, wer Vereinspost bekommt
    # (Club#notification_emails).
    trait :mit_stammdaten do
      long_name { "#{name} e.V." }
      street { 'Musterweg' }
      house_number { '1' }
      postcode { '30159' }
      city { 'Hannover' }
      sequence(:contact_email) { |n| "verein#{n}@example.org" }
    end
  end
end
