require 'test_helper'

class RefereeClubLookupTest < ActiveSupport::TestCase
  def setup
    @club      = create(:club, name: 'TSV Hochdahl')
    @long      = create(:club, name: 'SSF Bonn', long_name: 'SSF Bonn 1905 e.V.')
    @short     = create(:club, name: 'Turnverein Musterstadt', short_name: 'TVM')
    @deaktiv   = create(:club, name: 'DJK Hansa Dortmund', deactivated_at: Time.current)
    @duplikat  = create(:club, name: 'SVGO Bremen')
    @master    = create(:club, name: 'SV Grambke-Oslebshausen')
  end

  def lookup(aliases = {})
    RefereeClubLookup.new(aliases: aliases)
  end

  test 'exakter Name' do
    result = lookup.call('TSV Hochdahl')

    assert_equal @club.id, result.club_id
    assert_equal :name, result.match_type
  end

  test 'Groß- und Kleinschreibung sowie Leerzeichen sind egal' do
    assert_equal @club.id, lookup.call('  tsv hochdahl ').club_id
  end

  test 'long_name greift, wenn der Kurzname nicht passt' do
    result = lookup.call('SSF Bonn 1905 e.V.')

    assert_equal @long.id, result.club_id
    assert_equal :long_name, result.match_type
  end

  test 'short_name greift' do
    assert_equal :short_name, lookup.call('TVM').match_type
  end

  test 'normalisiert: „e.V." und Satzzeichen fallen weg' do
    result = lookup.call('T.S.V. Hochdahl e. V.')

    assert_equal @club.id, result.club_id
    assert_equal :normalized_name, result.match_type
  end

  test 'Alias schlägt den exakten Namenstreffer und verhindert die Dublette' do
    result = lookup({ 'SVGO Bremen' => @master.id }).call('SVGO Bremen')

    assert_equal @master.id, result.club_id, 'Alias muss vor dem exakten Namen greifen'
    assert_equal :alias, result.match_type
    assert_not_equal @duplikat.id, result.club_id
  end

  test 'Alias ist case-insensitiv' do
    assert_equal @master.id, lookup({ 'svgo bremen' => @master.id }).call('SVGO Bremen').club_id
  end

  test 'Alias auf einen nicht existierenden Club wird gemeldet statt still ignoriert' do
    service = lookup({ 'Irgendwas' => 999_999 })

    assert_equal [999_999], service.missing_alias_targets
    assert_equal :none, service.call('Irgendwas').match_type
  end

  test 'deaktivierte Vereine bleiben zuordenbar' do
    assert_equal @deaktiv.id, lookup.call('DJK Hansa Dortmund').club_id
  end

  test 'Statustexte im Vereinsfeld ergeben keinen Verein' do
    ['Karriere beendet', 'ohne Verein', 'KARRIERE BEENDET'].each do |value|
      result = lookup.call(value)

      assert_nil result.club_id
      assert_equal :placeholder, result.match_type, "#{value} muss als Platzhalter gelten"
    end
  end

  test 'leerer Wert ergibt keinen Verein' do
    assert_equal :blank, lookup.call(nil).match_type
    assert_equal :blank, lookup.call('  ').match_type
  end

  test 'mehrdeutige normalisierte Treffer werden nicht geraten' do
    create(:club, name: 'FC Doppel e.V.')
    create(:club, name: 'FC Doppel!')

    result = lookup.call('FC Doppel')

    assert_nil result.club_id
    assert_equal :ambiguous, result.match_type
  end

  test 'ein exakter Treffer schlägt eine normalisierte Mehrdeutigkeit' do
    eindeutig = create(:club, name: 'FC Eindeutig')
    create(:club, name: 'FC Eindeutig e.V.')

    result = lookup.call('FC Eindeutig')

    assert_equal eindeutig.id, result.club_id
    assert_equal :name, result.match_type
  end

  test 'unbekannter Verein ergibt :none' do
    assert_equal :none, lookup.call('MFBC Leipzig').match_type
  end

  test 'die ausgelieferte Alias-Datei ist lesbar und verweist auf Integer-IDs' do
    aliases = RefereeClubLookup.load_aliases

    assert_predicate aliases.size, :positive?
    assert(aliases.values.all? { |id| id.is_a?(Integer) && id.positive? })
    assert aliases.key?('SVGO Bremen')
  end
end
