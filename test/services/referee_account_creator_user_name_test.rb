require 'test_helper'

class RefereeAccountCreatorUserNameTest < ActiveSupport::TestCase
  test 'Gast bekommt den Nachnamen als Benutzernamen' do
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Serocki')

    assert_equal 'sr-serocki', RefereeAccountCreator.user_name_for(referee)
  end

  test 'Gast mit Lizenznummer bekommt trotzdem den Nachnamen' do
    referee = create(:referee, guest: true, lizenznummer: 8725, nachname: 'Jarysz')

    assert_equal 'sr-jarysz', RefereeAccountCreator.user_name_for(referee)
  end

  test 'Schiedsrichter ohne Gast-Haken behaelt die Lizenznummer' do
    referee = create(:referee, guest: false, lizenznummer: 3204, nachname: 'Müller')

    assert_equal 'sr-3204', RefereeAccountCreator.user_name_for(referee)
  end

  test 'Umlaute und ss werden ausgeschrieben' do
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Gärtner-Weiß')

    assert_equal 'sr-gaertner-weiss', RefereeAccountCreator.user_name_for(referee)
  end

  test 'Leerzeichen und Apostroph werden zum Bindestrich' do
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: "van der O'Brien")

    assert_equal 'sr-van-der-o-brien', RefereeAccountCreator.user_name_for(referee)
  end

  test 'zweiter Gast gleichen Nachnamens bekommt eine Ziffer' do
    create(:user, user_name: 'sr-nielsen')
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Nielsen')

    assert_equal 'sr-nielsen2', RefereeAccountCreator.user_name_for(referee)
  end

  test 'die Ziffer zaehlt weiter, bis der Name frei ist' do
    create(:user, user_name: 'sr-nielsen')
    create(:user, user_name: 'sr-nielsen2')
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Nielsen')

    assert_equal 'sr-nielsen3', RefereeAccountCreator.user_name_for(referee)
  end

  test 'Kollision wird kleinschreibungsneutral geprueft' do
    create(:user, user_name: 'SR-Nielsen')
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Nielsen')

    assert_equal 'sr-nielsen2', RefereeAccountCreator.user_name_for(referee)
  end

  test 'das eigene Konto zaehlt beim Umbenennen nicht als Kollision' do
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Nielsen')
    user = create(:user, user_name: 'sr-nielsen', referee_id: referee.id)

    assert_equal 'sr-nielsen', RefereeAccountCreator.user_name_for(referee, ignore_user_id: user.id)
  end

  test 'Nachname ohne verwertbare Zeichen faellt auf die Datensatz-ID zurueck' do
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: '???')

    assert_equal "sr-g#{referee.id}", RefereeAccountCreator.user_name_for(referee)
  end

  test 'die Kontoanlage vergibt den Gast-Namen' do
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: 'Kowalczyk',
                               email: 'gast@example.org')

    result = RefereeAccountCreator.new(referee).call

    assert result.success?, result.error
    assert_equal 'sr-kowalczyk', result.user.user_name
  end
end
