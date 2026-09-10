require 'test_helper'
require 'rake'
require 'tempfile'

# Tests für lib/tasks/streaming.rake.
#
# Der Import trägt Geheimnisse ein: Ein falsch zugeordneter Schlüssel sendet das
# Spiel des einen Vereins auf den Kanal des anderen. Deshalb ordnet er nur zu,
# was eindeutig ist, und meldet den Rest, statt zu raten.
class StreamingTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')
    @club = create(:club)
    @liga = create(:league, name: '1. FBL Herren')
  end

  test 'traegt den Schluessel an der Mannschaft der laufenden Saison ein' do
    team = create(:team, league: @liga, club: @club, name: 'MFBC Leipzig')

    ausgabe, = import(['1. FBL Herren,MFBC Leipzig,m9p7-bvy0-87jr-0w8m-54ch'])

    assert_equal 'm9p7-bvy0-87jr-0w8m-54ch', team.reload.stream_key
    assert_match(/1 Schlüssel gesetzt/, ausgabe)
  end

  test 'Probelauf traegt nichts ein' do
    team = create(:team, league: @liga, club: @club, name: 'MFBC Leipzig')

    ausgabe, = import(['1. FBL Herren,MFBC Leipzig,m9p7-bvy0-87jr-0w8m-54ch'], 'DRY_RUN' => '1')

    assert_nil team.reload.stream_key
    assert_match(/PROBELAUF/, ausgabe)
  end

  test 'meldet eine Mannschaft, die es in der laufenden Saison nicht gibt' do
    create(:team, league: create(:league, :previous_season), club: @club, name: 'MFBC Leipzig')

    ausgabe, = import(['1. FBL Herren,MFBC Leipzig,m9p7-bvy0-87jr-0w8m-54ch'])

    assert_match(/nicht zugeordnet/, ausgabe)
    assert_match(/keine Mannschaft der laufenden Saison/, ausgabe)
  end

  # Der gefährlichste Fall: Derselbe Mannschaftsname in zwei Ligen. Wer hier
  # rät, sendet die Damen auf den Kanal der Herren.
  test 'schaerft ueber die Ligaspalte, wenn ein Name in mehreren Ligen vorkommt' do
    damen = create(:league, name: '1. FBL Damen')
    team_h = create(:team, league: @liga, club: @club, name: 'Floor Fighters Chemnitz')
    team_d = create(:team, league: damen, club: @club, name: 'Floor Fighters Chemnitz')

    import(['1. FBL Damen,Floor Fighters Chemnitz,yy15-6tma-z2e3-zxy4-6z2f'])

    assert_equal 'yy15-6tma-z2e3-zxy4-6z2f', team_d.reload.stream_key
    assert_nil team_h.reload.stream_key, 'die gleichnamige Mannschaft der anderen Liga darf nichts bekommen'
  end

  test 'traegt nichts ein, wenn der Name mehrdeutig bleibt' do
    zweite = create(:league, name: 'Andere Liga')
    team_a = create(:team, league: @liga, club: @club, name: 'Floor Fighters Chemnitz')
    team_b = create(:team, league: zweite, club: @club, name: 'Floor Fighters Chemnitz')

    ausgabe, = import(['Schreibweise von woanders,Floor Fighters Chemnitz,yy15-6tma-z2e3-zxy4-6z2f'])

    assert_nil team_a.reload.stream_key
    assert_nil team_b.reload.stream_key
    assert_match(/2 Mannschaften passen/, ausgabe)
  end

  test 'ein unveraenderter Schluessel wird nicht erneut geschrieben' do
    create(:team, league: @liga, club: @club, name: 'MFBC Leipzig', stream_key: 'm9p7-bvy0-87jr-0w8m-54ch')

    ausgabe, = import(['1. FBL Herren,MFBC Leipzig,m9p7-bvy0-87jr-0w8m-54ch'])

    assert_match(/0 Schlüssel gesetzt, 1 unverändert/, ausgabe)
  end

  # Ohne Zugang darf der Watchdog nicht mit Fehlercode enden: Auf Staging und in
  # der Entwicklung ist das der Normalzustand, und ein Cronjob, der alle fünf
  # Minuten einen Fehler meldet, wird irgendwann abgeschaltet -- auch auf Prod.
  test 'der Watchdog meldet den fehlenden Zugang und endet ohne Fehler' do
    vorher = YoutubeLiveApi::ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
    YoutubeLiveApi::ENV_KEYS.each { |key| ENV.delete(key) }

    ausgabe, status = run_task('streaming:watchdog')

    assert_equal 0, status
    assert_match(/nicht eingerichtet/, ausgabe)
  ensure
    vorher.each { |key, wert| wert.nil? ? ENV.delete(key) : ENV[key] = wert }
  end

  # Ein deutsches Excel exportiert mit Semikolon. Mit fest verdrahtetem Komma
  # wäre JEDE Spalte nil, jede Zeile würde still übersprungen, und die Ausgabe
  # lautete "0 Schlüssel gesetzt, 0 unverändert" -- von einem echten "alles schon
  # aktuell" nicht zu unterscheiden. Für einen Task, der Geheimnisse einträgt,
  # ist das die schlechtestmögliche Rückmeldung.
  test 'liest auch eine mit Semikolon getrennte Datei' do
    team = create(:team, league: @liga, club: @club, name: 'MFBC Leipzig')

    ausgabe, = import_roh("liga;mannschaft;streamschluessel\n1. FBL Herren;MFBC Leipzig;m9p7-bvy0")

    assert_equal 'm9p7-bvy0', team.reload.stream_key
    assert_match(/1 Schlüssel gesetzt/, ausgabe)
  end

  test 'bricht bei fehlender Pflichtspalte ab, statt still nichts zu tun' do
    ausgabe, status = import_roh("liga,verein,schluessel\n1. FBL Herren,MFBC Leipzig,abcd")

    assert_equal 1, status
    assert_match(/Fehlende Spalte/, ausgabe)
  end

  # Ein vertippter Mannschaftsname leitet sonst den Stream eines Vereins auf den
  # Kanal eines anderen -- das gehört in die Prüfliste, nicht als Wort in den
  # Fließtext.
  test 'ersetzt einen vorhandenen Schluessel nicht stillschweigend' do
    team = create(:team, league: @liga, club: @club, name: 'MFBC Leipzig',
                         stream_key: 'alt-schluessel')

    ausgabe, status = import(['1. FBL Herren,MFBC Leipzig,neu-schluessel'])

    assert_equal 'alt-schluessel', team.reload.stream_key
    assert_equal 1, status
    assert_match(/trägt bereits einen anderen Schlüssel/, ausgabe)
  end

  test 'vergibt denselben Schluessel nicht an zwei Mannschaften' do
    create(:team, league: @liga, club: @club, name: 'Erste', stream_key: 'abcd-efgh')
    zweite = create(:team, league: @liga, club: create(:club), name: 'Zweite')

    ausgabe, status = import(['1. FBL Herren,Zweite,abcd-efgh'])

    assert_nil zweite.reload.stream_key
    assert_equal 1, status
    assert_match(/hängt schon an Mannschaft/, ausgabe)
  end

  # Jede offene Zeile ist eine Mannschaft ohne Schlüssel -- also eine
  # Übertragung, die der Wächter später keinem Spiel zuordnen kann.
  test 'endet mit Fehlercode, wenn Zeilen offen bleiben' do
    _, status = import(['1. FBL Herren,Unbekannte Mannschaft,abcd'])

    assert_equal 1, status
  end

  test 'der Probelauf endet trotz offener Zeilen ohne Fehlercode' do
    _, status = import(['1. FBL Herren,Unbekannte Mannschaft,abcd'], 'DRY_RUN' => '1')

    assert_equal 0, status
  end

  test 'zaehlt Zeilen ohne Angaben getrennt' do
    create(:team, league: @liga, club: @club, name: 'MFBC Leipzig')

    ausgabe, = import(['1. FBL Herren,MFBC Leipzig,abcd', ',,', '1. FBL Herren,,'])

    assert_match(/2 Zeile\(n\) ohne Angaben/, ausgabe)
  end

  private

  def import_roh(inhalt, env = {})
    datei = Tempfile.new(['keys', '.csv'])
    datei.write(inhalt)
    datei.flush
    run_task('streaming:import_keys', env.merge('CSV' => datei.path))
  ensure
    datei.close!
  end

  def import(zeilen, env = {})
    datei = Tempfile.new(['keys', '.csv'])
    datei.write((['liga,mannschaft,streamschluessel'] + zeilen).join("\n"))
    datei.flush
    run_task('streaming:import_keys', env.merge('CSV' => datei.path))
  ensure
    datei.close!
  end

  def run_task(name, env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task = Rake::Task[name]
    task.reenable
    status = 0
    out, err = capture_io do
      task.invoke
    rescue SystemExit => e
      status = e.status
    end
    [out + err, status]
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end
end
