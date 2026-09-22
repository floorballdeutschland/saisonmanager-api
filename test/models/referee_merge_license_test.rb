require 'test_helper'

# Was eine Zusammenlegung vom Zweitprofil mitnehmen muss (api#742).
#
# Der Fall aus der Praxis (20.09.2026): Eine Schiedsrichterin heiratet, der
# Kursimport erkennt den neuen Namen nicht wieder und legt ein zweites Profil mit
# neuer Lizenznummer an. Die frische Kurslizenz steht damit am ZWEITprofil,
# waehrend der Master seine alte, abgelaufene behaelt -- die alte Blank-Regel
# ("nur uebernehmen, wenn das Master-Feld leer ist") liess sie dort liegen, und
# nach der Zusammenlegung stand die Person ohne gueltige Lizenz da.
class RefereeMergeLicenseTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @admin = create(:user, :admin)
  end

  def course_result(referee:, stufe: 'L3', status: 'applied')
    import = RefereeCourseImport.create!(
      uploaded_by_user: @admin, filename: 'kurs.csv', total_rows: 0, status: 'in_review'
    )
    RefereeCourseResult.create!(
      referee_course_import: import, referee: referee, status: status,
      match_type: 'new_entry', match_field_count: 0,
      lizenzstufe: stufe, gueltigkeit: Date.new(2027, 9, 30),
      csv_vorname: 'Michaela', csv_nachname: 'Erber-Dachselt'
    )
  end

  test 'die spaetere Lizenz der Dublette gewinnt gegen die aeltere des Masters' do
    master    = create(:referee, lizenzstufe: 'L2', gueltigkeit: Date.new(2024, 9, 30))
    secondary = create(:referee, lizenzstufe: 'L3', gueltigkeit: Date.new(2027, 9, 30))

    secondary.merge_into!(master)

    master.reload
    assert_equal 'L3', master.lizenzstufe
    assert_equal Date.new(2027, 9, 30), master.gueltigkeit
  end

  test 'die aeltere Lizenz der Dublette laesst den Master unangetastet' do
    master    = create(:referee, lizenzstufe: 'L1', gueltigkeit: Date.new(2028, 9, 30))
    secondary = create(:referee, lizenzstufe: 'L3', gueltigkeit: Date.new(2027, 9, 30))

    secondary.merge_into!(master)

    master.reload
    assert_equal 'L1', master.lizenzstufe
    assert_equal Date.new(2028, 9, 30), master.gueltigkeit
  end

  test 'eine Gueltigkeit ohne Stufe verlaengert die Lizenz des Masters NICHT' do
    # Sonst wuerde aus einer abgelaufenen L2 eine gueltige L2 auf einem Datum, das
    # nie fuer diese Stufe erteilt wurde -- die Person waere wieder ansetzbar.
    master    = create(:referee, lizenzstufe: 'L2', gueltigkeit: Date.new(2024, 9, 30))
    secondary = create(:referee, lizenzstufe: nil, gueltigkeit: Date.new(2027, 9, 30))

    secondary.merge_into!(master)

    master.reload
    assert_equal 'L2', master.lizenzstufe
    assert_equal Date.new(2024, 9, 30), master.gueltigkeit
  end

  test 'ein Master ganz ohne Lizenz nimmt auch eine stufenlose Gueltigkeit an' do
    master    = create(:referee, lizenzstufe: nil, gueltigkeit: nil)
    secondary = create(:referee, lizenzstufe: nil, gueltigkeit: Date.new(2027, 9, 30))

    secondary.merge_into!(master)

    assert_equal Date.new(2027, 9, 30), master.reload.gueltigkeit
  end

  test 'eine spaetere, aber niedrigere Stufe wird uebernommen und protokolliert' do
    RefereeLicenseLevel.create!(name: 'A', position: 1, validity_years: 4)
    RefereeLicenseLevel.create!(name: 'G', position: 4, validity_years: 2)
    RefereeCourseResultApplier.reset_license_level_positions_cache!
    master    = create(:referee, lizenzstufe: 'A', gueltigkeit: Date.new(2027, 7, 31))
    secondary = create(:referee, lizenzstufe: 'G', gueltigkeit: Date.new(2028, 9, 30))
    meldungen = []
    Rails.logger.stub(:warn, ->(m) { meldungen << m }) do
      secondary.merge_into!(master)
    end

    assert_equal 'G', master.reload.lizenzstufe
    assert(meldungen.any? { |m| m.include?('Lizenz-Downgrade') }, meldungen.inspect)
  ensure
    RefereeCourseResultApplier.reset_license_level_positions_cache!
  end

  test 'die Lizenznummer des Masters bleibt, auch wenn seine Lizenz getauscht wird' do
    master    = create(:referee, lizenznummer: 7175, lizenzstufe: 'L2', gueltigkeit: Date.new(2024, 9, 30))
    secondary = create(:referee, lizenznummer: 8784, lizenzstufe: 'L3', gueltigkeit: Date.new(2027, 9, 30))

    secondary.merge_into!(master)

    assert_equal 7175, master.reload.lizenznummer
    assert_equal 'L3', master.lizenzstufe
  end

  test 'Kursergebnisse haengen nach der Zusammenlegung am Master' do
    master    = create(:referee)
    secondary = create(:referee)
    angewendet = course_result(referee: secondary)
    offen      = course_result(referee: secondary, stufe: nil, status: 'pending_review')

    secondary.merge_into!(master)

    assert_equal master.id, angewendet.reload.referee_id
    assert_equal master.id, offen.reload.referee_id
  end

  test 'Rueckmeldungen und Spieltagsbestaetigungen wandern mit' do
    master    = create(:referee)
    secondary = create(:referee)
    feedback  = create(:referee_feedback, referee1_id: secondary.id)
    game_day  = create(:game_day)
    bestaetigung = GameDayRefereeConfirmation.create!(game_day: game_day, referee: secondary, confirmed_at: Time.current)

    secondary.merge_into!(master)

    assert_equal master.id, feedback.reload.referee1_id
    assert_equal master.id, bestaetigung.reload.referee_id
  end

  test 'Spieltagsbestaetigung faellt weg, wenn der Master zum selben Spieltag schon eine hat' do
    master    = create(:referee)
    secondary = create(:referee)
    game_day  = create(:game_day)
    GameDayRefereeConfirmation.create!(game_day: game_day, referee: master, confirmed_at: Time.current)
    doppelt = GameDayRefereeConfirmation.create!(game_day: game_day, referee: secondary, confirmed_at: Time.current)

    secondary.merge_into!(master)

    assert_nil GameDayRefereeConfirmation.find_by(id: doppelt.id)
    assert_equal 1, GameDayRefereeConfirmation.where(game_day_id: game_day.id).count
  end

  test 'Ansetzungen wandern mit, eine mit beiden Profilen bleibt unveraendert' do
    master    = create(:referee)
    secondary = create(:referee)
    normal = RefereeAssignment.create!(game: create(:game), referee1_id: secondary.id)
    beide  = RefereeAssignment.create!(game: create(:game), referee1_id: master.id, referee2_id: secondary.id)

    secondary.merge_into!(master)

    assert_equal master.id, normal.reload.referee1_id
    assert_equal secondary.id, beide.reload.referee2_id
  end

  test 'eine offene Kurszeile bekommt den Stammdaten-Schnappschuss des Masters' do
    master    = create(:referee, vorname: 'Michaela', nachname: 'Erber-Dachselt',
                                 geburtsdatum: Date.new(1990, 5, 4), club_id: 203)
    secondary = create(:referee)
    offen = course_result(referee: secondary, stufe: nil, status: 'pending_review')
    offen.update!(master_vorname_final: 'Michaela', master_nachname_final: 'Erber-Dachselt',
                  master_geburtsdatum_final: nil, master_club_id_final: nil)

    secondary.merge_into!(master)

    offen.reload
    assert_equal master.id, offen.referee_id
    assert_equal Date.new(1990, 5, 4), offen.master_geburtsdatum_final
    assert_equal 203, offen.master_club_id_final
  end

  test 'eine angewendete Kurszeile behaelt ihren Schnappschuss' do
    master    = create(:referee, geburtsdatum: Date.new(1990, 5, 4))
    secondary = create(:referee)
    angewendet = course_result(referee: secondary)
    angewendet.update!(master_geburtsdatum_final: nil)

    secondary.merge_into!(master)

    assert_equal master.id, angewendet.reload.referee_id
    assert_nil angewendet.master_geburtsdatum_final
  end

  test 'eine Rueckmeldung mit beiden Profilen bleibt unveraendert' do
    master    = create(:referee)
    secondary = create(:referee)
    beide = create(:referee_feedback, referee1_id: master.id, referee2_id: secondary.id)

    secondary.merge_into!(master)

    assert_equal secondary.id, beide.reload.referee2_id
  end

  test 'der Coach wandert nicht auf ein Spiel, in dem der Master schon pfeift' do
    master    = create(:referee)
    secondary = create(:referee)
    eigenes = RefereeAssignment.create!(game: create(:game), referee1_id: master.id, coach_id: secondary.id)
    fremdes = RefereeAssignment.create!(game: create(:game), coach_id: secondary.id)

    secondary.merge_into!(master)

    assert_equal secondary.id, eigenes.reload.coach_id
    assert_equal master.id, fremdes.reload.coach_id
  end

  test 'von zwei Spieltagsbestaetigungen bleibt die mit ausgefuellter Checkliste' do
    master    = create(:referee)
    secondary = create(:referee)
    game_day  = create(:game_day)
    leer = GameDayRefereeConfirmation.create!(game_day: game_day, referee: master,
                                              confirmed_at: Time.current, checklist_answers: [])
    gefuellt = GameDayRefereeConfirmation.create!(game_day: game_day, referee: secondary,
                                                  confirmed_at: Time.current,
                                                  checklist_answers: [{ 'frage' => 'Halle', 'antwort' => 'ja' }])

    secondary.merge_into!(master)

    assert_nil GameDayRefereeConfirmation.find_by(id: leer.id)
    assert_equal master.id, gefuellt.reload.referee_id
    assert_equal 1, gefuellt.checklist_answers.size
  end
end
