require 'test_helper'

# Beim Saisonwechsel werden die Spielberichte aller vergangenen Saisons
# geschlossen. Ein offen gebliebener Bericht blieb sonst dauerhaft bearbeitbar:
# Tore, Strafen und der Status stehen nur bei abgeschlossenem Bericht unter dem
# Vorbehalt von Admin und SBK, und der ausrichtende Verein darf den Bericht auch
# Jahre spaeter noch anfassen.
class PastSeasonReportCloserTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    setting = Setting.first
    setting.update!(seasons: {
                      '16' => { 'name' => '2024/2025' },
                      '17' => { 'name' => '2025/2026' },
                      '18' => { 'name' => '2026/2027' }
                    })

    @alte_liga = create(:league, season_id: '17')
    @aktuelle_liga = create(:league, season_id: '18')
  end

  test 'ein offener Bericht der Vorsaison wird geschlossen' do
    spiel = spiel_in(@alte_liga, status: 'aftergame')

    ergebnis = PastSeasonReportCloser.call

    assert_equal 1, ergebnis.games
    assert_equal 1, ergebnis.leagues
    assert_equal 'match_record_closed', spiel.reload.game_status
  end

  test 'die laufende Saison bleibt unberuehrt' do
    spiel = spiel_in(@aktuelle_liga, status: 'aftergame')

    assert_equal 0, PastSeasonReportCloser.call.games
    assert_equal 'aftergame', spiel.reload.game_status
  end

  # `NOT IN` ist fuer NULL nicht wahr, sondern unbekannt. Ein nie begonnener
  # Bericht traegt im Bestand genau das -- er waere als einziger offen geblieben.
  test 'ein Bericht ohne Status wird mitgeschlossen' do
    spiel = spiel_in(@alte_liga, status: nil)

    assert_equal 1, PastSeasonReportCloser.call.games
    assert_equal 'match_record_closed', spiel.reload.game_status
  end

  test 'ein finalisierter Bericht behaelt seinen Status' do
    spiel = spiel_in(@alte_liga, status: 'finalized')

    assert_equal 0, PastSeasonReportCloser.call.games
    assert_equal 'finalized', spiel.reload.game_status
  end

  # Der Zeitstempel beantwortet, wann die Beteiligten den Bericht eingereicht
  # haben. Ein Sammelabschluss Jahre spaeter ist keine Einreichung -- und ein
  # frisches Datum haette jeden alten Spieltag als eben erst abgeschlossen
  # ausgegeben, mit allem, was an dieser Spalte haengt.
  test 'der Einreichungszeitpunkt wird nicht erfunden' do
    spiel = spiel_in(@alte_liga, status: 'aftergame')

    PastSeasonReportCloser.call

    assert_nil spiel.reload.match_record_closed_at
  end

  test 'ein zweiter Lauf findet nichts mehr' do
    spiel_in(@alte_liga, status: 'aftergame')

    assert_equal 1, PastSeasonReportCloser.call.games
    assert_equal 0, PastSeasonReportCloser.call.games
  end

  # Der Sammelabschluss laeuft ueber update_all, der after_commit-Haken am Spiel
  # greift also nicht. Spielplan und Tabelle der Liga zeigen den Status.
  #
  # Geprueft werden die Loeschaufrufe und nicht der Cache-Inhalt: In der
  # Testumgebung ist der Store ein Null-Store, ein Lesen nach dem Schreiben
  # liefert dort immer nil und jede Aussage darueber waere wahr.
  test 'die Caches der betroffenen Liga werden geleert' do
    spiel_in(@alte_liga, status: 'aftergame')
    geloescht = []

    Rails.cache.stub(:delete, ->(key) { geloescht << key }) do
      PastSeasonReportCloser.call
    end

    assert_includes geloescht, "leagues/#{@alte_liga.id}/schedule"
    assert_includes geloescht, "leagues/#{@alte_liga.id}/table"
    assert_includes geloescht, "leagues/#{@alte_liga.id}/scorer"
    assert_not_includes geloescht, "leagues/#{@aktuelle_liga.id}/schedule"
  end

  # `leagues.season_id` ist eine Textspalte. Ein Vergleich in SQL verglich als
  # Text und liesse die einstelligen Saisons gegen eine zweistellige laufende
  # Saison ausgerechnet aus.
  test 'einstellige Saisons zaehlen als vergangen' do
    Setting.first.update!(seasons: { '9' => { 'name' => '2017/2018' }, '10' => { 'name' => '2018/2019' } })
    alte_saison = create(:league, season_id: '9')
    spiel = spiel_in(alte_saison, status: 'aftergame')

    assert_equal 1, PastSeasonReportCloser.call(current_season_id: 10).games
    assert_equal 'match_record_closed', spiel.reload.game_status
  end

  # Eine Liga, deren Saison in der Saisonliste gar nicht steht, bleibt liegen:
  # Was dort gemeint ist, weiss dieser Weg nicht.
  test 'eine Liga ohne bekannte Saison bleibt unangetastet' do
    fremde = create(:league, season_id: '99')
    spiel = spiel_in(fremde, status: 'aftergame')

    assert_equal 0, PastSeasonReportCloser.call.games
    assert_equal 'aftergame', spiel.reload.game_status
  end

  private

  def spiel_in(league, status:)
    game_day = create(:game_day, league: league, club: create(:club))
    Game.create!(
      game_day: game_day,
      home_team: create(:team, league: league),
      guest_team: create(:team, league: league),
      game_status: status,
      forfait: 0, overtime: false, legacy: false,
      events: [], players: { 'home' => [], 'guest' => [] }
    )
  end
end
