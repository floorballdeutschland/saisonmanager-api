# frozen_string_literal: true

# `{ trikot_number:, name: }` zu einer Person eines Spiels, in öffentlicher
# Anzeigeform (DSGVO, siehe PublicPlayerNames): Vorname und Nachname, der
# Nachname fällt bei einem Antrag weg.
#
# Quelle ist der Spielbericht-Schnappschuss (`games.players`), wie auf der
# öffentlichen Spielseite. Nur wer dort nicht steht, wird im Spielerprofil
# nachgeschlagen, dann ohne Trikotnummer.
class PublicPersonRefs
  def initialize(game)
    @game = game
    @hidden = PublicPlayerNames.hidden_ids
  end

  # Über die Spieler-ID (Schüsse).
  def ref(side, player_id)
    return nil if player_id.blank?

    entry = lineup(side).find { |p| p['player_id'].to_i == player_id.to_i }
    return from_entry(entry) if entry

    player = Player.find_by(id: player_id)
    return nil if player.nil?

    first, last = PublicPlayerNames.mask_names(player.id, player.first_name, player.last_name, @hidden)
    { trikot_number: nil, name: "#{first} #{last}".squish }
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
