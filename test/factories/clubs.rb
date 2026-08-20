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
  end
end
