require 'test_helper'

module PlayerStats
  # Der naechtliche Lauf hinter der Spielerdaten-Rangliste (#465).
  class RefresherTest < ActiveSupport::TestCase
    setup do
      create(:setting, current_season_id: '18')
      @go = create(:game_operation)
      @league = create(:league, game_operation: @go, season_id: '18', league_class_id: 'rl')
      @club = create(:club, game_operation: @go)
      @gegner = create(:club)
      @heim = create(:team, league: @league, club: @club)
      @gast = create(:team, league: @league, club: @gegner)
      @spieler = create(:player)
      @game_day = create(:game_day, league: @league)
    end

    test 'zaehlt Einsaetze, Tore, Vorlagen und Strafminuten je Spieler und Team' do
      mitspieler = create(:player)
      ended_game(
        home_lineup: [lineup(7, @spieler), lineup(9, mitspieler)],
        events: [goal(7, assist: 9), goal(7), penalty(7, 'penalty_5')]
      )

      Refresher.new.run!

      eintrag = PlayerGameStat.find_by(player_id: @spieler.id)
      assert_equal 1, eintrag.games
      assert_equal 2, eintrag.goals
      assert_equal 0, eintrag.assists
      assert_equal 5, eintrag.penalty_minutes
      assert_equal @heim.id, eintrag.team_id
      assert_equal @club.id, eintrag.club_id
      assert_equal @league.id, eintrag.league_id
      assert_equal '18', eintrag.season_id
      assert_equal @go.id, eintrag.game_operation_id
      assert_equal 'rl', eintrag.league_class_id

      assert_equal 1, PlayerGameStat.find_by(player_id: mitspieler.id).assists
    end

    # Ein kampfloses Spiel ist kein Einsatz -- Game#evaluate_scorer liefert dafuer
    # bewusst nichts, und die Rangliste muss dieselbe Zahl zeigen wie das Spielerprofil.
    test 'kampflose und nicht beendete Spiele zaehlen nicht' do
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)], forfait: 1)
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)], ended: false)

      Refresher.new.run!

      assert_nil PlayerGameStat.find_by(player_id: @spieler.id)
    end

    # Zwei Saisons, zwei Ligen: Es entsteht je Liga eine Zeile, die Ansicht summiert
    # spaeter darueber.
    test 'schreibt je Liga eine Zeile, auch saisonuebergreifend' do
      alte_liga = create(:league, game_operation: @go, season_id: '17')
      altes_team = create(:team, league: alte_liga, club: @club)
      alter_tag = create(:game_day, league: alte_liga)
      create(:game, game_day: alter_tag, home_team: altes_team, guest_team: @gast, ended: true,
                    players: { 'home' => [lineup(7, @spieler)], 'guest' => [] }, events: [goal(7)])
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])

      Refresher.new.run!

      zeilen = PlayerGameStat.where(player_id: @spieler.id).order(:season_id)
      assert_equal %w[17 18], zeilen.map(&:season_id)
      assert_equal [1, 1], zeilen.map(&:games)
    end

    test 'ein zweiter Lauf erzeugt keine Dubletten und aendert nichts' do
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])
      Refresher.new.run!
      vorher = PlayerGameStat.order(:id).pluck(:player_id, :team_id, :games, :goals)

      Refresher.new.run!

      assert_equal 1, PlayerGameStat.count
      assert_equal vorher, PlayerGameStat.order(:id).pluck(:player_id, :team_id, :games, :goals)
    end

    # Der Grund fuer Loeschen-und-neu-Schreiben statt Aufaddieren: Eine Korrektur muss
    # auch nach unten wirken. Ein aufsummierender Lauf wuerde das Tor nie mehr los.
    test 'ein zurueckgenommenes Tor verschwindet beim naechsten Lauf' do
      spiel = ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7), goal(7)])
      Refresher.new.run!
      assert_equal 2, PlayerGameStat.find_by(player_id: @spieler.id).goals

      spiel.update!(events: [goal(7)])
      Refresher.new.run!

      assert_equal 1, PlayerGameStat.find_by(player_id: @spieler.id).goals
    end

    test 'Zeilen einer geloeschten Liga raeumt der volle Lauf weg' do
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])
      Refresher.new.run!
      assert_equal 1, PlayerGameStat.count

      PlayerGameStat.update_all(league_id: 999_999)
      Refresher.new.run!

      assert_equal 0, PlayerGameStat.where(league_id: 999_999).count
    end

    # Spielgemeinschaften bleiben unberuecksichtigt (Vorgabe aus #465): Der Einsatz
    # zaehlt fuer den Verein der Mannschaft, nicht fuer die beteiligten Vereine.
    test 'ein Einsatz fuer eine Spielgemeinschaft zaehlt nur beim Verein der Mannschaft' do
      partner = create(:club)
      @heim.update!(syndicate: true, syndicate_clubs: [partner.id])
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])

      Refresher.new.run!

      assert_equal [@club.id], PlayerGameStat.where(player_id: @spieler.id).pluck(:club_id)
    end

    test 'schreibt den Heimatverein in den Schnappschuss, ohne laufenden Heimatverein bleibt er leer' do
      mit_heimat = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
      ohne_heimat = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                             'valid_until' => '2020-06-30' }])

      Refresher.new.run!

      assert_equal @club.id, PlayerStatProfile.find(mit_heimat.id).home_club_id
      assert_equal @go.id, PlayerStatProfile.find(mit_heimat.id).home_game_operation_id
      assert_nil PlayerStatProfile.find(ohne_heimat.id).home_club_id
    end

    test 'ein Nachlauf fuer eine Saison laesst die uebrigen Ligen unberuehrt' do
      alte_liga = create(:league, game_operation: @go, season_id: '17')
      altes_team = create(:team, league: alte_liga, club: @club)
      create(:game, game_day: create(:game_day, league: alte_liga), home_team: altes_team,
                    guest_team: @gast, ended: true,
                    players: { 'home' => [lineup(7, @spieler)], 'guest' => [] }, events: [goal(7)])
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])
      Refresher.new.run!

      Refresher.new(season_id: '18').run!

      assert_equal %w[17 18], PlayerGameStat.order(:season_id).pluck(:season_id)
    end

    # Ein Spiel ohne aufloesbare Mannschaft ist genau der Fall, den der rescue je Spiel
    # abfaengt. Er darf dabei nicht spurlos verschwinden: Der Lauf ist unbeaufsichtigt
    # und endet auch mit uebersprungenen Spielen mit Exit 0.
    test 'uebersprungene Spiele werden gemeldet' do
      spiel = ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])
      spiel.update_column(:home_team_id, 999_999)

      messages = []
      ergebnis = nil
      Sentry.stub(:capture_message, ->(message, *) { messages << message }) do
        ergebnis = Refresher.new.run!
      end

      assert_equal 1, ergebnis[:skipped_games]
      assert_equal 1, messages.size
      assert_includes messages.first, 'uebersprungen'
    end

    test 'ein Lauf ohne uebersprungene Spiele meldet nichts' do
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])

      messages = []
      Sentry.stub(:capture_message, ->(message, *) { messages << message }) do
        Refresher.new.run!
      end

      assert_empty messages
    end

    # Die Drosselung haengt an Rails.cache. Im Test-Env ist das ein :null_store, in dem
    # jedes write durchgeht -- ohne echten Store pruefte der Test sie gar nicht.
    test 'die Meldung ueber uebersprungene Spiele wiederholt sich nicht bei jedem Lauf' do
      spiel = ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])
      spiel.update_column(:home_team_id, 999_999)

      messages = []
      with_real_cache do
        Sentry.stub(:capture_message, ->(message, *) { messages << message }) do
          2.times { Refresher.new.run! }
        end
      end

      assert_equal 1, messages.size
    end

    test 'DRY_RUN schreibt nichts' do
      ended_game(home_lineup: [lineup(7, @spieler)], events: [goal(7)])

      ergebnis = Refresher.new(dry_run: true).run!

      assert_equal 1, ergebnis[:rows]
      assert_equal 0, PlayerGameStat.count
      assert_equal 0, PlayerStatProfile.count
    end

    private

    def ended_game(home_lineup: [], guest_lineup: [], events: [], forfait: 0, ended: true)
      create(:game, game_day: @game_day, home_team: @heim, guest_team: @gast,
                    ended:, forfait:, events:,
                    players: { 'home' => home_lineup, 'guest' => guest_lineup })
    end

    def lineup(number, player)
      { 'trikot_number' => number, 'player_id' => player.id,
        'player_firstname' => player.first_name, 'player_name' => player.last_name }
    end

    def goal(number, assist: nil)
      event = { 'home_number' => number, 'home_goals' => 1, 'guest_goals' => 0 }
      event['home_assist'] = assist if assist
      event
    end

    # penalty_mapping am Ereignis, damit der Test nicht am Strafenkatalog haengt --
    # genau so liest Game#penalty_mapping eingefrorene Altdaten.
    def penalty(number, mapping)
      { 'penalty_id' => 1, 'penalty_mapping' => mapping, 'home_number' => number }
    end
  end
end
