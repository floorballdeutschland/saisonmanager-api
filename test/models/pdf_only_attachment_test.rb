require 'test_helper'

# Spieldokumente nehmen nur noch PDF an (PdfOnlyAttachment). Vorher
# hochgeladene Fotos müssen gültig bleiben.
class PdfOnlyAttachmentTest < ActiveSupport::TestCase
  PNG_BYTES = "\x89PNG\r\n\x1a\n0000IHDR".b

  setup do
    create(:setting)
    sa = create(:state_association)
    league = create(:league, game_operation: create(:game_operation, state_association_id: sa.id))
    club = create(:club, state_association_id: sa.id)
    game_day = GameDay.create!(league: league, arena: create(:arena), club: club, number: 1, date: '2026-01-10')
    @game = Game.create!(game_day: game_day, home_team: create(:team, league: league, club: club),
                         guest_team: create(:team, league: league, club: club),
                         forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })
  end

  test 'PDF ist gültig' do
    assert_predicate scan_with(io: StringIO.new('%PDF-1.7 rest'), content_type: 'application/pdf'), :valid?
  end

  test 'PDF-Kennung nach Vorspann ist gültig' do
    assert_predicate scan_with(io: StringIO.new("\n\n%PDF-1.4"), content_type: 'application/pdf'), :valid?
  end

  test 'Foto ist ungültig' do
    scan = scan_with(io: StringIO.new(PNG_BYTES), content_type: 'image/png', filename: 'foto.png')

    assert_not scan.valid?
    assert_equal ['Nur PDF-Dateien bis 5 MB sind zulässig, Fotos werden nicht angenommen.'],
                 scan.errors.full_messages
  end

  # Zu groß und falsches Format sagen dasselbe: was zulässig ist.
  test 'zu großes PDF nennt dieselbe Meldung' do
    io = StringIO.new("%PDF-1.7 #{'x' * GameScan::MAX_FILE_SIZE}")
    scan = scan_with(io: io, content_type: 'application/pdf')

    assert_not scan.valid?
    assert_equal [GameScan.pdf_only_message(GameScan::MAX_FILE_SIZE)], scan.errors.full_messages
  end

  test 'Foto, das zugleich zu groß ist, meldet nur einmal' do
    io = StringIO.new(PNG_BYTES + ('x' * GameScan::MAX_FILE_SIZE))
    scan = scan_with(io: io, content_type: 'image/png', filename: 'foto.png')

    assert_not scan.valid?
    assert_equal 1, scan.errors.count
  end

  test 'Foto mit PDF-Typ im Kopf ist ungültig' do
    assert_not scan_with(io: StringIO.new(PNG_BYTES), content_type: 'application/pdf').valid?
  end

  # Ohne Magic Bytes bleibt der angegebene Typ stehen, hier greift nur die
  # Kennung im Dateikopf.
  test 'Datei ohne PDF-Kennung mit PDF-Typ ist ungültig' do
    assert_not scan_with(io: StringIO.new('nur ein Text'), content_type: 'application/pdf').valid?
  end

  test 'die Prüfung lässt den Dateizeiger am Anfang' do
    io = StringIO.new('%PDF-1.4')
    scan_with(io: io, content_type: 'application/pdf').valid?

    assert_equal 0, io.pos
  end

  # Ein vor der Umstellung hochgeladenes Foto: angehängt und gespeichert ohne
  # Validierung, dann aus anderem Grund erneut gespeichert.
  test 'altes Foto bleibt beim erneuten Speichern gültig' do
    scan = scan_with(io: StringIO.new(PNG_BYTES), content_type: 'image/png', filename: 'foto.png')
    scan.save!(validate: false)
    scan = GameScan.find(scan.id)

    scan.expires_at = 2.months.from_now
    assert_predicate scan, :valid?
  end

  test 'Berichtsformular als Foto ist ungültig' do
    report = GameRefereeReport.new(game: @game, uploaded_by: create(:user, :admin))
    report.file.attach(io: StringIO.new(PNG_BYTES), filename: 'formular.jpg', content_type: 'image/jpeg')

    assert_not report.valid?
    assert_equal [GameRefereeReport.pdf_only_message(GameRefereeReport::MAX_FILE_SIZE)],
                 report.errors.full_messages
  end

  private

  def scan_with(io:, content_type:, filename: 'bogen.pdf')
    scan = GameScan.new(game: @game, expires_at: 12.months.from_now)
    scan.scan_file.attach(io: io, filename: filename, content_type: content_type)
    scan
  end
end
