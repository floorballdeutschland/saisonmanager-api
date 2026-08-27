# lib/tasks/backfill_profile_releases.rake
#
# Traegt fuer Freigaben (Zweitspielrecht), die ueber das Spielerprofil erteilt wurden, die
# fehlende Vorgangszeile in `transfer_requests` nach.
#
# Ursache: Eine Freigabe entsteht auf zwei Wegen. Der Antragsweg
# (`TransferRequest#execute_release!`) schreibt den Eintrag in `players.clubs` UND fuehrt
# einen Vorgang mit; das Spielerprofil (`PlayersController#add_additional_club`) schrieb bis
# api#572 nur nach `players.clubs`. Die Uebersicht „Transferantraege" liest die Vorgaenge --
# eine im Profil erteilte Freigabe war dort nie zu sehen. api#572 behebt das fuer neue
# Freigaben, dieser Lauf holt die der laufenden Saison nach.
#
# Was der Lauf aus dem clubs-Eintrag lesen kann und was er ableiten muss:
#
#   aufnehmender Verein   `club_id`, steht da
#   handelndes Konto      `created_by`, steht da
#   Zeitpunkt             `created_at`, steht da
#   abgebender Verein     ABGELEITET: der Heimatverein, der zum Zeitpunkt der Freigabe lief
#
# Die Ableitung ist die einzige Stelle, an der sich der Lauf irren koennte, deshalb ist sie
# streng: Genau EIN Heimat-Eintrag muss zum Zeitpunkt gelaufen haben (begonnen davor oder
# undatiert, nicht vorher beendet), der Verein muss es noch geben, und er darf nicht der
# aufnehmende sein. Alles andere wird uebersprungen und gezaehlt, nie geraten -- ein falsch
# benannter abgebender Verein waere in der Uebersicht nicht als Fehler zu erkennen, eine
# fehlende Zeile dagegen ist genau der Zustand von vorher. Auf Produktion war die Ableitung
# am 27.08.2026 fuer alle 17 nachzutragenden Eintraege eindeutig.
#
# Beendete Freigaben: Ein `valid_until`, das nicht auf dem regulaeren Stichtag (15.07.,
# 00:00) liegt, kann nur von Hand gesetzt worden sein -- die Freigabe wurde vorzeitig
# beendet. Der Vorgang entsteht dann gleich als `revoked`, mit dem Konto und dem Zeitpunkt
# aus dem Eintrag. Ein Eintrag, der am Stichtag ausgelaufen ist, bleibt `approved`:
# Auslaufen ist kein Widerruf.
#
# Der Vorgang traegt das Datum der Freigabe und nicht das des Laufs (`created_at` wird
# nachgesetzt), sonst stuenden alle 17 Zeilen am Tag des Laufs in der Uebersicht.
#
# Bewusst nur die laufende Saison: `season_id` ist Pflichtspalte, und der Lauf setzt die
# aktuelle. Fuer aeltere Freigaben waere sie zu ermitteln, und ein Vorgang, den in der
# Uebersicht ohnehin niemand mehr sucht, waere den Aufwand nicht wert. SINCE laesst sich
# deshalb nur innerhalb der laufenden Saison verschieben; frueher weist der Lauf ab.
#
# Nicht bloss Anzeige: `League.license_release_dates` liest genau `release`+`approved` und
# speist damit die Spalte „Freigabedatum" der Lizenzliste. Die nachgetragenen Zeilen fuellen
# dort also eine fristenrelevante Angabe, die fuer im Profil erteilte Freigaben bisher leer
# blieb. Das ist gewollt und der Grund fuer die Strenge dieses Laufs.
#
# Zuerst api#572 ausliefern, dann diesen Lauf. Sonst entstehen zwischen Lauf und Auslieferung
# neue Eintraege ohne Vorgang.
#
# Dry-Run (Standard):
#   bundle exec rails transfers:backfill_profile_releases
# Ausfuehren:
#   bundle exec rails transfers:backfill_profile_releases DRY_RUN=false
# Anderer Startzeitpunkt (Vorgabe: 01.07.2026, Beginn der laufenden Saison):
#   SINCE=2026-07-01

# Regulaeres Ende einer Freigabe: 15.07., 00:00 Uhr. `add_additional_club` und
# `TransferRequest#add_secondary_club_membership!` setzen beide genau das
# (`Date.new(jahr, 7, 15).to_time`).
#
# Gelesen wird mit `Time.parse` und nicht mit `Time.zone.parse`: Nur ersteres behaelt den
# Versatz, den die Zeichenkette selbst traegt. Geschrieben wurde Mitternacht in der Zone des
# schreibenden Prozesses -- auf dem Server UTC, auf einem Entwicklungsrechner Berlin --, und
# in die Anwendungszone (UTC) umgerechnet waere aus der Berliner Variante 22:00 Uhr des
# Vortags geworden. Der Lauf haette die Freigabe dann als von Hand beendet gelesen und einen
# Widerruf erfunden, den es nie gab.
def _release_regulaeres_ende?(roh)
  zeitpunkt = begin
    Time.parse(roh.to_s)
  rescue StandardError
    nil
  end
  return false if zeitpunkt.nil?

  zeitpunkt.month == 7 && zeitpunkt.day == 15 &&
    zeitpunkt.hour.zero? && zeitpunkt.min.zero? && zeitpunkt.sec.zero?
end

# Beginn der laufenden Spielzeit: der 1. Juli, der zuletzt vergangen ist. Derselbe
# Stichtag, um den herum die Freigaben auslaufen (15.07.).
def _release_saisonbeginn
  beginn = Time.zone.local(Date.current.year, 7, 1)
  beginn -= 1.year if beginn > Time.current
  beginn
end

# Eine Konto-Kennung aus dem JSONB, oder nil. Wie oben: kein blindes `.to_i`.
def _release_konto(wert)
  id = Integer(wert.to_s, exception: false)
  id if id && User.exists?(id: id)
end

def _release_zeit(wert)
  return nil if wert.blank?

  Time.zone.parse(wert.to_s)
rescue StandardError
  nil
end

# Der Heimatverein, der zum Zeitpunkt der Freigabe lief. Liefert die Liste, damit der
# Aufrufer Mehrdeutigkeit erkennen kann, statt sie mit `.first` zu verdecken.
def _release_heimat_zum_zeitpunkt(player, zeitpunkt)
  laufend = Array(player.clubs).select do |c|
    next false unless c.is_a?(Hash)
    next false unless ActiveModel::Type::Boolean.new.cast(c['home_club'])

    beginn = _release_zeit(c['created_at'])
    ende   = _release_zeit(c['valid_until'])
    (beginn.nil? || beginn <= zeitpunkt) && (ende.nil? || ende > zeitpunkt)
  end

  laufend.map { |c| c['club_id'].to_i }.uniq
end

# Gibt es zu diesem clubs-Eintrag schon einen Vorgang?
#
# Verglichen wird der Zeitpunkt des Eintrags mit dem Zeitpunkt, an dem der Vorgang die
# Mitgliedschaft geschrieben hat (`lv_approved_at`), nicht mit seinem `created_at`: Der
# Antragsweg laeuft ueber Tage, angelegt wird der Vorgang beim Stellen, geschrieben wird der
# Eintrag beim Genehmigen. Das Fenster von einem Tag ist grosszuegig; zwei Freigaben
# desselben Profils an denselben Verein innerhalb eines Tages gibt es nicht.
def _release_vorgang_vorhanden?(vorgaenge, player_id, club_id, zeitpunkt)
  Array(vorgaenge[[player_id, club_id]]).any? do |massgeblich|
    (massgeblich - zeitpunkt).abs <= 1.day
  end
end

namespace :transfers do
  desc 'Vorgangszeilen fuer im Spielerprofil erteilte Freigaben nachtragen. DRY_RUN=false zum Ausfuehren.'
  task backfill_profile_releases: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    since = _release_zeit(ENV['SINCE'].presence || '2026-07-01')
    abort 'SINCE ist kein lesbarer Zeitpunkt' if since.nil?

    season_id = Setting.current_season_id
    abort 'Keine aktuelle Saison gesetzt' if season_id.blank?

    # Der Lauf stempelt jede Zeile mit der LAUFENDEN Saison. Eine aeltere Freigabe
    # bekaeme damit die falsche, und das bleibt unsichtbar: Die Lizenzliste
    # schluesselt ueber `League.release_date_for` nach der Saison der Liga auf, das
    # Freigabedatum erschiene also in der falschen Liste und fehlte in der
    # richtigen. Eine Konvention im Kopfkommentar ist dagegen kein Schutz.
    if since < _release_saisonbeginn
      abort "SINCE #{since.strftime('%d.%m.%Y')} liegt vor dem Beginn der laufenden Saison " \
            "(#{_release_saisonbeginn.strftime('%d.%m.%Y')}). Der Lauf stempelt die laufende Saison " \
            'und darf deshalb nicht weiter zurueckreichen.'
    end

    puts "=== Freigaben aus dem Spielerprofil nachtragen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Zeitraum ab #{since.strftime('%d.%m.%Y')}, Saison #{season_id}"
    puts

    # Vorfilter in SQL ueber den Datumspraefix der Zeichenkette: `created_at` liegt im JSONB
    # in verschiedenen Schreibweisen vor, ein Cast nach timestamptz wuerde am ersten
    # unlesbaren Wert des Altbestands hochgehen. Der Praefixvergleich ist fuer ein
    # ISO-Datum am Anfang der Zeichenkette schreibweisenunabhaengig; gelesen und geprueft
    # wird danach in Ruby.
    sql = <<~SQL.squish
      SELECT p.id, e
      FROM players p, jsonb_array_elements(p.clubs) e
      WHERE p.merged_into_id IS NULL
        AND (e->>'home_club') IN ('false','f')
        AND (e->>'created_at') IS NOT NULL
        AND (e->>'created_at') >= #{ActiveRecord::Base.connection.quote(since.strftime('%Y-%m-%d'))}
    SQL

    # Unlesbares wird gezaehlt und ausgegeben, nicht verworfen: Der Praefixfilter
    # oben laesst jede Schreibweise durch, die mit einem ISO-Datum beginnt, und der
    # Kommentar dort begruendet ihn gerade damit, dass der Altbestand unlesbare
    # Werte enthaelt. Fielen sie hier lautlos heraus, taeuschte die Schlusszeile
    # Vollstaendigkeit vor. `JSON.parse` ebenso: ein Abbruch mitten im Lauf liesse
    # den Bediener ohne Bilanz zurueck.
    unlesbar = []
    roh_eintraege = ActiveRecord::Base.connection.select_rows(sql).filter_map do |player_id, roh|
      eintrag = begin
        roh.is_a?(String) ? JSON.parse(roh) : roh
      rescue JSON::ParserError => e
        unlesbar << "##{player_id}: clubs-Eintrag nicht lesbar (#{e.message})"
        next
      end

      zeitpunkt = _release_zeit(eintrag['created_at'])
      if zeitpunkt.nil?
        unlesbar << "##{player_id}: created_at nicht lesbar (#{eintrag['created_at'].inspect})"
        next
      end
      next if zeitpunkt < since

      [player_id.to_i, eintrag, zeitpunkt]
    end

    eintraege = roh_eintraege.sort_by { |_, _, zeitpunkt| zeitpunkt }

    # Bestehende Freigabe-Vorgaenge einmal einsammeln statt je Eintrag abzufragen.
    vorgaenge = Hash.new { |h, k| h[k] = [] }
    TransferRequest.where(request_type: 'release').where('created_at >= ?', since - 60.days)
                   .find_each do |tr|
      vorgaenge[[tr.player_id, tr.requesting_club_id]] << (tr.lv_approved_at || tr.created_at)
    end

    players = Player.where(id: eintraege.map(&:first).uniq).index_by(&:id)

    nachgetragen = 0
    vorhanden = 0
    uebersprungen = 0
    fehler = 0

    eintraege.each do |player_id, eintrag, zeitpunkt|
      club_id = eintrag['club_id'].to_i
      player = players[player_id]
      unless player
        puts "##{player_id}: Profil nicht gefunden -- uebersprungen"
        uebersprungen += 1
        next
      end

      kennung = "##{player_id} #{player.first_name} #{player.last_name}"

      if _release_vorgang_vorhanden?(vorgaenge, player_id, club_id, zeitpunkt)
        vorhanden += 1
        next
      end

      # `.to_i` genuegt nicht: `created_by` ist NOT NULL ohne Fremdschluessel, ein
      # nicht-numerischer Altwert wuerde als Konto 0 geschrieben und stuende in der
      # Uebersicht als Vorgang ohne auflösbares Konto. Der Lauf ist an jeder anderen
      # Ableitungsstelle streng, hier auch.
      handelnd = Integer(eintrag['created_by'].to_s, exception: false)
      unless handelnd && User.exists?(id: handelnd)
        puts "#{kennung}: kein gueltiges handelndes Konto am Eintrag (#{eintrag['created_by'].inspect}) -- uebersprungen"
        uebersprungen += 1
        next
      end

      heimat = _release_heimat_zum_zeitpunkt(player, zeitpunkt)
      if heimat.size != 1
        puts "#{kennung}: abgebender Verein nicht eindeutig (#{heimat.inspect}) -- uebersprungen"
        uebersprungen += 1
        next
      end

      former_club_id = heimat.first
      if former_club_id == club_id
        puts "#{kennung}: abgebender und aufnehmender Verein identisch (#{club_id}) -- uebersprungen"
        uebersprungen += 1
        next
      end

      unless Club.exists?(id: former_club_id) && Club.exists?(id: club_id)
        puts "#{kennung}: Verein nicht mehr vorhanden (#{former_club_id} → #{club_id}) -- uebersprungen"
        uebersprungen += 1
        next
      end

      # Ein vorhandenes, aber unlesbares Enddatum wird nicht ausgelegt: Beide
      # Auslegungen schreiben etwas Falsches -- als „laeuft noch" stuende eine
      # Freigabe in der Uebersicht und in der Lizenzliste, die es nicht gibt, als
      # „beendet" ein erfundener Widerruf. Und weil `_release_regulaeres_ende?`
      # bewusst mit einem anderen Parser liest (siehe dort), faellt ein Wert, den
      # nur einer der beiden versteht, sonst genau in die schreibende Auslegung.
      if eintrag['valid_until'].present? && _release_zeit(eintrag['valid_until']).nil?
        puts "#{kennung}: Enddatum nicht lesbar (#{eintrag['valid_until'].inspect}) -- uebersprungen"
        uebersprungen += 1
        next
      end

      ende = _release_zeit(eintrag['valid_until'])
      vorzeitig_beendet = ende.present? && ende < Time.current &&
                          !_release_regulaeres_ende?(eintrag['valid_until'])

      puts "#{kennung}: #{former_club_id} → #{club_id} am #{zeitpunkt.strftime('%d.%m.%Y')}" \
           "#{vorzeitig_beendet ? " (beendet am #{ende.strftime('%d.%m.%Y')})" : ''}"

      if dry_run
        nachgetragen += 1
        next
      end

      begin
        ActiveRecord::Base.transaction do
          tr = TransferRequest.create!(
            player_id: player_id,
            requesting_club_id: club_id,
            former_club_id: former_club_id,
            status: 'approved',
            request_type: 'release',
            direct: true,
            created_by: handelnd,
            approved_by_lv_user_id: handelnd,
            lv_approved_at: zeitpunkt,
            season_id: season_id
          )

          if vorzeitig_beendet
            tr.update!(
              status: 'revoked',
              revoked_by: _release_konto(eintrag['valid_set_by']) || handelnd,
              revoked_at: ende,
              revocation_reason: 'Freigabe im Spielerprofil beendet'
            )
          end

          # `created_at` traegt in der Uebersicht das Datum der Freigabe, und
          # `before_create` erzeugt einen Bestaetigungslink, der zu einem laufenden Antrag
          # gehoert. Beides ausserhalb der Validierungen nachziehen.
          tr.update_columns(created_at: zeitpunkt, updated_at: zeitpunkt, player_confirmation_token: nil)
        end
        nachgetragen += 1
      rescue StandardError => e
        # Mit Backtrace: Der Rumpf schreibt in drei Schritten (create!, update!,
        # update_columns), und ohne ihn ist hinterher nicht zu sagen, welcher.
        puts "  FEHLER: #{e.class}: #{e.message}"
        puts(e.backtrace.first(5).map { |z| "    #{z}" })
        fehler += 1
      end
    end

    # Nicht subtrahiert, sondern gezaehlt: „alles, was sonst nirgends gezaehlt
    # wurde" meldete jeden kuenftig ergaenzten Abbruchzweig stillschweigend als
    # Erfolg.
    puts
    unlesbar.each { |zeile| puts "NICHT GELESEN #{zeile}" }
    puts "#{eintraege.size} Zweitvereins-Eintraege im Zeitraum: #{vorhanden} mit Vorgang, " \
         "#{nachgetragen} #{dry_run ? 'nachzutragen' : 'nachgetragen'}, " \
         "#{uebersprungen} uebersprungen, #{unlesbar.size} nicht lesbar, #{fehler} Fehler."
    puts 'Dry-Run — nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run

    # Ein unlesbarer Eintrag ist kein Fehler DIESES Laufs, aber er gehoert vor
    # Augen: Er zaehlt in den Exit-Code, damit ein protokollierter Lauf nicht grün
    # meldet, obwohl etwas ungesehen liegen blieb. Die bewussten Auslassungen
    # (`uebersprungen`) tun das nicht -- sie sind das erwartete Ergebnis.
    exit 1 if fehler.positive? || unlesbar.any?
  end
end
