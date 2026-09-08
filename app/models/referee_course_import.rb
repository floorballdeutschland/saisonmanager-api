class RefereeCourseImport < ApplicationRecord
  # `partially_submitted`: Der Importeur hat einen Teil eingereicht und Zeilen
  # zurueckgestellt. Der Import bleibt damit bearbeitbar, seine
  # zurueckgestellten Zeilen koennen nach der Klaerung nachgereicht werden.
  STATUSES = %w[in_review partially_submitted submitted cancelled].freeze

  # Zustaende, in denen der Importeur seine noch nicht eingereichten Zeilen
  # bearbeiten, zurueckstellen und einreichen darf.
  EDITABLE_STATUSES = %w[in_review partially_submitted].freeze

  belongs_to :uploaded_by_user, class_name: 'User'
  has_many :referee_course_results, dependent: :destroy

  # Original-CSV als Audit-Trail. Wird beim Upload attached, dependent: :purge_later
  # raeumt das Blob mit, wenn der Import geloescht wird.
  has_one_attached :source_csv

  validates :status, inclusion: { in: STATUSES }

  scope :open, -> { where.not(status: 'cancelled') }

  def editable?
    EDITABLE_STATUSES.include?(status)
  end

  # Ein teilweise eingereichter Import ist fertig, sobald keine offene Zeile
  # mehr auf den Importeur wartet -- die letzte wurde nachgereicht oder
  # verworfen. Am Modell und nicht im Controller, weil beide Wege dort
  # vorbeikommen: das Verwerfen einer Zeile und der Submit, der nichts mehr zu
  # tun findet (Selbstheilung, falls sich die beiden ueberholt haben).
  def close_if_done!
    return unless status == 'partially_submitted'
    return if referee_course_results.open_for_importer.exists?

    update!(status: 'submitted')
  end

  def source_csv_url
    return nil unless source_csv.attached?

    Rails.application.routes.url_helpers.rails_blob_path(source_csv, only_path: true)
  end

  def progress_counts
    counts = referee_course_results.group(:status).count
    # Die offenen Zeilen in einer zweiten Abfrage nach zurueckgestellt/nicht
    # aufteilen, statt beide Zahlen einzeln zu zaehlen: `index` rendert alle
    # Importe ohne Paginierung, jede Extra-Abfrage zaehlt dort pro Import.
    open_counts = referee_course_results.open_for_importer.group(:deferred).count
    {
      total: total_rows,
      pending_review: counts.fetch('pending_review', 0),
      applied: counts.fetch('applied', 0),
      rejected: counts.fetch('rejected', 0),
      # Getrennt von `pending_review`, das beide Lagen umfasst: die Zeile, die
      # beim Landesverband wartet, und die vom Importeur zurueckgestellte.
      deferred: open_counts.fetch(true, 0),
      submittable: open_counts.fetch(false, 0)
    }
  end

  def short_hash
    {
      id:,
      filename:,
      status:,
      total_rows:,
      created_at: created_at&.iso8601,
      uploaded_by_user_id:
    }
  end

  def full_hash
    short_hash.merge(progress: progress_counts, source_csv_url: source_csv_url)
  end
end
