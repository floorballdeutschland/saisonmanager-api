# frozen_string_literal: true

# `{ trikot_number:, name: }` zu einer Person eines Spiels, in öffentlicher
# Anzeigeform (DSGVO, siehe PublicPlayerNames): Vorname und Nachname, der
# Nachname fällt bei einem Antrag weg.
#
# Quelle ist allein der Spielbericht-Schnappschuss (`games.players`), wie auf
# der öffentlichen Spielseite. Wer dort nicht (mehr) steht, bekommt keinen
# Namen; ein Nachschlagen im Spielerprofil gäbe Personen heraus, die laut
# Bericht nicht gespielt haben.
class PublicPersonRefs
  def initialize(game)
    @game = game
    @hidden = PublicPlayerNames.hidden_ids
  end

  # Über die Spieler-ID (Schüsse).
  def ref(side, player_id)
    return nil if player_id.blank?

    entry = lineup(side).find { |p| p['player_id'].to_i == player_id.to_i }
    entry && from_entry(entry)
  end

  # Über die Trikotnummer (Ereignisse).
  def ref_by_number(side, number)
    entry = @game.public_lineup_entry(side, number)
    entry && from_entry(entry)
  end

  private

  def lineup(side)
    players = @game.players.is_a?(Hash) ? @game.players : {}
    Array(players[side.to_s])
  end

  def from_entry(entry)
    masked = PublicPlayerNames.mask_lineup_entry(entry, @hidden)
    number = masked['trikot_number']
    {
      trikot_number: number.present? ? number.to_i : nil,
      name: "#{masked['player_firstname']} #{masked['player_name']}".squish
    }
  end
end
