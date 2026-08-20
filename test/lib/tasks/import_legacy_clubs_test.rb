require 'test_helper'
require 'rake'

# Tests fuer import:clubs (lib/tasks/import_legacy_data.rake), begrenzt auf die
# Landesverbands-Zuordnung.
#
# Das Altsystem kennt den Landesverband nicht, es kennt nur den Spielbetrieb. Der
# Wert ist hier also abgeleitet. Seit die Zustaendigkeit daran haengt
# (Club#main_game_operation_id), darf der Import ihn an einem bestehenden Verein
# nicht mehr anfassen: Sonst zoege ein zweiter Lauf die gepflegte Zuordnung auf
# den Alt-Spielbetrieb zurueck.
#
# Die beiden HTTP-Helfer werden gestubbt; der Task laeuft sonst gegen den echten
# Altserver.
class ImportLegacyClubsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['import:clubs']
    create(:setting, current_season_id: '18')

    @gepflegt_sa = create(:state_association)
    @gepflegt_go = create(:game_operation, state_association_id: @gepflegt_sa.id)
    @alt_sa = create(:state_association)
    # Der Spielbetrieb, unter dem der Verein im Altsystem gefuehrt wird.
    @alt_go = create(:game_operation, state_association_id: @alt_sa.id)
  end

  # Die Helfer sind mit `def` im namespace-Block definiert, also private
  # Instanzmethoden auf Object; der Task laeuft am Top-Level-Objekt. Gestubbt wird
  # deshalb dort und nicht an der Klasse, sonst greift der Stub nicht und der Test
  # laeuft in eine echte HTTP-Verbindung zum Altserver.
  def run_import(nutzlast)
    @task.reenable
    main = TOPLEVEL_BINDING.receiver
    main.stub(:legacy_session, 'cookie') do
      main.stub(:legacy_fetch, nutzlast) do
        capture_io { @task.invoke }
      end
    end
  end

  def go_nutzlast(go_id, clubs)
    [{ 'id' => go_id, 'clubs' => clubs }]
  end

  # Der Fall, der die Umstellung ausgeloest hat, in der Gegenrichtung: Der ETV
  # Hamburg wird im Altsystem unter Niedersachsen gefuehrt, sein gepflegter
  # Landesverband ist Hamburg. Ein Importlauf darf ihn nicht zurueckziehen.
  test 'laesst den gepflegten Landesverband eines bestehenden Vereins unberuehrt' do
    club = create(:club, name: 'Alt', state_association_id: @gepflegt_sa.id)

    run_import(go_nutzlast(@alt_go.id, [{ 'id' => club.id, 'name' => 'Neu aus Altsystem',
                                          'long_name' => 'Neu e.V.', 'short_name' => 'NEU',
                                          'state' => 'de-ni' }]))

    club.reload
    assert_equal 'Neu aus Altsystem', club.name, 'die Stammdaten sollen weiter uebernommen werden'
    assert_equal @gepflegt_sa.id, club.state_association_id
    assert_equal @gepflegt_go.id, club.main_game_operation_id,
                 'die Zustaendigkeit darf nicht auf den Alt-Spielbetrieb zurueckfallen'
  end

  # Ein neuer Verein bekommt den Landesverband des Alt-Spielbetriebs, sonst waere
  # er fuer niemanden zustaendig.
  test 'setzt den Landesverband bei einem neuen Verein aus dem Spielbetrieb' do
    neue_id = Club.maximum(:id).to_i + 1000

    run_import(go_nutzlast(@alt_go.id, [{ 'id' => neue_id, 'name' => 'Frisch',
                                          'long_name' => 'Frisch e.V.', 'short_name' => 'FR',
                                          'state' => 'de-ni' }]))

    club = Club.find(neue_id)
    assert_equal @alt_sa.id, club.state_association_id
    assert_equal @alt_go.id, club.main_game_operation_id
  end

  # Ohne Landesverband am Spielbetrieb wird kein Wert geschrieben und gewarnt. Ein
  # nil waere nach der Umstellung nicht bloss eine Luecke, sondern der Verlust der
  # Zustaendigkeit.
  test 'warnt und schreibt nichts, wenn der Spielbetrieb keinen Landesverband hat' do
    go_ohne_lv = create(:game_operation, state_association_id: nil)
    neue_id = Club.maximum(:id).to_i + 2000

    _out, err = run_import(go_nutzlast(go_ohne_lv.id, [{ 'id' => neue_id, 'name' => 'Herrenlos',
                                                        'long_name' => 'Herrenlos e.V.',
                                                        'short_name' => 'HL', 'state' => 'de-ni' }]))

    assert_match(/keinen Landesverband/, err)
    assert_nil Club.find(neue_id).state_association_id
  end
end
