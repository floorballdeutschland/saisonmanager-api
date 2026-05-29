class RefereeCourseImport < ApplicationRecord
  STATUSES = %w[in_review submitted cancelled].freeze

  belongs_to :uploaded_by_user, class_name: 'User'
  has_many :referee_course_results, dependent: :destroy

  # Original-CSV als Audit-Trail. Wird beim Upload attached, dependent: :purge_later
  # raeumt das Blob mit, wenn der Import geloescht wird.
  has_one_attached :source_csv

  validates :status, inclusion: { in: STATUSES }

  scope :open, -> { where.not(status: 'cancelled') }

  def source_csv_url
    return nil unless source_csv.attached?

    Rails.application.routes.url_helpers.rails_blob_path(source_csv, only_path: true)
  end

  def progress_counts
    counts = referee_course_results.group(:status).count
    {
      total: total_rows,
      pending_review: counts.fetch('pending_review', 0),
      applied: counts.fetch('applied', 0)
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
