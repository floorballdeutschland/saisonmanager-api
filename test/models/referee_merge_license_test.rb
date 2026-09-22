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

  test 'Stufe und Gueltigkeit wandern nur gemeinsam' do
    # Ohne Stufe am Zweitprofil bleibt die des Masters stehen, statt geleert zu
    # werden -- eine Gueltigkeit ohne Stufe waere keine Lizenz.
    master    = create(:referee, lizenzstufe: 'L2', gueltigkeit: Date.new(2024, 9, 30))
    secondary = create(:referee, lizenzstufe: nil, gueltigkeit: Date.new(2027, 9, 30))

    secondary.merge_into!(master)

    master.reload
    assert_equal 'L2', master.lizenzstufe
    assert_equal Date.new(2027, 9, 30), master.gueltigkeit
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
end
