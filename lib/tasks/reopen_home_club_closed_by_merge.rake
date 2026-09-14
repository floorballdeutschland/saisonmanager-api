# lib/tasks/reopen_home_club_closed_by_merge.rake
#
# Oeffnet den Heimatverein wieder, den eine Zusammenlegung am Tag eines Vereinswechsels
# geschlossen hat.
#
# Ursache: `Player#_close_surplus_home_clubs` arbeitete auf `open_home_club_entries`, und
# dessen Stichtagsvergleich ist tagesgenau -- ein am selben Tag beendeter Eintrag zaehlte
# bis Mitternacht weiter als laufend. Wer also heute den Verein gewechselt hatte, hatte in
# den Augen der Zusammenlegung zwei offene Heimatvereine. Sie behielt einen davon und
# schloss den anderen, und traf sie dabei ueber den Lizenzbeleg den bereits beendeten
# Eintrag, blieb NULL offen: Das Profil steht danach in keiner Vereinsliste, ist nicht
# lizenzierbar und nicht transferierbar. Belegt an Spieler 1047 (Ole Lordieck) am
# 09.09.2026 -- Transfer Berlin Rockets -> SSV Rapid um 11:30, Merge um 11:37, danach ohne
# Verein. Der Code ist mit diesem PR dicht; dieser Lauf raeumt den Bestand nach.
#
# Warum eine Regel im Code und keine Liste: Anders als bei den frueheren Merge-Laeufen ist
# hier nichts abzuwaegen. Der Zustand ist eindeutig falsch (kein Mensch hat keinen Verein),
# und welcher Eintrag wieder aufgehen muss, steht am Datensatz selbst: der zuletzt
# begonnene, geschlossen im Zeitfenster der Zusammenlegung und mit deren Stempel.
#
# Drei Riegel, jeder fuer sich ein Abbruchgrund:
#
#   1. Es darf KEIN Heimatverein mehr laufen. Ein Profil mit einem laufenden Eintrag hat
#      das Problem nicht, und einen zweiten zu oeffnen brauechte genau die Doppeldeutigkeit,
#      gegen die `_close_surplus_home_clubs` ueberhaupt eingefuehrt wurde.
#   2. Geoeffnet wird ausschliesslich der ZULETZT begonnene Heimat-Eintrag. Jeder aeltere
#      ist regulaer beendet worden, und ihn zu oeffnen behauptete eine Mitgliedschaft, die
#      es nicht mehr gibt. Der Riegel unterscheidet ausserdem die beiden Eintraege des
#      Wechseltags voneinander: Bei 1047 liegen beide (11:30 und 11:37) im Fenster der
#      Zusammenlegung und tragen deren Benutzer, nur der spaeter begonnene gehoert auf.
#   3. Der Eintrag muss den Stempel der Zusammenlegung tragen: `valid_set_by` gleich dem
#      ausfuehrenden Benutzer UND ein Ende im Zeitfenster um den Merge-Zeitpunkt. Ohne
#      diesen positiven Beleg wird gemeldet statt geschrieben -- ein Profil kann auch aus
#      ganz anderen Gruenden ohne Verein dastehen (Austritt, Ablage, Altbestand), und die
#      darf dieser Lauf nicht anfassen.
#
# Der Vermerk `home_club_decided_by` geht am zurueckgenommenen Eintrag weg: Er haelt fest,
# nach welcher Regel die Zusammenlegung IHREN Heimatverein gewaehlt hat. Nachdem diese Wahl
# hier aufgehoben wird, stuende er als Aussage ueber einen geschlossenen Eintrag da, die
# nicht mehr stimmt.
#
# Dry-Run (Standard):
#   bundle exec rails players:reopen_home_club_closed_by_merge USER_ID=<id>
# Ausfuehren:
#   bundle exec rails players:reopen_home_club_closed_by_merge USER_ID=<id> DRY_RUN=false
# Nur bestimmte Profile:
#   PLAYER_IDS=1047,4711

# Die Heimat-Eintraege, die WIRKLICH noch laufen: ohne Enddatum oder mit einem Ende nach
# heute. Bewusst nicht `open_home_club_entries` -- dessen tagesgenauer Vergleich ist genau
# die Ursache, die dieser Lauf nachraeumt, und als Vorbedingung saehe er den geschlossenen
# Eintrag bis Mitternacht noch als offen.
def _rhc_laufende_heimat(clubs)
  Array(clubs).select do |c|
    next false unless c.is_a?(Hash)
    next false unless ActiveModel::Type::Boolean.new.cast(c['home_club'])

    c['valid_until'].blank? || _rhc_endet_nach_heute?(c['valid_until'])
  end
end

def _rhc_endet_nach_heute?(valid_until)
  Date.parse(valid_until.to_s) > Date.current
rescue ArgumentError, TypeError
  false
end

# Der zuletzt begonnene Heimat-Eintrag. club_id als zweiter Schluessel, weil `sort_by` in
# Ruby nicht als stabil zugesichert ist und Eintraege ohne created_at (Altbestand) sich
# denselben Schluessel teilen.
def _rhc_juengste_heimat(clubs)
  heimat = Array(clubs).select do |c|
    c.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(c['home_club'])
  end
  heimat.max_by { |c| [c['created_at'].to_s, c['club_id'].to_i] }
end

# Traegt der Eintrag den Stempel dieser Zusammenlegung? Gleiches Merkmal wie in
# `PlayerUnmerging#_merge_closed_membership_club_ids`: derselbe Benutzer und ein Ende im
# Zeitfenster um den Merge.
def _rhc_vom_merge_geschlossen?(eintrag, merge)
  return false if eintrag.blank? || eintrag['valid_until'].blank?
  return false if eintrag['valid_set_by'].blank? || merge.performed_by_user_id.blank?
  return false if eintrag['valid_set_by'].to_i != merge.performed_by_user_id.to_i

  moment = Time.zone.parse(eintrag['valid_until'].to_s)
  return false if moment.nil?

  fenster = PlayerUnmerging::MERGE_CLOSE_WINDOW
  moment.between?(merge.created_at - fenster, merge.created_at + fenster)
rescue ArgumentError, TypeError
  false
end

namespace :players do
  desc 'Vom Merge geschlossenen Heimatverein wieder oeffnen. DRY_RUN=false zum Ausfuehren.'
  task reopen_home_club_closed_by_merge: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    user_id = ENV['USER_ID'].presence&.then { |v| Integer(v, exception: false) }
    nur_ids = ENV['PLAYER_IDS'].to_s.split(',').filter_map { |v| Integer(v, exception: false) }

    # Der Lauf schreibt `updated_by`; ohne Benutzer bliebe die Aenderung anonym.
    abort 'USER_ID fehlt oder ist keine Zahl' if user_id.nil? && !dry_run

    master_ids = MergeLog.where(object_type: 'player').distinct.pluck(:master_id)
    master_ids &= nur_ids if nur_ids.any?

    puts "=== Vom Merge geschlossenen Heimatverein oeffnen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "#{master_ids.size} Zusammenlegungsziel(e) zu pruefen"
    puts

    geoeffnet = 0
    unveraendert = 0
    abweichend = 0
    fehler = 0

    master_ids.sort.each do |master_id|
      player = Player.find_by(id: master_id)
      next if player.nil? || player.merged_into_id.present?

      # Riegel 1: Wer noch einen laufenden Heimatverein hat, ist nicht betroffen.
      if _rhc_laufende_heimat(player.clubs).any?
        unveraendert += 1
        next
      end

      # Riegel 2: nur der zuletzt begonnene Eintrag.
      eintrag = _rhc_juengste_heimat(player.clubs)
      # Riegel 3: und nur mit dem Stempel einer Zusammenlegung dieses Profils.
      merges = MergeLog.where(object_type: 'player', master_id: player.id).order(:created_at)
      merge = merges.find { |m| _rhc_vom_merge_geschlossen?(eintrag, m) }

      if merge.nil?
        # Ohne Heimat-Eintraege ist das der Normalfall vieler Altprofile und keine Meldung
        # wert; mit Eintraegen steht hier ein Profil ohne Verein, das dieser Lauf nicht
        # erklaeren kann -- das gehoert gesehen.
        if eintrag.present?
          puts "##{player.id} #{player.first_name} #{player.last_name}: ohne laufenden Heimatverein, " \
               'aber kein Eintrag mit Merge-Stempel -- bitte pruefen'
          abweichend += 1
        else
          unveraendert += 1
        end
        next
      end

      club = Club.find_by(id: eintrag['club_id'])&.name || eintrag['club_id']
      puts "##{player.id} #{player.first_name} #{player.last_name}: oeffnet #{club} " \
           "(beendet #{eintrag['valid_until']} durch Merge ##{merge.id} vom #{merge.created_at})"

      if dry_run
        geoeffnet += 1
        next
      end

      begin
        ActiveRecord::Base.transaction do
          eintrag.delete('valid_until')
          eintrag.delete('valid_set_by')
          Array(player.clubs).each do |c|
            c.delete(Player::HOME_CLUB_DECIDED_BY) if c.is_a?(Hash)
          end
          player.updated_by = user_id
          player.save!(validate: false)

          nachher = _rhc_laufende_heimat(player.clubs)
          if nachher.size != 1
            raise "Nachbedingung verletzt: #{nachher.size} laufende Heimatvereine statt genau einem"
          end
        end
        geoeffnet += 1
      rescue StandardError => e
        puts "  FEHLER: #{e.class}: #{e.message}"
        fehler += 1
      end
    end

    puts
    puts "#{geoeffnet} Profil(e) #{dry_run ? 'zu oeffnen' : 'geoeffnet'}, " \
         "#{unveraendert} in Ordnung, #{abweichend} zur Handpruefung, #{fehler} Fehler."
    puts 'Dry-Run — nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run
  end
end
