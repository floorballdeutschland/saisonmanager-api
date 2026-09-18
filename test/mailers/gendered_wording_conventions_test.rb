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
  test 'die Sternform steht auch wirklich in den Vorlagen' do
    mit_stern = vorlagen.count { |datei| File.read(datei).include?('*in') }

    assert_operator mit_stern, :>=, 10
  end
end
