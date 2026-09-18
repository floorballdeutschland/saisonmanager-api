require 'test_helper'

# Die Formen selbst, ohne Mailversand. Wichtig ist hier vor allem, was NICHT
# „M" oder „W" ist: `players.gender` ist eine freie Textspalte ohne Validierung,
# der Bestand kennt „D" und leere Werte, und die Factory schreibt klein „m".
class PlayerWordingTest < ActiveSupport::TestCase
  test 'weiblich gendert Nomen, Artikel und Relativpronomen' do
    w = PlayerWording.new('W')

    assert_equal 'Spielerin', w.noun
    assert_equal 'die Spielerin', w.nominative
    assert_equal 'der Spielerin', w.genitive
    assert_equal 'von der Spielerin', w.by_agent
    assert_equal 'die folgende Spielerin', w.following_accusative
    assert_equal 'die', w.relative_nominative
    assert_equal 'als Spielerin', w.as_role
  end

  test 'maennlich bleibt bei den bisherigen Formulierungen' do
    w = PlayerWording.new('M')

    assert_equal 'Spieler', w.noun
    assert_equal 'der Spieler', w.nominative
    assert_equal 'des Spielers', w.genitive
    assert_equal 'den folgenden Spieler', w.following_accusative
  end

  test 'divers und leer teilen sich die neutrale Form' do
    %w[D].push(nil, '', '  ').each do |gender|
      w = PlayerWording.new(gender)

      assert_equal 'Spieler*in', w.noun, "gender=#{gender.inspect}"
      assert_equal 'die spielende Person', w.nominative, "gender=#{gender.inspect}"
      assert_equal 'der spielenden Person', w.genitive, "gender=#{gender.inspect}"
    end
  end

  # Der Bestand ist gemischt geschrieben (die Factory legt „m" an), und ein
  # unbekannter Wert darf nicht mit einer NoMethodError-Mail enden.
  test 'Kleinschreibung zaehlt, unbekannte Werte fallen auf neutral' do
    assert_equal 'Spielerin', PlayerWording.new('w').noun
    assert_equal 'der Spieler', PlayerWording.new(' m ').nominative
    assert_equal 'Spieler*in', PlayerWording.new('unbekannt').noun
  end

  test 'capitalized macht nur den ersten Buchstaben gross' do
    assert_equal 'Die spielende Person', PlayerWording.new(nil).capitalized(:nominative)
    assert_equal 'Die Spielerin', PlayerWording.new('W').capitalized(:nominative)
  end

  test 'for liest das Geschlecht am Spielerprofil' do
    player = create(:player, gender: 'w')

    assert_equal 'Spielerin', PlayerWording.for(player).noun
    assert_equal 'Spieler*in', PlayerWording.for(nil).noun
  end
end
