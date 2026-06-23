# frozen_string_literal: true

module LegacyImport
  # Reine Transformationen vom Alt-Schema (MariaDB, Zeilen als Hashes mit den
  # ursprünglichen Spaltennamen) in die Attribut-Hashes / JSONB-Strukturen des
  # neuen Rails-Modells. Keine DB-Zugriffe, keine Seiteneffekte – damit ohne
  # MariaDB in der CI testbar (siehe test/services/legacy_import/transformer_test.rb).
  #
  # Die Auflösung der globalen IDs (id_verein → club_id, id_spieler → player_id,
  # id_spielort → arena_id) erfüllt der Aufrufer über Remap-Tabellen; hier
  # werden sie als Parameter hereingereicht.
  module Transformer
    module_function

    # global_*_liga-Zeile → leagues-Attribute.
    def league_attrs(liga, game_operation_id:)
      kl = Vocab.klasse_attrs(liga['id_klasse'], liga['klasse_name'])
      kat = Vocab.kategorie_attrs(liga['id_kategorie'])

      {
        game_operation_id:,
        season_id: Vocab.season_id(liga['id_saison']),
        name: liga['name'],
        short_name: liga['kurzname'],
        league_class_id: kl[:league_class_id],
        league_category_id: kat[:league_category_id],
        age_group: kl[:age_group],
        female: to_bool(liga['weiblich']) || kl[:female] || false,
        table_modus: Vocab::SPIELSYSTEM_TABLE_MODUS[liga['id_spielsystem'].to_i],
        order_key: liga['ordnungsnr'].to_s,
        deadline: liga['stichtag'],
        legacy_league: true
      }.compact
    end

    # global_*_mannschaft-Zeile → teams-Attribute.
    def team_attrs(mannschaft, league_id:, club_id:, syndicate_club_ids: [])
      {
        league_id:,
        club_id:,
        name: mannschaft['name'],
        short_name: mannschaft['kurzname'],
        approved: to_bool(mannschaft['genehmigt']),
        syndicate: to_bool(mannschaft['sg']),
        syndicate_clubs: syndicate_club_ids
      }.compact
    end

    # global_*_spieltag-Zeile → game_days-Attribute.
    def game_day_attrs(spieltag, league_id:, arena_id:, club_id:)
      {
        league_id:,
        arena_id:,
        club_id:,
        number: spieltag['spieltag_nr'].to_i,
        date: spieltag['datum'].to_s
      }.compact
    end

    # global_*_begegnung-Zeile → games-Attribute (ohne JSONB; die werden über
    # build_events/build_players separat ergänzt). Altspiele gelten als
    # abgeschlossen und werden mit legacy = true entkoppelt.
    def game_attrs(begegnung, game_day_id:, home_team_id:, guest_team_id:, playoff: false)
      {
        game_day_id:,
        home_team_id:,
        guest_team_id:,
        game_number: begegnung['spielnummer'].to_s.presence,
        start_time: begegnung['uhrzeit'],
        forfait: begegnung['forfeit'].to_i,
        playoff:,
        referee1_string: begegnung['schiedsrichter'].presence,
        game_status: 'finalized',
        # Altspiele sind abgeschlossen – die Flags steuern u. a., ob das Spiel in
        # League#evaluate_table_results (Tabelle) und in der Scorerwertung zählt.
        started: true,
        ended: true,
        game_ended: true,
        legacy: true
      }.compact
    end

    # global_*_ereignis-Zeilen einer Begegnung → events-JSONB-Array im internen
    # Format (Referenz: fix_imported_game_format.rake). Tore-Spalten sind
    # KUMULATIV; das Team eines Tores wird über den Sprung im Spielstand
    # bestimmt (robuster als nur über die Trikotnummer).
    def build_events(ereignis_rows)
      prev_home = 0
      prev_guest = 0

      ereignis_rows.sort_by { |e| e['zeile'].to_i }.map do |e|
        home_goals = e['tore_team1'].to_i
        guest_goals = e['tore_team2'].to_i
        penalty = e['id_strafe'].to_i.positive?

        team = event_team(penalty:, row: e, home_goals:, guest_goals:, prev_home:, prev_guest:)

        event = {
          'id' => e['id_ereignis'],
          'period' => e['periode'],
          'time' => e['zeit'],
          'home_goals' => home_goals,
          'guest_goals' => guest_goals,
          'event_team' => team,
          'event_type' => penalty ? 'penalty' : 'goal'
        }

        number, assist = team == 'home' ? [e['nr_team1'], e['ass_team1']] : [e['nr_team2'], e['ass_team2']]
        number_key = team == 'home' ? 'home_number' : 'guest_number'
        assist_key = team == 'home' ? 'home_assist' : 'guest_assist'
        event[number_key] = number.to_i if number.to_i.positive?
        event[assist_key] = assist.to_i if assist.to_i.positive?

        if penalty
          event['penalty_id'] = Vocab::STRAFE_TO_PENALTY_ID[e['id_strafe'].to_i]
          event['penalty_code_id'] = e['id_strafcode'].to_i if e['id_strafcode'].to_i.positive?
        end

        prev_home = home_goals
        prev_guest = guest_goals
        event
      end
    end

    # global_*_mitspieler-Zeilen einer Begegnung → players-JSONB
    # ({ 'home' => [...], 'guest' => [...] }). player_id_map bildet die alte
    # globale id_spieler auf die neue Player-ID ab; ohne Map wird die Alt-ID
    # durchgereicht (PoC). Gastspieler ohne id_spieler behalten Name/Vorname.
    def build_players(mitspieler_rows, player_id_map: nil)
      result = { 'home' => [], 'guest' => [] }

      mitspieler_rows.each do |m|
        team = m['team'].to_i == 1 ? 'home' : 'guest'
        old_pid = m['id_spieler'].to_i
        player_id = if old_pid.zero?
                      nil
                    elsif player_id_map
                      player_id_map[old_pid]
                    else
                      old_pid
                    end

        result[team] << {
          'player_id' => player_id,
          'trikot_number' => m['trikotnr'].to_i,
          'goalkeeper' => to_bool(m['torwart']),
          'captain' => to_bool(m['kapitain']),
          'last_name' => m['name'],
          'first_name' => m['vorname']
        }.compact
      end

      result
    end

    # global_*_betreuer-Zeilen → { 'home' => {...}, 'guest' => {...} } im Format
    # der Live-Spalten home_team_coaches/guest_team_coaches: ein Hash mit Keys
    # "coachN_string"/"coachN_signed" (vgl. GamesController). Altdaten kennen nur
    # den vollen Namen (betreuer1..5) ohne Vor-/Nachname-Split und eine
    # Unterschrift nur für betreuer1.
    def build_coaches(betreuer_rows)
      result = { 'home' => {}, 'guest' => {} }
      betreuer_rows.each do |b|
        side = b['team'].to_i == 1 ? 'home' : 'guest'
        (1..5).each do |i|
          name = b["betreuer#{i}"]
          result[side]["coach#{i}_string"] = name if name.present?
        end
        result[side]['coach1_signed'] = true if to_bool(b['betreuer1_unterschrift'])
      end
      result
    end

    # global_*_spielbericht-Zeile → Felder auf games. Schiris bleiben bewusst
    # Freitext (referee1/2_string, keine Verknüpfung zu referees). Liefert {}
    # ohne Bericht, damit der Aufrufer bedenkenlos mergen kann.
    def spielbericht_attrs(spielbericht)
      return {} if spielbericht.blank?

      {
        referee1_string: spielbericht['schiedsrichter1'].presence,
        referee2_string: spielbericht['schiedsrichter2'].presence,
        referee1_signed: to_bool(spielbericht['unterschrift_schiri1']),
        referee2_signed: to_bool(spielbericht['unterschrift_schiri2']),
        home_captain_signed: to_bool(spielbericht['unterschrift_kapitain1']),
        guest_captain_signed: to_bool(spielbericht['unterschrift_kapitain2']),
        home_timeout_string: spielbericht['timeout1'].presence,
        guest_timeout_string: spielbericht['timeout2'].presence,
        record_comment: spielbericht['kommentar'].presence,
        protest: to_bool(spielbericht['protest']),
        overtime: to_bool(spielbericht['verlaengerung'])
      }.compact
    end

    # ── intern ────────────────────────────────────────────────────────────────
    def event_team(penalty:, row:, home_goals:, guest_goals:, prev_home:, prev_guest:)
      unless penalty
        return 'home' if home_goals > prev_home
        return 'guest' if guest_goals > prev_guest
      end
      # Strafe oder kein Spielstand-Sprung: Team über gesetzte Trikotnummer.
      row['nr_team1'].to_i.positive? ? 'home' : 'guest'
    end

    def to_bool(val)
      val.to_i == 1
    end
  end
end
