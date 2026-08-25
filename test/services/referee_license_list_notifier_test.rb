require 'test_helper'

# Die Lizenzlisten kommen wenige Tage vor dem Spiel statt mit der Ansetzungsmail:
# Der Link gilt nur bis zum Tag nach dem Spiel, angesetzt wird aber oft Wochen
# vorher. Ein Lauf pro Woche (Nacht Do → Fr) deckt die kommenden sieben Tage ab.
class RefereeLicenseListNotifierTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  # Freitag, 6. März 2026, kurz nach Mitternacht deutscher Zeit. Bewusst 23:10 UTC
  # des Vortags: Genau hier ginge ein Fenster auseinander, das mit `Date.current`
  # (die Anwendung läuft in UTC) statt im Kalender des Spielbetriebs rechnet.
  FRIDAY_NIGHT = Time.utc(2026, 3, 5, 23, 10)

  setup do
    ActionMailer::Base.deliveries.clear
    create(:setting)
    @league = create(:league, game_operation: create(:game_operation, :national))
    @referee = create(:referee, email: 'schiri@example.de')
    @partner = create(:referee, email: 'partner@example.de')
    @coach = create(:referee, email: 'coach@example.de')
  end

  def assignment_on(date, referee1: @referee, referee2: @partner, coach: nil, status: 'published', club: nil)
    game_day = create(:game_day, league: @league, date: date)
    game = create(:game, game_day: game_day, start_time: '14:00',
                         home_team: create(:team, league: @league), guest_team: create(:team, league: @league))
    RefereeAssignment.create!(game: game, referee1: referee1, referee2: referee2, coach: coach,
                              club: club, status: status, published_at: Time.current)
  end

  def run_notifier
    travel_to(FRIDAY_NIGHT) { RefereeLicenseListNotifier.new.run }
  end

  # Lässt die Zustellung an eine Adresse scheitern, wie ein abgewiesener
  # Empfänger in Produktion (`raise_delivery_errors` ist dort aktiv). Ein
  # Interceptor greift im echten Zustellweg von deliver_now, nicht erst an einem
  # ersetzten Mailer.
  class RejectingInterceptor
    class << self
      attr_accessor :address

      def delivering_email(mail)
        raise Net::SMTPFatalError, "550 abgewiesen: #{address}" if mail.to.include?(address)
      end
    end
  end

  def with_failing_mail_for(referee)
    RejectingInterceptor.address = referee.email
    ActionMailer::Base.register_interceptor(RejectingInterceptor)
    yield
  ensure
    ActionMailer::Base.unregister_interceptor(RejectingInterceptor)
    RejectingInterceptor.address = nil
  end

  test 'Fenster laeuft vom Lauftag sieben Tage weit' do
    travel_to FRIDAY_NIGHT do
      window = RefereeLicenseListNotifier.window

      # Kalender des Spielbetriebs: 23:10 UTC ist in Deutschland schon Freitag.
      assert_equal Date.new(2026, 3, 6), window.first
      assert_equal Date.new(2026, 3, 12), window.last
    end
  end

  test 'Schiris und Coach eines Spiels im Fenster bekommen ihre Liste' do
    assignment = assignment_on('2026-03-07', coach: @coach)

    result = nil
    assert_emails 3 do
      result = run_notifier
    end

    assert_equal 3, result[:mails]
    assert_equal 1, result[:assignments]
    assert_not_nil assignment.reload.license_lists_notified_at
  end

  # Der eigentliche Punkt der Bündelung: Wer vier Ansetzungen am Wochenende hat,
  # bekommt eine Mail mit vier Zeilen, nicht vier Mails.
  test 'mehrere Spiele eines Schiris kommen in einer Mail' do
    assignment_on('2026-03-07', referee2: nil)
    assignment_on('2026-03-08', referee2: nil)

    result = nil
    assert_emails 1 do
      result = run_notifier
    end

    assert_equal 2, result[:assignments]
    mail = ActionMailer::Base.deliveries.last
    assert_equal ['schiri@example.de'], mail.to
    assert_includes mail.body.encoded, '07.03.2026'
    assert_includes mail.body.encoded, '08.03.2026'
  end

  test 'Spiele jenseits des Fensters bleiben liegen' do
    assignment = assignment_on('2026-03-13')

    assert_emails 0 do
      run_notifier
    end
    assert_nil assignment.reload.license_lists_notified_at
  end

  test 'Spiele vor dem Lauftag bleiben liegen' do
    assignment = assignment_on('2026-03-05')

    assert_emails 0 do
      run_notifier
    end
    assert_nil assignment.reload.license_lists_notified_at
  end

  test 'nur veroeffentlichte Ansetzungen' do
    assignment_on('2026-03-07', status: 'tentative')

    assert_emails 0 do
      run_notifier
    end
  end

  # Ein zweiter Lauf am selben Tag (Wiederholung nach einem Abbruch) darf nicht
  # dieselbe Post ein zweites Mal schicken.
  test 'ein zweiter Lauf schickt nichts nach' do
    assignment_on('2026-03-07')

    run_notifier
    assert_emails 0 do
      run_notifier
    end
  end

  test 'Schiri ohne Adresse bekommt keine Mail, der Partner schon' do
    @partner.update!(email: nil)
    assignment_on('2026-03-07')

    assert_emails 1 do
      run_notifier
    end
    assert_equal ['schiri@example.de'], ActionMailer::Base.deliveries.last.to
  end

  # Bei einer Vereins-Ansetzung stellt der Verein die Schiris selbst; persönliche
  # Adressen gibt es nicht. Ein angesetzter Coach bekommt seine Liste trotzdem.
  test 'Vereins-Ansetzung erreicht nur den Coach' do
    assignment_on('2026-03-07', referee1: nil, referee2: nil, coach: @coach, club: create(:club))

    assert_emails 1 do
      run_notifier
    end
    assert_equal ['coach@example.de'], ActionMailer::Base.deliveries.last.to
  end

  # Derselbe Mensch als Schiri UND Coach eingetragen: ein Spiel, eine Zeile.
  test 'Doppelrolle ergibt keine doppelte Zeile' do
    assignment_on('2026-03-07', referee1: @referee, referee2: nil, coach: @referee)

    assert_emails 1 do
      run_notifier
    end
    body = ActionMailer::Base.deliveries.last.body.encoded
    assert_equal 1, body.scan('Lizenzlisten ansehen').size
  end

  # `game_days.date` ist eine Textspalte; ein unlesbarer Altbestand darf den Lauf
  # nicht abbrechen und die übrigen Mails nicht verhindern.
  test 'unlesbares Spieltagsdatum bricht den Lauf nicht ab' do
    kaputt = assignment_on('2026-03-07', referee2: nil)
    kaputt.game.game_day.update_column(:date, 'unbekannt')
    assignment_on('2026-03-08', referee1: @partner, referee2: nil)

    result = nil
    assert_emails 1 do
      result = run_notifier
    end

    assert_equal 1, result[:assignments]
    assert_equal ['partner@example.de'], ActionMailer::Base.deliveries.last.to
  end

  # Ein unmögliches, aber formgerechtes Datum im Fenster: „2026-02-30" passiert
  # jeden Formatfilter, lässt TO_DATE aber werfen. Weil die Abfrage über den
  # gesamten Altbestand läuft (license_lists_notified_at ist überall NULL), hätte
  # ein einziger solcher Spieltag den ganzen Versand verhindert.
  test 'unmoegliches Datum im Fenster verhindert den Versand nicht' do
    thursday_night = Time.utc(2026, 2, 26, 23, 10) # Fenster 27.02. bis 05.03.
    kaputt = assignment_on('2026-03-01', referee2: nil)
    kaputt.game.game_day.update_column(:date, '2026-02-30')
    assignment_on('2026-03-02', referee1: @partner, referee2: nil)

    result = nil
    assert_emails 1 do
      result = travel_to(thursday_night) { RefereeLicenseListNotifier.new.run }
    end

    assert_equal 1, result[:assignments]
    assert_equal ['partner@example.de'], ActionMailer::Base.deliveries.last.to
    assert_nil kaputt.reload.license_lists_notified_at
  end

  # `raise_delivery_errors` ist in Produktion aktiv. Ein abgewiesener Empfänger
  # darf den Lauf nicht abbrechen, und die übrigen Mails müssen hinausgehen.
  test 'eine fehlgeschlagene Mail stoppt den Lauf nicht' do
    fehler = assignment_on('2026-03-07', referee2: nil)
    ok = assignment_on('2026-03-08', referee1: @partner, referee2: nil)

    result = nil
    assert_emails 1 do
      result = with_failing_mail_for(@referee) { run_notifier }
    end

    assert_equal 1, result[:mails]
    assert_equal 1, result[:failures]
    assert_equal 1, result[:assignments]
    # Die gescheiterte Ansetzung bleibt unmarkiert, damit ein Wiederholungslauf
    # sie nachliefert.
    assert_nil fehler.reload.license_lists_notified_at
    assert_not_nil ok.reload.license_lists_notified_at
  end

  # Beide Schiris eines Gespanns: Geht die Mail an einen von ihnen nicht raus,
  # darf die Ansetzung nicht als erledigt gelten, sonst bekäme er nie eine Liste.
  test 'Ansetzung bleibt unmarkiert, wenn nur einer der beiden Schiris erreicht wird' do
    assignment = assignment_on('2026-03-07')

    assert_emails 1 do
      with_failing_mail_for(@partner) { run_notifier }
    end

    assert_nil assignment.reload.license_lists_notified_at
  end

  test 'window_covers erkennt kurzfristige Spiele' do
    travel_to FRIDAY_NIGHT do
      assert RefereeLicenseListNotifier.window_covers?(Date.new(2026, 3, 6))
      assert RefereeLicenseListNotifier.window_covers?(Date.new(2026, 3, 12))
      assert_not RefereeLicenseListNotifier.window_covers?(Date.new(2026, 3, 13))
      assert_not RefereeLicenseListNotifier.window_covers?(nil)
    end
  end
end
