# frozen_string_literal: true

require 'test_helper'

class LegacyImport::PlayerResolverTest < ActiveSupport::TestCase # rubocop:disable Style/ClassAndModuleChildren
  # [last, first, birthdate, id]
  ROWS = [
    ['Jäger', 'Louis', '1995-04-12', 101],
    ['Westermann', 'Marcel', '1990-01-01', 102],
    ['Müller', 'Tim', '2000-07-07', 103],
    ['Müller', 'Tim', '2000-07-07', 104] # Namens-/Datumsdublette → mehrdeutig
  ].freeze

  test 'build_index überspringt leere Geburtsdaten und verwirft mehrdeutige Treffer' do
    index = LegacyImport::PlayerResolver.build_index(ROWS + [['Ohne', 'Datum', '', 105]])
    assert_equal 101, index[LegacyImport::PlayerResolver.key('Jäger', 'Louis', '1995-04-12')]
    # Müller/Tim/2000-07-07 ist doppelt → nicht im Index
    assert_nil index[LegacyImport::PlayerResolver.key('Müller', 'Tim', '2000-07-07')]
    # leeres Geburtsdatum gar nicht aufgenommen
    assert_nil index[LegacyImport::PlayerResolver.key('Ohne', 'Datum', '')]
  end

  test 'resolve mappt alte id_spieler case-insensitiv auf neue Player-IDs' do
    index = LegacyImport::PlayerResolver.build_index(ROWS)
    spieler = {
      '7001' => { 'name' => 'jäger', 'vorname' => ' Louis ', 'geb_datum' => '1995-04-12' },
      '7002' => { 'name' => 'Westermann', 'vorname' => 'Marcel', 'geb_datum' => '1990-01-01T00:00:00' },
      '7003' => { 'name' => 'Unbekannt', 'vorname' => 'Wer', 'geb_datum' => '1980-02-02' }
    }
    result = LegacyImport::PlayerResolver.resolve(spieler, index)

    assert_equal 101, result[7001]              # Groß/Klein + Whitespace egal
    assert_equal 102, result[7002]              # Datum auf 10 Zeichen gekürzt
    assert_nil result[7003]                     # kein Treffer → nicht enthalten
  end
end
