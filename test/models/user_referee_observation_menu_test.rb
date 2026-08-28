require 'test_helper'

# Der Menuepunkt „Meine Beobachtungen" haengt an der B-Zusatzqualifikation, nicht
# an der Rolle.
#
# Die Falle steckt im Early-Return von User#permissions_items: Fuer ein REINES
# Schiedsrichterkonto bricht die Methode dort ab und vergibt danach nichts mehr.
# Das ist der Normalfall eines Coaches. Stuenden die beiden neuen Schluessel
# weiter unten, bekaeme sie ausgerechnet dieser Personenkreis nie — die ersten
# beiden Tests unten fallen dann. Der letzte Test deckt den Gegenweg ab: ein
# Coach mit RSK-Zweitrolle laeuft am Early-Return vorbei und muss sie ebenfalls
# bekommen, ohne die uebrigen Selfservice-Rechte zu erben.
class UserRefereeObservationMenuTest < ActiveSupport::TestCase
  setup do
    @b_type = RefereeQualificationType.create!(name: 'B-Coach', short_name: 'B', active: true)
  end

  test 'Schiedsrichter mit gueltiger B-Qualifikation bekommt den Menuepunkt' do
    user = referee_user(coach_referee)
    items = user.permissions_items

    assert items[:menu_item_referee_observations]
    assert items[:show_page_referee_observations]
  end

  test 'Schiedsrichter ohne B-Qualifikation sieht nur die eigenen Rueckmeldungen' do
    user = referee_user(create(:referee))
    items = user.permissions_items

    assert_not items[:menu_item_referee_observations]
    assert items[:show_page_referee_observations]
  end

  test 'abgelaufene B-Qualifikation vergibt den Menuepunkt nicht' do
    referee = create(:referee)
    RefereeQualification.create!(referee: referee, referee_qualification_type: @b_type,
                                 valid_until: Date.current - 1)

    assert_not referee_user(referee).permissions_items[:menu_item_referee_observations]
  end

  test 'Konto ohne Schiedsrichterprofil bekommt keinen der beiden Schluessel' do
    items = create(:user, :admin).permissions_items

    assert_not items[:menu_item_referee_observations]
    assert_not items[:show_page_referee_observations]
  end

  test 'Coach mit RSK-Zweitrolle bekommt die Schluessel trotz Early-Return' do
    referee = coach_referee
    user = create(:user, :rsk_scoped, game_operation_id: create(:game_operation).id,
                                      referee: referee)
    items = user.permissions_items

    assert items[:menu_item_referee_observations],
           'Der Early-Return in permissions_items darf den Coach-Menuepunkt nicht verschlucken'
    assert items[:show_page_referee_observations]
    # Gegenprobe: Die uebrigen Selfservice-Rechte bekommt diese Rolle bewusst nicht.
    assert_not items[:menu_item_referee_profile]
  end

  private

  def coach_referee
    referee = create(:referee)
    RefereeQualification.create!(referee: referee, referee_qualification_type: @b_type)
    referee
  end

  def referee_user(referee)
    create(:user, referee: referee,
                  permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }])
  end
end
