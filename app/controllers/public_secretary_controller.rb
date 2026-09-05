class PublicSecretaryController < ApplicationController
  skip_before_action :authenticate_user

  # GET /api/v2/public/secretary?token=XXX
  # Returns game day info + license lists for all games
  def show
    raw_token = params[:token]
    return render json: { message: 'Kein Token angegeben.' }, status: :bad_request unless raw_token.present?

    link = GameDaySecretaryLink.find_by_token(raw_token)
    return render json: { message: 'Dieser Link ist ungültig oder abgelaufen.' }, status: :gone if link.nil?

    game_days = link.game_days
                    .includes(:arena, league: :game_operation)
                    .to_a
                    .sort_by { |gd| [gd.date.to_s, gd.league&.name.to_s] }

    # Wurden alle Spieltage des Links gelöscht, gibt es nichts mehr zu führen.
    # Ohne diesen Zweig käme eine 200 mit game_day: null zurück und die Seite
    # liefe in einen Fehler, statt den Link als ungültig zu melden.
    return render json: { message: 'Dieser Link ist ungültig oder abgelaufen.' }, status: :gone if game_days.empty?

    games = games_for(game_days)

    render json: {
      # Einzelner Spieltag für ältere Frontends, die game_days noch nicht kennen.
      game_day: game_days.first && game_day_json(game_days.first),
      game_days: game_days.map { |gd| game_day_json(gd) },
      games: games.map { |g| game_json(g) },
      license_lists: build_license_lists(games),
      expires_at: link.expires_at.iso8601,
      created_by: link.created_by&.fullname
    }
  end

  private

  # Spiele aller Spieltage des Links in der Reihenfolge, in der sie in der Halle
  # laufen. start_time ist Text (HH:MM); Spiele ohne Zeit hängen sich hinten an.
  #
  # game_day und dessen league werden mitgeladen: Sortierung und Ausgabe lesen
  # beide, und das Sekretariat lädt diese Seite am Tisch immer wieder neu.
  # Die id im Sortierschlüssel hält die Reihenfolge stabil – sort_by ist es
  # nicht, und zwei Spiele derselben Anwurfzeit sprängen sonst zwischen zwei
  # Abrufen hin und her.
  def games_for(game_days)
    Game.where(game_day_id: game_days.map(&:id))
        .includes(:home_team, :guest_team, game_day: :league)
        .to_a
        .sort_by { |g| [g.game_day&.date.to_s, g.start_time.presence || '99:99', g.id] }
  end

  def game_day_json(game_day)
    {
      id: game_day.id,
      date: game_day.date,
      league: game_day.league&.name,
      # league_id + game_operation_slug ermöglichen im Frontend den direkten Link
      # zur Spielseite: /:association/:leagueId/spiel/:matchId. Gleiches Muster
      # wie bei den Schiri-Spieltagen.
      league_id: game_day.league&.id,
      arena: game_day.arena&.name,
      game_operation_slug: game_day.league&.game_operation&.slug
    }
  end

  def game_json(game)
    {
      id: game.id,
      game_number: game.game_number,
      start_time: game.start_time,
      home_team: game.home_team&.name,
      guest_team: game.guest_team&.name,
      game_status: game.game_status,
      # Bei mehreren Ligen in derselben Halle muss am Spiel erkennbar sein,
      # zu welchem Spieltag es gehört.
      game_day_id: game.game_day_id,
      league: game.game_day&.league&.name
    }
  end

  def build_license_lists(games)
    contexts = team_contexts(games)
    teams = Team.where(id: contexts.keys).index_by(&:id)

    ordered_team_ids(contexts, teams).each_with_object({}) do |team_id, hash|
      team = teams[team_id]
      next unless team

      # Vor dem Aufbau sortieren statt danach: Der Eintrag traegt nur den
      # zusammengesetzten Anzeigenamen, eine Sortierung darueber liefe nach
      # Vornamen.
      players = Player.find_by_team_id(team_id).sort_by(&:license_list_sort_key)
      entries = players.filter_map do |player|
        license = player.extr_license
        next unless license

        # to_s im Sortierschlüssel: ein Historieneintrag ohne created_at ließ
        # max_by mit „comparison of NilClass with String failed" auffliegen. Seit
        # ein Link mehrere Ligen umfasst, risse ein einziger solcher Datensatz
        # die Lizenzlisten aller Mannschaften der Halle mit.
        last_status = license['history']&.max_by { |h| h['created_at'].to_s }
        next unless last_status

        last_status_id = last_status['license_status_id'].to_i
        next unless [License::APPROVED, License::REQUESTED].include?(last_status_id)

        # to_i wie zwei Zeilen darüber: als String gespeicherte Status ließen das
        # Erteilungsdatum sonst leer – genau die Spalte, an der das Sekretariat
        # die Spielberechtigung abliest.
        approved_entry = license['history']&.select { |h| h['license_status_id'].to_i == License::APPROVED }&.last

        {
          name: "#{player.first_name} #{player.last_name}",
          birthdate: player.birthdate,
          license_status: License::NAMES[last_status_id],
          approved_at: approved_entry&.dig('created_at'),
          valid_until: license['valid_until']
        }
      end

      league  = contexts[team_id][:league]
      leagues = contexts[team_id][:leagues].presence || [league].compact
      hash[team_id.to_s] = {
        team_name: team.name,
        # Die Liga des Spieltags, in dem die Mannschaft an diesem Tag antritt –
        # nicht Team#league_id. Bei einem Pokalspiel in derselben Halle wäre das
        # ihre Hauptliga und damit die falsche Überschrift.
        #
        # `league_id`/`league_name` bleiben die FRÜHESTE Begegnung des Tages und
        # damit abwärtskompatibel. Maßgeblich für die Gruppierung ist aber
        # `leagues`: Tritt eine Mannschaft am selben Tag in derselben Halle in
        # zwei Ligen an (vormittags Liga, nachmittags Pokal), gehört ihre
        # Lizenzliste unter BEIDE Überschriften. Mit nur einer Liga fehlte sie
        # unter der zweiten vollständig, und das Sekretariat des zweiten Spiels
        # suchte sie dort vergeblich – in der flachen Liste vorher war sie
        # wenigstens auffindbar.
        league_id: league&.id,
        league_name: league&.name,
        leagues: leagues.map { |l| { id: l.id, name: l.name } },
        players: entries
      }
    end
  end

  # Mannschaft -> { Liga, Spieltagsdatum, alle Ligen } aus den Spielen des Links.
  # `games` kommt bereits nach Datum und Anwurf sortiert herein, die erste
  # Begegnung gibt also `:league` vor (Reihenfolge und Abwärtskompatibilität).
  #
  # `:leagues` sammelt darüber hinaus JEDE Liga, in der die Mannschaft an diesem
  # Link beteiligt ist. Ohne diese Sammlung bekäme eine Mannschaft, die
  # vormittags in der Liga und nachmittags im Pokal antritt, nur die frühere,
  # und unter der zweiten Überschrift fehlte ihre Lizenzliste ganz.
  def team_contexts(games)
    games.each_with_object({}) do |game, hash|
      game_day = game.game_day
      next unless game_day

      [game.home_team_id, game.guest_team_id].compact.each do |team_id|
        ctx = (hash[team_id] ||= { league: game_day.league, date: game_day.date.to_s, leagues: [] })
        ctx[:leagues] << game_day.league if game_day.league && ctx[:leagues].exclude?(game_day.league)
      end
    end
  end

  # Dieselbe Ordnung wie die Spieltage des Links: Datum, dann Liganame. Der
  # Mannschaftsname und die id hängen als Schlussglieder an, damit die Antwort
  # zwischen zwei Abrufen gleich bleibt.
  #
  # Ein Verlass ist das im Browser trotzdem nicht: `license_lists` ist ein
  # Objekt mit den Mannschafts-ids als Schlüssel, und JavaScript zieht
  # zahlenartige Schlüssel unabhängig von der Einfügereihenfolge nach vorn. Die
  # Ansicht ordnet deshalb selbst, anhand von league_id. Die Reihenfolge hier
  # ist für alle anderen Leser der Antwort.
  def ordered_team_ids(contexts, teams)
    contexts.keys.sort_by do |team_id|
      [contexts[team_id][:date], contexts[team_id][:league]&.name.to_s,
       teams[team_id]&.name.to_s, team_id]
    end
  end
end
