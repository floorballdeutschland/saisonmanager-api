require 'test_helper'

class ClubTest < ActiveSupport::TestCase
  # Issue #193: meta_hash greift für den LV-Logo-Fallback auf
  # state_association#logo_url zu. Ohne Eager-Loading lud admin_user_clubs den
  # Landesverband samt Logo-Attachment einzeln pro GameOperation nach. Mit dem
  # Preload bleibt die state_associations-Query-Zahl konstant (= 1), statt
  # linear mit der Zahl der Verbände zu wachsen, und das Logo wird mitgeladen.
  #
  # Bewusst nicht geprüft: die separate, von #193 nicht abgedeckte N+1 über das
  # GameOperation-eigene `banner` (banner_url) – daher zählen wir gezielt die
  # state_associations- und die Logo-Attachment-Queries, nicht alle
  # active_storage_attachments-Queries.
  test 'admin_user_clubs lädt LV + Logo ohne N+1 (Issue #193)' do
    create(:setting, current_season_id: '18')
    sa1 = StateAssociation.create!(name: "LV A #{SecureRandom.hex(4)}", short_name: 'A')
    sa2 = StateAssociation.create!(name: "LV B #{SecureRandom.hex(4)}", short_name: 'B')
    GameOperation.create!(name: 'GO A', short_name: 'GOA', path: "go-a-#{SecureRandom.hex(4)}", state_association: sa1)
    GameOperation.create!(name: 'GO B', short_name: 'GOB', path: "go-b-#{SecureRandom.hex(4)}", state_association: sa2)

    admin = User.create!(user_name: "n1admin_#{SecureRandom.hex(4)}", password: 'password123',
                         password_confirmation: 'password123',
                         permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }], teams: [])

    sqls = capture_sql { Club.admin_user_clubs(admin) }
    sa_queries = sqls.count { |s| s =~ /\bfrom\s+"state_associations"/i }

    # Belongs-to-Preload: eine Query für alle Landesverbände statt einer pro GO.
    # Ohne den Fix skaliert dieser Wert linear mit der Zahl der GameOperations.
    assert_operator sa_queries, :<=, 1, "Erwartet höchstens 1 state_associations-Query, war #{sa_queries}"
  end

  # Ergänzend zum N+1-Test oben: das nested Preload lädt nicht nur den
  # Landesverband, sondern auch dessen Logo-Attachment vor, sodass der
  # logo_url-Fallback in meta_hash kein has_one_attached-Logo einzeln nachlädt.
  test 'state_association-Preload lädt das Logo-Attachment mit (Issue #193)' do
    sa = StateAssociation.create!(name: "LV #{SecureRandom.hex(4)}", short_name: 'L')
    GameOperation.create!(name: 'GO', short_name: 'GO', path: "go-#{SecureRandom.hex(4)}", state_association: sa)

    gos = GameOperation.includes(state_association: { logo_attachment: :blob })
                       .where(state_association_id: sa.id).to_a

    # Lazy nachgeladene has_one_attached-Logos erkennt man am LIMIT-Suffix.
    logo_lazy_queries = capture_sql { gos.each { |g| g.state_association&.logo_url } }
                        .count { |s| s =~ /from\s+"active_storage_attachments".*\blimit\b/im }

    assert_equal 0, logo_lazy_queries,
                 "Logo-Attachment wurde lazy nachgeladen (#{logo_lazy_queries} Queries) statt aus dem Preload"
  end

  private

  def capture_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      next if payload[:name] == 'SCHEMA'
      next if payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

      sqls << payload[:sql]
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
