# Gäste tragen keine Lizenznummer — sie sind Aushilfen ohne eigene
# Zuständigkeit im Verband und werden als "G-<id>" geführt. Über das
# Anlageformular haben trotzdem welche eine bekommen: Es belegt das Feld mit
# der nächsten freien Nummer vor, und der Haken "Gast" blendete es nur aus.
#
# Folgenschwer, weil die automatische Vergabe (Kursimport, Vorbelegung im
# Formular) den höchsten Wert über die Nicht-Gäste gesucht hat: Die Nummer
# eines Gasts galt als frei und sollte ein zweites Mal vergeben werden — die
# Eindeutigkeitsprüfung schlug zu, und im Kursimport rollte das den kompletten
# Submit zurück. Doppelt vergebene Nummern liegen also nicht in der Datenbank.
#
# Diese Migration gibt die belegten Nummern frei — aber nur die, an denen
# nichts mehr hängt. Eine freigegebene Nummer wird nämlich sofort wieder
# vergeben (sie ist typischerweise das Maximum), und mehrere Stellen
# verknüpfen über die NUMMER statt über den Datensatz: `games.referee_ids`
# und `games.referee1_string`/`referee2_string` aus dem Spielbericht, dazu
# `referees.partner_lizenznummer`. Stünde die Nummer dort noch, erbte der
# nächste Inhaber die Spiele des Gasts — bis in die Abrechnung. Solche
# Nummern bleiben deshalb liegen und werden gemeldet, statt still freigegeben
# zu werden. Harmlos ist das, seit die Vergabe alle Schiedsrichter mitzählt.
#
# Der Spielplan-Text `games.nominated_referee_string` wird dagegen mitgezogen:
# Er wird beim Veröffentlichen einer Ansetzung als "<lizenznummer> Nachname,
# Vorname" geschrieben, ist reine Anzeige und verknüpft nichts. Bereinigt wird
# nur diese vorangestellte Form; das Feld trägt auch Freitext, alles andere
# bleibt stehen und wird gemeldet. Die Ansetzungen selbst verweisen über die
# Datensatz-ID und bleiben unberührt.
class FreeLizenznummernHeldByGuests < ActiveRecord::Migration[7.2]
  def up
    kandidaten = Referee.where(guest: true).where.not(lizenznummer: nil).pluck(:id, :lizenznummer)
    return if kandidaten.empty?

    behalten, freizugeben = kandidaten.partition { |(_id, nummer)| referenced?(nummer) }
    behalten.each do |(id, nummer)|
      say "Gast #{id} behaelt #{nummer}: die Nummer steht noch in einem Spielbericht " \
          'oder in einem Gespann -- von Hand pruefen'
    end
    return if freizugeben.empty?

    numbers = freizugeben.map(&:last)
    Referee.where(id: freizugeben.map(&:first)).update_all(lizenznummer: nil)
    say "Lizenznummer bei #{freizugeben.size} Gast-Schiedsrichter(n) freigegeben: #{numbers.join(', ')}"

    clean_schedule_strings(numbers)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Verweise, die an der Nummer hängen statt am Datensatz. Vorbild ist
  # Referee#_rewrite_referee_game_references, das beim Zusammenführen genau
  # diese Felder umschreibt.
  def referenced?(nummer)
    Game.where('? = ANY(referee_ids)', nummer).exists? ||
      Game.where('referee1_string LIKE :p OR referee2_string LIKE :p', p: "#{nummer} %").exists? ||
      Referee.where(partner_lizenznummer: nummer).exists?
  end

  def clean_schedule_strings(numbers)
    prefix = /\A(?:#{numbers.join('|')})\s+/
    Game.where.not(nominated_referee_string: [nil, ''])
        .where('nominated_referee_string ~ ?', "(^| )(#{numbers.join('|')}) ")
        .find_each do |game|
      bereinigt = game.nominated_referee_string.split(' / ')
                      .map { |teil| teil.sub(prefix, '') }.join(' / ')
      if bereinigt == game.nominated_referee_string
        # Die Nummer steht mitten im Text (Freitext, Importspalte). Nicht
        # raten -- melden, sonst bleibt sie unbemerkt im Spielplan stehen.
        say "Spiel #{game.id}: Nummer im Spielplan-Text nicht am Anfang " \
            "('#{game.nominated_referee_string}') -- von Hand pruefen"
        next
      end

      game.update_columns(nominated_referee_string: bereinigt)
      say "Spiel #{game.id}: Spielplan-Text auf '#{bereinigt}' gesetzt"
    end
  end
end
