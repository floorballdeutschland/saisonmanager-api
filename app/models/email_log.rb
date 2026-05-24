class EmailLog < ApplicationRecord
  validates :recipient, :subject, :sent_at, presence: true

  scope :recent, -> { where('sent_at >= ?', 30.days.ago).order(sent_at: :desc) }

  def self.purge_old
    where('sent_at < ?', 30.days.ago).delete_all
  end
end
