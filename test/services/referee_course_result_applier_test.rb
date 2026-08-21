require 'test_helper'

class RefereeCourseResultApplierTest < ActiveSupport::TestCase
  # ActiveSupport::TestCase bringt die Mail-Assertions hier nicht mit (anders als
  # ActionDispatch::IntegrationTest).
  include ActionMailer::TestHelper

  def setup
    @admin = create(:user, :admin)
    @import = RefereeCourseImport.create!(
      uploaded_by_user: @admin, filename: 't.csv', total_rows: 1
    )
  end

  def make_result(referee: nil, **overrides)
    defaults = {
      referee_course_import: @import,
      referee:               referee,
      csv_lizenznummer:      referee&.lizenznummer,
      csv_vorname:           referee&.vorname || 'V',
      csv_nachname:          referee&.nachname || 'N',
      csv_geburtsdatum:      Date.new(2000, 1, 1),
      csv_verein:            nil,
      csv_email:             nil,
      master_lizenznummer_by_importer: referee&.lizenznummer,
      master_vorname_by_importer:      referee&.vorname || 'V',
      master_nachname_by_importer:     referee&.nachname || 'N',
      master_geburtsdatum_by_importer: Date.new(2000, 1, 1),
      master_club_id_by_importer:      referee&.club_id,
      master_email_by_importer:        nil,
      master_lizenznummer_final: referee&.lizenznummer,
      master_vorname_final:      referee&.vorname || 'V',
      master_nachname_final:     referee&.nachname || 'N',
      master_geburtsdatum_final: Date.new(2000, 1, 1),
      master_club_id_final:      referee&.club_id,
      master_email_final:        nil,
      lizenzstufe:               'G',
      gueltigkeit:               Date.new(2026, 9, 30),
      kursstichtag:              Date.new(2025, 8, 3),
      match_type:                referee ? 'exact_match' : 'new_entry',
      match_field_count:         referee ? 6 : 0,
      status:                    'pending_review'
    }
    RefereeCourseResult.create!(defaults.merge(overrides))
  end

  # ---- Lizenzmail -------------------------------------------------------
  #
  # Der Versand liegt bewusst nicht in `call`: Der Submit wendet alle Zeilen
  # eines Imports in EINER Transaktion an, ein Versand darin hinterließe bei
  # einem Fehler in einer späteren Zeile Mails zu zurückgerollten Lizenzen.

  test 'direkt angewendete Lizenzaenderung schickt die Mail nach dem Commit' do
    ref = create(:referee, email: 'schiri@example.org', lizenzstufe: nil, gueltigkeit: nil)
    # master_email_final muss die Adresse tragen: Bei review_required=false
    # uebernimmt der Applier die Stammdaten und leert dabei bewusst leere Felder –
    # ohne sie stuende der Schiri danach ohne E-Mail da.
    result = make_result(referee: ref, master_email_final: ref.email)
    applier = RefereeCourseResultApplier.new(result, performed_by_user: @admin)

    assert_enqueued_emails 0 do
      applier.call(review_required: false)
    end
    assert_enqueued_emails 1 do
      applier.deliver_pending_license_notification
    end
  end

  test 'review-pflichtige Zeile vermerkt die Mail statt sie zu schicken' do
    ref = create(:referee, email: 'schiri@example.org', lizenzstufe: nil, gueltigkeit: nil)
    result = make_result(referee: ref)
    applier = RefereeCourseResultApplier.new(result, performed_by_user: @admin)

    applier.call(review_required: true)

    assert_enqueued_emails 0 do
      applier.deliver_pending_license_notification
    end
    assert result.reload.license_notification_pending
  end

  # Zweiter Lauf über dieselbe Zeile (die LV-Freigabe): Die Lizenzfelder ändern
  # sich nicht mehr, gemeldet wird über den Vermerk aus dem Submit.
  test 'die Freigabe schickt die beim Submit vermerkte Mail' do
    ref = create(:referee, email: 'schiri@example.org', lizenzstufe: nil, gueltigkeit: nil)
    result = make_result(referee: ref, master_email_final: 'schiri@example.org')
    RefereeCourseResultApplier.new(result, performed_by_user: @admin).call(review_required: true)

    freigabe = RefereeCourseResultApplier.new(result, performed_by_user: @admin)
    freigabe.call(review_required: false)

    assert_enqueued_emails 1 do
      freigabe.deliver_pending_license_notification
    end
    assert_not result.reload.license_notification_pending
  end

  # Ohne das `if license_changed` am Vermerk wuerde jede LV-Freigabe einer
  # nachgereichten Zeile eine Mail ueber eine Lizenz schicken, die sich nie
  # bewegt hat.
  test 'review-pflichtige Zeile ohne Lizenzaenderung vermerkt nichts' do
    RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
    ref = create(:referee, email: 'schiri@example.org',
                           lizenzstufe: 'G', gueltigkeit: Date.new(2026, 7, 31))
    result = make_result(referee: ref)

    RefereeCourseResultApplier.new(result, performed_by_user: @admin).call(review_required: true)

    assert_not result.reload.license_notification_pending
  end

  test 'unveraenderte Lizenz schickt keine Mail' do
    # Kursjahr 2025 + validity_years 1 → Regeljahr 2026 → 31.07.2026, genau der
    # Stand des Schiris. Die Stufe explizit anlegen, damit der Test nicht an der
    # Default-Dauer haengt.
    RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
    ref = create(:referee, email: 'schiri@example.org',
                           lizenzstufe: 'G', gueltigkeit: Date.new(2026, 7, 31))
    result = make_result(referee: ref, master_email_final: ref.email)
    applier = RefereeCourseResultApplier.new(result, performed_by_user: @admin)

    applier.call(review_required: false)

    assert_enqueued_emails 0 do
      applier.deliver_pending_license_notification
    end
    assert_not result.reload.license_notification_pending
  end

  test 'Neuanlage aus dem Kurs bekommt die Mail an die Adresse aus der CSV' do
    result = make_result(referee: nil,
                         master_email_by_importer: 'neu@example.org',
                         master_email_final: 'neu@example.org')
    applier = RefereeCourseResultApplier.new(result, performed_by_user: @admin)
    applier.call(review_required: false)

    assert_enqueued_emails 1 do
      applier.deliver_pending_license_notification
    end
    assert_equal 'neu@example.org', result.reload.referee.email
  end

  # Der Kursimport legt Schiedsrichter an, die noch keinen Ausweis in der Hand
  # halten – die Mail darf ihnen keine „aktualisierte" Lizenz melden und den
  # QR-Code auf dem Ausweis nicht als vorhanden voraussetzen.
  test 'Neuanlage bekommt die Mail zur erteilten, nicht zur aktualisierten Lizenz' do
    result = make_result(referee: nil,
                         master_email_by_importer: 'neu@example.org',
                         master_email_final: 'neu@example.org')
    applier = RefereeCourseResultApplier.new(result, performed_by_user: @admin)
    applier.call(review_required: false)
    applier.deliver_pending_license_notification
    perform_enqueued_jobs

    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.subject, 'Schiedsrichterlizenz erteilt'
    assert_includes mail.body.to_s, 'wurde im Saisonmanager eine Schiedsrichterlizenz eingetragen'
    assert_includes mail.body.to_s, 'sobald du ihn erhalten hast'
  end

  test 'Bestandsschiri mit Stufe bekommt die Mail zur aktualisierten Lizenz' do
    RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
    ref = create(:referee, email: 'schiri@example.org',
                           lizenzstufe: 'N1', gueltigkeit: Date.new(2026, 7, 31))
    applier = RefereeCourseResultApplier.new(
      make_result(referee: ref, master_email_final: ref.email), performed_by_user: @admin
    )
    applier.call(review_required: false)
    applier.deliver_pending_license_notification
    perform_enqueued_jobs

    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.subject, 'Schiedsrichterlizenz aktualisiert'
    assert_includes mail.body.to_s, 'deine Schiedsrichterlizenz wurde im Saisonmanager aktualisiert'
  end

  # Ein zweiter Aufruf derselben Instanz darf nicht noch eine Mail schicken.
  test 'der Merker ist nach dem Versand leer' do
    ref = create(:referee, email: 'schiri@example.org', lizenzstufe: nil, gueltigkeit: nil)
    applier = RefereeCourseResultApplier.new(
      make_result(referee: ref, master_email_final: ref.email), performed_by_user: @admin
    )
    applier.call(review_required: false)
    applier.deliver_pending_license_notification

    assert_enqueued_emails 0 do
      assert_equal RefereeNotification::NOTHING, applier.deliver_pending_license_notification
    end
  end

  test 'ohne hinterlegte Adresse schickt der Applier keine Mail' do
    ref = create(:referee, email: nil, lizenzstufe: nil, gueltigkeit: nil)
    applier = RefereeCourseResultApplier.new(make_result(referee: ref), performed_by_user: @admin)
    applier.call(review_required: false)

    assert_enqueued_emails 0 do
      applier.deliver_pending_license_notification
    end
  end

  test 'ein Gast bekommt keine Lizenzmail' do
    gast = create(:referee, guest: true, lizenznummer: nil, email: 'gast@example.org',
                            lizenzstufe: nil, gueltigkeit: nil)
    result = make_result(referee: gast, master_email_final: gast.email)
    applier = RefereeCourseResultApplier.new(result, performed_by_user: @admin)
    applier.call(review_required: false)

    assert_enqueued_emails 0 do
      applier.deliver_pending_license_notification
    end
  end

  test 'wendet Lizenz auf bestehenden Referee an (gueltigkeit aus validity_years)' do
    RefereeLicenseLevel.create!(name: 'G', validity_years: 2)
    ref = create(:referee, lizenzstufe: nil, gueltigkeit: nil)
    result = make_result(referee: ref) # kursstichtag 2025-08-03

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    assert_equal 'applied', result.reload.status
    assert_equal 'G', ref.reload.lizenzstufe
    # Gültigkeit aus der Stufe abgeleitet: validity_years 2 + Kursjahr 2025 → 30.09.2027
    assert_equal Date.new(2027, 9, 30), ref.gueltigkeit
  end

  test 'leitet gueltigkeit ohne passende Lizenzstufe mit der Default-Dauer ab' do
    ref = create(:referee, lizenzstufe: nil, gueltigkeit: nil)
    result = make_result(referee: ref) # lizenzstufe 'G' ohne RefereeLicenseLevel-Definition

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    # Default 1 Jahr + Kursjahr 2025 → Ablaufjahr 2026 ist Regeljahr → 31.07.2026
    assert_equal Date.new(2026, 7, 31), ref.reload.gueltigkeit
  end

  test 'faellt ohne Kursstichtag auf die manuell gesetzte gueltigkeit zurueck' do
    RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
    ref = create(:referee, lizenzstufe: nil, gueltigkeit: nil)
    # Ohne kursstichtag liefert gueltigkeit_for nil → Fallback auf @result.gueltigkeit.
    result = make_result(referee: ref, kursstichtag: nil, gueltigkeit: Date.new(2028, 9, 30))

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    assert_equal Date.new(2028, 9, 30), ref.reload.gueltigkeit
  end

  test 'belässt Stammdaten unverändert bei review_required' do
    ref = create(:referee, vorname: 'Alt', nachname: 'Name')
    result = make_result(
      referee: ref,
      master_vorname_final: 'Neu', master_nachname_final: 'Korrigiert'
    )

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: true)

    assert_equal 'pending_review', result.reload.status
    assert_equal 'Alt', ref.reload.vorname
    assert_equal 'G', ref.lizenzstufe # Lizenz wird trotzdem gesetzt
  end

  test 'übernimmt Stammdaten bei review_required=false' do
    ref = create(:referee, vorname: 'Alt', nachname: 'Name')
    result = make_result(
      referee: ref,
      master_vorname_final: 'Neu', master_nachname_final: 'Korrigiert'
    )

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    assert_equal 'Neu', ref.reload.vorname
    assert_equal 'Korrigiert', ref.nachname
  end

  test 'legt Referee bei Neuanlage mit auto-Lizenznummer an' do
    # Fixtures (referees.yml) liefern Lizenznummern 10_001/10_002 — für diesen
    # Max+1-Test brauchen wir einen bekannten Ausgangszustand.
    Referee.delete_all
    create(:referee, lizenznummer: 9_998)
    create(:referee, lizenznummer: 9_999)

    result = make_result(
      referee: nil,
      master_lizenznummer_by_importer: nil,
      master_lizenznummer_final: nil,
      master_vorname_final: 'Neue', master_nachname_final: 'Person'
    )

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)
    result.reload
    assert result.new_referee_created
    assert_equal 10_000, result.master_lizenznummer_final
    assert_equal 10_000, result.referee.lizenznummer
  end

  test 'übernimmt vorgegebene Lizenznummer bei Neuanlage' do
    result = make_result(
      referee: nil,
      master_lizenznummer_by_importer: 12_345,
      master_lizenznummer_final: 12_345,
      master_vorname_final: 'Neue', master_nachname_final: 'Person'
    )

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)
    assert_equal 12_345, result.reload.referee.lizenznummer
  end

  test 'überschreibt eine bestehende Lizenznummer NIEMALS' do
    ref = create(:referee, lizenznummer: 500)
    result = make_result(
      referee: ref,
      master_lizenznummer_final: 999, # Versuch eines Importeurs, die Lizenz zu wechseln
      master_vorname_final: ref.vorname, master_nachname_final: ref.nachname
    )

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    assert_equal 500, ref.reload.lizenznummer
  end

  test 'verweigert leere Lizenzstufe' do
    ref = create(:referee)
    result = make_result(referee: ref, lizenzstufe: nil)

    error = assert_raises(RefereeCourseResultApplier::InvalidResult) do
      RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                                .call(review_required: false)
    end
    assert_match(/Lizenzstufe fehlt/, error.message)
  end

  test 'verweigert leeres Gültigkeitsdatum (kein Wipe der existing gueltigkeit)' do
    ref = create(:referee, lizenzstufe: 'A', gueltigkeit: Date.new(2030, 9, 30))
    result = make_result(referee: ref, gueltigkeit: nil)

    error = assert_raises(RefereeCourseResultApplier::InvalidResult) do
      RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                                .call(review_required: false)
    end
    assert_match(/Gültigkeitsdatum fehlt/, error.message)
    assert_equal Date.new(2030, 9, 30), ref.reload.gueltigkeit
  end

  test 'lehnt Doppel-Apply ab' do
    ref = create(:referee)
    result = make_result(referee: ref)
    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    assert_raises(RefereeCourseResultApplier::AlreadyApplied) do
      RefereeCourseResultApplier.new(result.reload, performed_by_user: @admin)
                                .call(review_required: false)
    end
  end

  test 'LV kann ein Stammdatenfeld bewusst auf nil setzen (kein .compact)' do
    ref = create(:referee, email: 'alt@example.de')
    result = make_result(referee: ref, master_email_final: nil)

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    assert_nil ref.reload.email
  end

  test 'lässt die E-Mail unangetastet, wenn der Schiri ein Benutzerkonto hat' do
    ref = create(:referee, email: 'selbst-gepflegt@example.de')
    create(:user, referee: ref)
    result = make_result(
      referee: ref,
      master_email_final: 'aus-dem-csv@example.de',
      master_vorname_final: 'Neu'
    )

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    ref.reload
    assert_equal 'selbst-gepflegt@example.de', ref.email, 'Konto-Adresse darf der Import nicht überschreiben'
    assert_equal 'Neu', ref.vorname, 'übrige Stammdaten müssen weiter übernommen werden'
  end

  test 'leert die E-Mail bei Konto-Schiris auch nicht via nil' do
    ref = create(:referee, email: 'selbst-gepflegt@example.de')
    create(:user, referee: ref)
    result = make_result(referee: ref, master_email_final: nil)

    RefereeCourseResultApplier.new(result, performed_by_user: @admin)
                              .call(review_required: false)

    assert_equal 'selbst-gepflegt@example.de', ref.reload.email
  end
end
