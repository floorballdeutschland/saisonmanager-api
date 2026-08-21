require 'test_helper'

# Der Submit eines Kursimports wendet alle Zeilen in EINER Transaktion an. Die
# Lizenzmails gehen deshalb erst nach dem Commit raus – und nur für die Zeilen,
# die ohne LV-Review durchlaufen. Die übrigen melden sich erst mit der Freigabe
# (siehe Admin::RefereeCourseResultsControllerTest).
module Admin
  class RefereeCourseImportSubmitMailTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      # Ohne passenden Eintrag scheitert der Submit schon an der Vorprüfung
      # ("Unbekannte Lizenzstufen").
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      @import = RefereeCourseImport.create!(
        uploaded_by_user: @admin, filename: 't.csv', total_rows: 2, status: 'in_review'
      )
    end

    def result_for(referee, match_type:, **overrides)
      RefereeCourseResult.create!(
        { referee_course_import: @import,
          referee: referee,
          status: 'pending_review',
          match_type: match_type,
          match_field_count: match_type == 'exact_match' ? 6 : 4,
          csv_vorname: referee&.vorname || 'Neu', csv_nachname: referee&.nachname || 'Person',
          master_vorname_final: referee&.vorname || 'Neu',
          master_nachname_final: referee&.nachname || 'Person',
          master_email_final: referee&.email,
          lizenzstufe: 'G',
          gueltigkeit: Date.new(2026, 7, 31),
          kursstichtag: Date.new(2025, 8, 3) }.merge(overrides)
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # 6/6-Treffer laufen ohne Review durch (RefereeCourseSubmitPolicy), eine Zeile
    # ohne ableitbaren Landesverband nicht.
    test 'submit meldet nur die ohne Review durchgelaufenen Zeilen' do
      direkt = create(:referee, email: 'direkt@example.org', lizenzstufe: nil, gueltigkeit: nil)
      wartet = create(:referee, email: 'wartet@example.org', lizenzstufe: nil, gueltigkeit: nil)
      direkt_result = result_for(direkt, match_type: 'exact_match')
      wartet_result = result_for(wartet, match_type: 'partial_match', state_association_id: nil)
      login(@admin)

      assert_enqueued_emails 1 do
        post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
        assert_response :success
      end

      # Nicht nur zaehlen, sondern pruefen, WER die Mail bekommt: Bei einer
      # verdrehten Bedingung bliebe die Zahl 1 und die Mail ginge an den
      # falschen Schiedsrichter.
      perform_enqueued_jobs
      assert_equal ['direkt@example.org'], ActionMailer::Base.deliveries.last.to

      assert_equal 1, JSON.parse(response.body)['license_notifications']
      assert_equal 'applied', direkt_result.reload.status
      assert_not direkt_result.license_notification_pending
      assert_equal 'pending_review', wartet_result.reload.status
      assert wartet_result.license_notification_pending
    end

    # Die Antwort trennt „ohne Adresse" von „nichts zu melden": Nach einem Kurs
    # mit vielen Zeilen ist das erste eine Aufgabenliste, das zweite in Ordnung.
    test 'submit zaehlt die nicht erreichbaren Schiedsrichter getrennt' do
      result_for(create(:referee, email: 'direkt@example.org', lizenzstufe: nil, gueltigkeit: nil),
                 match_type: 'exact_match')
      result_for(create(:referee, email: nil, lizenzstufe: nil, gueltigkeit: nil),
                 match_type: 'exact_match')
      login(@admin)

      assert_enqueued_emails 1 do
        post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
        assert_response :success
      end

      antwort = JSON.parse(response.body)
      assert_equal 1, antwort['license_notifications']
      assert_equal 1, antwort['license_notifications_unreachable']
    end

    # Der Kommentar an RefereeNotification verspricht, dass ein Fehlschlag beim
    # Versand den Vorgang nicht umwirft: Der Import ist angewendet, die Mail
    # laesst sich nachholen, ein 500er hinterliesse einen halb angewendeten
    # Import.
    test 'ein Fehler beim Versand laesst den Import angewendet' do
      referee = create(:referee, email: 'direkt@example.org', lizenzstufe: nil, gueltigkeit: nil)
      result = result_for(referee, match_type: 'exact_match')
      login(@admin)

      # Der Fehler fliegt dort, wo RefereeNotification ihn abfaengt: beim Bauen
      # und Einreihen der Mail.
      RefereeMailer.stub(:license_notification, ->(*, **) { raise 'SMTP kaputt' }) do
        post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      end

      assert_response :success
      assert_equal 'applied', result.reload.status
      assert_equal 'G', referee.reload.lizenzstufe
      assert_equal 0, JSON.parse(response.body)['license_notifications']
    end

    # Scheitert eine spätere Zeile, rollt die Transaktion alles zurück. Es darf
    # dann auch keine Mail zu einer Lizenz geben, die gar nicht geschrieben wurde.
    test 'ein Fehler in einer spaeteren Zeile verschickt keine Mail' do
      direkt = create(:referee, email: 'direkt@example.org', lizenzstufe: nil, gueltigkeit: nil)
      belegt = create(:referee, lizenznummer: 424_242)
      result_for(direkt, match_type: 'exact_match')
      # Neuanlage auf eine schon belegte Lizenznummer → RecordNotUnique →
      # SubmitRowError.
      result_for(nil, match_type: 'new_entry',
                      master_lizenznummer_by_importer: belegt.lizenznummer,
                      master_lizenznummer_final: belegt.lizenznummer)
      login(@admin)

      assert_enqueued_emails 0 do
        post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
        assert_response :unprocessable_entity
      end

      assert_nil direkt.reload.lizenzstufe
      assert_equal 'in_review', @import.reload.status
    end
  end
end
