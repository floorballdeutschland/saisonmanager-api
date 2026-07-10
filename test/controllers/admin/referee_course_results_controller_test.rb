require 'test_helper'

module Admin
  class RefereeCourseResultsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @import = RefereeCourseImport.create!(
        uploaded_by_user: @admin, filename: 't.csv', total_rows: 1, status: 'in_review'
      )
      # Kursjahr 2025: Ablaufjahr hängt an der Dauer der zugeordneten Stufe.
      @result = RefereeCourseResult.create!(
        referee_course_import: @import,
        status: 'pending_review',
        match_type: 'new_entry',
        match_field_count: 0,
        csv_vorname: 'V', csv_nachname: 'N',
        kursstichtag: Date.new(2025, 8, 3)
      )
    end

    # Dritte Säule der Vereinheitlichung (#87): setzt der LV-Reviewer die Stufe,
    # leitet der Controller die Gültigkeit über RefereeLicenseLevel.gueltigkeit_for
    # ab — mit der Dauer DIESER Stufe und dem Regeljahr-Stichtag.
    test 'update leitet gueltigkeit aus der Stufe ab (Regeljahr → 31.07.)' do
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      login(@admin)

      # 2025 + 1 = 2026 (Regeljahr) → 31.07.2026
      patch "/api/v2/admin/referee_course_results/#{@result.id}", params: { lizenzstufe: 'G' }

      assert_response :success
      assert_equal '2026-07-31', JSON.parse(response.body)['gueltigkeit']
      assert_equal Date.new(2026, 7, 31), @result.reload.gueltigkeit
    end

    test 'update nutzt die validity_years der Stufe (kein Regeljahr → 30.09.)' do
      RefereeLicenseLevel.create!(name: 'N1', validity_years: 2)
      login(@admin)

      # 2025 + 2 = 2027 (kein Regeljahr) → 30.09.2027
      patch "/api/v2/admin/referee_course_results/#{@result.id}", params: { lizenzstufe: 'N1' }

      assert_response :success
      assert_equal Date.new(2027, 9, 30), @result.reload.gueltigkeit
    end

    test 'update belässt eine explizit mitgesendete gueltigkeit (manueller Wert hat Vorrang)' do
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      login(@admin)

      patch "/api/v2/admin/referee_course_results/#{@result.id}",
            params: { lizenzstufe: 'G', gueltigkeit: '2099-01-15' }

      assert_response :success
      assert_equal Date.new(2099, 1, 15), @result.reload.gueltigkeit
    end

    # Der „Anwenden"-Pfad (approve → RefereeCourseResultApplier) leitet die
    # Gültigkeit ebenfalls über gueltigkeit_for ab und überschreibt dabei einen
    # veralteten, zuvor gespeicherten Wert — hier end-to-end über HTTP geprüft.
    test 'approve leitet die gueltigkeit des Referees ueber gueltigkeit_for ab (Regeljahr → 31.07.)' do
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      referee = create(:referee, lizenzstufe: nil, gueltigkeit: nil)
      result = RefereeCourseResult.create!(
        referee_course_import: @import,
        referee: referee,
        status: 'pending_review',
        match_type: 'exact_match',
        match_field_count: 6,
        csv_vorname: referee.vorname, csv_nachname: referee.nachname,
        lizenzstufe: 'G',
        gueltigkeit: Date.new(2026, 9, 30), # veralteter 30.09.-Wert, wird neu abgeleitet
        kursstichtag: Date.new(2025, 8, 3)
      )
      login(@admin)

      post "/api/v2/admin/referee_course_results/#{result.id}/approve"

      assert_response :success
      # 2025 + 1 = 2026 (Regeljahr) → 31.07.2026, nicht der gespeicherte 30.09.
      assert_equal Date.new(2026, 7, 31), referee.reload.gueltigkeit
      assert_equal 'applied', result.reload.status
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
