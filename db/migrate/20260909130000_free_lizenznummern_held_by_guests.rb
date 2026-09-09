# Gäste tragen keine Lizenznummer — sie sind Aushilfen ohne eigene
# Zuständigkeit im Verband und werden als "G-<id>" geführt. Über das
# Anlageformular haben trotzdem welche eine bekommen: Es belegt das Feld mit
# der nächsten freien Nummer vor, und der Haken "Gast" blendete es nur aus.
#
# Folgenschwer, weil die automatische Vergabe (Kursimport, Vorbelegung im
# Formular) den höchsten Wert über die Nicht-Gäste gesucht hat: Die Nummer
# eines Gasts galt als frei, wurde erneut vergeben und lief in die
# Eindeutigkeit — im Kursimport rollte das den kompletten Submit zurück.
#
# Diese Migration gibt die belegten Nummern frei. Der Spielplan-Text der
# betroffenen Spiele wird mitgezogen: Er wird beim Veröffentlichen einer
# Ansetzung als "<lizenznummer> Nachname, Vorname" geschrieben und stünde
# sonst mit einer Nummer da, die später einem anderen Menschen gehört. Die
# Ansetzungen selbst verweisen über die Datensatz-ID und bleiben unberührt.
class FreeLizenznummernHeldByGuests < ActiveRecord::Migration[7.2]
  def up
    freed = Referee.where(guest: true).where.not(lizenznummer: nil).pluck(:id, :lizenznummer)
    return if freed.empty?

    numbers = freed.map(&:last)
    Referee.where(id: freed.map(&:first)).update_all(lizenznummer: nil)
    say "Lizenznummer bei #{freed.size} Gast-Schiedsrichter(n) freigegeben: #{numbers.join(', ')}"

    prefix = /\A(?:#{numbers.join('|')})\s+/
    Game.where.not(nominated_referee_string: [nil, ''])
        .where('nominated_referee_string ~ ?', "(^| )(#{numbers.join('|')}) ")
        .find_each do |game|
      bereinigt = game.nominated_referee_string.split(' / ').map { |teil| teil.sub(prefix, '') }.join(' / ')
      next if bereinigt == game.nominated_referee_string

      game.update_columns(nominated_referee_string: bereinigt)
      say "Spiel #{game.id}: Spielplan-Text auf '#{bereinigt}' gesetzt"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
