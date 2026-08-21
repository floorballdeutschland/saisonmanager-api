require 'test_helper'

# Der Schiri erfährt von einer ergänzten oder geänderten Zusatzqualifikation per
# Mail. Ausgelöst wird sie in referees#update, die Bedingungen liegen in
# RefereeNotification, der Vergleich in RefereeQualificationDiff.
module Admin
  class RefereeQualificationMailTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @coach = RefereeQualificationType.create!(name: "B-Coach #{SecureRandom.hex(3)}")
      @beob  = RefereeQualificationType.create!(name: "Beobachter #{SecureRandom.hex(3)}")
      @referee = create(:referee, email: 'schiri@example.org')
      login(@admin)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def put_qualifications(referee, qualifications, **weitere_felder)
      put "/api/v2/admin/referees/#{referee.id}",
          params: { referee: { qualifications: qualifications }.merge(weitere_felder) }
      assert_response :success
    end

    def add_qualification(referee, type, valid_until: nil)
      referee.referee_qualifications.create!(referee_qualification_type: type, valid_until: valid_until)
    end

    test 'ergaenzte Qualifikation loest eine Mail aus' do
      assert_enqueued_emails 1 do
        put_qualifications(@referee, [{ qualification_type_id: @coach.id, valid_until: '30.06.2027' }])
      end
    end

    # Rendert die Vorlage wirklich: Ein Fehler im ERB-View fällt sonst erst in
    # Produktion beim Zustellen auf, weil assert_enqueued_emails nur einreiht.
    test 'die Mail nennt Empfaenger, Betreff und die Qualifikation' do
      put_qualifications(@referee, [{ qualification_type_id: @coach.id, valid_until: '30.06.2027' }])
      perform_enqueued_jobs

      mail = ActionMailer::Base.deliveries.last
      assert_equal ['schiri@example.org'], mail.to
      assert_includes mail.subject, 'Zusatzqualifikation aktualisiert'
      assert_includes mail.body.to_s, @coach.name
      assert_includes mail.body.to_s, '30.06.2027'
    end

    test 'geaenderte Gueltigkeit loest eine Mail aus' do
      add_qualification(@referee, @coach, valid_until: Date.new(2026, 6, 30))

      assert_enqueued_emails 1 do
        put_qualifications(@referee, [{ qualification_type_id: @coach.id, valid_until: '30.06.2027' }])
      end
    end

    test 'unveraenderte Qualifikationen loesen keine Mail aus' do
      add_qualification(@referee, @coach, valid_until: Date.new(2027, 6, 30))

      assert_enqueued_emails 0 do
        put_qualifications(@referee, [{ qualification_type_id: @coach.id, valid_until: '30.06.2027' }])
      end
    end

    test 'ein Wegfall loest keine Mail aus' do
      add_qualification(@referee, @coach)
      add_qualification(@referee, @beob)

      assert_enqueued_emails 0 do
        put_qualifications(@referee, [{ qualification_type_id: @coach.id, valid_until: nil }])
      end
    end

    # Zwei pflegbare Vorlagen mit je eigenem Betreff, also zwei Mails.
    test 'Lizenz und Qualifikation im selben Speichern ergeben zwei Mails' do
      assert_enqueued_emails 2 do
        put_qualifications(@referee, [{ qualification_type_id: @coach.id, valid_until: nil }],
                           lizenzstufe: 'A')
      end
    end

    test 'ohne hinterlegte E-Mail-Adresse geht keine Mail raus' do
      ohne_mail = create(:referee, email: nil)

      assert_enqueued_emails 0 do
        put_qualifications(ohne_mail, [{ qualification_type_id: @coach.id, valid_until: nil }])
      end
    end

    # Gäste sind Aushilfen ohne eigene Zuständigkeit im Verband, meist aus dem
    # Ausland – wie bei der Lizenzmail bekommen sie keine Post.
    test 'ein Gast bekommt keine Mail' do
      gast = create(:referee, guest: true, lizenznummer: nil, email: 'gast@example.org')

      assert_enqueued_emails 0 do
        put_qualifications(gast, [{ qualification_type_id: @coach.id, valid_until: nil }])
      end
    end

    test 'beim Anlegen eines Schiris geht keine Mail raus' do
      assert_enqueued_emails 0 do
        post '/api/v2/admin/referees', params: {
          referee: { lizenznummer: 987_654, vorname: 'Neu', nachname: 'Schiri',
                     email: 'neu@example.org',
                     qualifications: [{ qualification_type_id: @coach.id, valid_until: '30.06.2027' }] }
        }
        assert_response :created
      end
    end
  end
end
