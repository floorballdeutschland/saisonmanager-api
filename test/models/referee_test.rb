require 'test_helper'

class RefereeTest < ActiveSupport::TestCase
  def make_referee(lizenznummer:, partner_lizenznummer: nil)
    Referee.create!(
      lizenznummer: lizenznummer,
      vorname: "V#{lizenznummer}",
      nachname: "N#{lizenznummer}",
      partner_lizenznummer: partner_lizenznummer
    )
  end

  test 'partner_lizenznummer: setzt Gegen-Eintrag beim Partner, wenn dort noch leer' do
    a = make_referee(lizenznummer: 20_001)
    b = make_referee(lizenznummer: 20_002)

    a.update!(partner_lizenznummer: b.lizenznummer)

    assert_equal b.lizenznummer, a.reload.partner_lizenznummer
    assert_equal a.lizenznummer, b.reload.partner_lizenznummer
  end

  test 'partner_lizenznummer: überschreibt bestehenden Partner-Eintrag NICHT' do
    a = make_referee(lizenznummer: 20_003)
    c = make_referee(lizenznummer: 20_005, partner_lizenznummer: 99_999)

    a.update!(partner_lizenznummer: c.lizenznummer)

    assert_equal c.lizenznummer, a.reload.partner_lizenznummer
    assert_equal 99_999, c.reload.partner_lizenznummer
  end

  test 'partner_lizenznummer: kein Fehler wenn Partner-Lizenznummer nicht existiert' do
    a = make_referee(lizenznummer: 20_006)

    assert_nothing_raised do
      a.update!(partner_lizenznummer: 88_888)
    end
    assert_equal 88_888, a.reload.partner_lizenznummer
  end

  test 'partner_lizenznummer: Self-Reference setzt keinen Gegen-Eintrag' do
    a = make_referee(lizenznummer: 20_007)

    assert_nothing_raised do
      a.update!(partner_lizenznummer: a.lizenznummer)
    end
  end
end
