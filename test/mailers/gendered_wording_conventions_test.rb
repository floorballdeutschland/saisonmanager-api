require 'test_helper'

# Die Schreibweise der Personenbezeichnungen war ueber die Vorlagen verteilt und
# uneinheitlich: „Schiedsrichter:innen", „Schiedsrichter/innen",
# „Schiedsrichtercoach/in" und blankes „Schiedsrichter" standen nebeneinander.
# Vereinbart ist die Sternform.
#
# Geprueft wird der Quelltext der Vorlagen und nicht eine gerenderte Mail: Die
# meisten dieser Stellen sind feste Beschriftungen, fuer die es keinen Testfall
# gibt, und eine neue Vorlage mit alter Schreibweise faellt sonst erst im
# Postfach auf.
class GenderedWordingConventionsTest < ActiveSupport::TestCase
  # Nur Personenbezeichnungen. Komposita, deren eigentliches Substantiv ein
  # Objekt ist ("Schiedsrichterausweis", "Spielerfreigabe"), bleiben ungegendert
  # und werden hier deshalb gar nicht erst gesucht.
  ALTE_FORMEN = %r{(Spieler|Spielerinnen|Schiedsrichter|Schiedsrichtercoach|Kapitän|Funktionär|Partner)(:in|:innen|/in|/innen)}

  def vorlagen
    Dir[Rails.root.join('app/views/*_mailer/**/*.erb')] +
      [Rails.root.join('app/services/referee_assignment_calendar.rb').to_s]
  end

  test 'keine Vorlage benutzt mehr die Doppelpunkt- oder Schraegstrichform' do
    treffer = vorlagen.filter_map do |datei|
      fund = File.read(datei).scan(ALTE_FORMEN).map(&:join).uniq
      "#{datei.sub("#{Rails.root}/", '')}: #{fund.join(', ')}" if fund.any?
    end

    assert_empty treffer, "Sternform verwenden (Schiedsrichter*in, Spieler*in):\n#{treffer.join("\n")}"
  end

  # Gegenprobe: Der Test oben ist auch dann gruen, wenn jemand die Bezeichnungen
  # ersatzlos aus den Vorlagen entfernt.
  #
  # Gezaehlt werden die VORKOMMEN und nicht die Dateien: Bei einer Schwelle je
  # Datei reichten die Schiedsrichter-Vorlagen allein aus, und ein Dutzend
  # Bezeichnungen koennte still auf die alte Form zurueckfallen, ohne dass einer
  # der beiden Tests etwas sagt. Die Schwelle liegt unter dem heutigen Stand
  # (29), damit eine einzelne umformulierte Vorlage sie nicht reisst.
  test 'die Sternform steht auch wirklich in den Vorlagen' do
    mit_stern = vorlagen.sum { |datei| File.read(datei).scan('*in').size }

    assert_operator mit_stern, :>=, 25
  end

  # Was dieser Test NICHT leisten kann: die blanke Form ohne Endung
  # („Schiedsrichter" als Personenbezeichnung) zu finden. Sie ist von einem
  # Kompositum („Schiedsrichterausweis", „Spielerfreigabe") nicht per Muster zu
  # unterscheiden, und die Komposita bleiben absichtlich ungegendert. Wer eine
  # Vorlage anfasst, prueft das selbst.
end
