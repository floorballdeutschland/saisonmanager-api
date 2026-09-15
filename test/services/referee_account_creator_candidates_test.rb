require 'test_helper'

# Gäste bleiben aus der Massenanlage heraus, dürfen aber einzeln ein Konto
# bekommen. Beide Hälften dieser Entscheidung stehen an verschiedenen Stellen im
# Code und werden hier zusammen festgehalten.
class RefereeAccountCreatorCandidatesTest < ActiveSupport::TestCase
  # Die Factory vergibt eine Lizenznummer, der Nachweis liegt im Fenster: Dieser
  # Gast scheitert also allein am Gast-Haken und nicht an einer der übrigen
  # Bedingungen. Genau darauf kommt es an, sonst hinge der Ausschluss an einer
  # Nebenwirkung.
  def gast_mit_nachweis
    create(:referee, guest: true, email: 'gast@example.org', gueltigkeit: 1.year.from_now.to_date)
  end

  test 'ein Gast steht nicht in der Kandidatenliste der Massenanlage' do
    gast_mit_nachweis

    assert_empty RefereeAccountCreator.candidates
  end

  test 'derselbe Datensatz ohne Gast-Haken steht darin' do
    referee = create(:referee, guest: false, email: 'schiri@example.org',
                               gueltigkeit: 1.year.from_now.to_date)

    assert_includes RefereeAccountCreator.candidates, referee
  end

  test 'die Einzelanlage legt einem Gast trotzdem ein Konto an' do
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Serocki',
                               email: 'gast@example.org')

    result = RefereeAccountCreator.new(referee).call

    assert result.success?, result.error
    assert_equal 'sr-serocki', result.user.user_name
  end
end
