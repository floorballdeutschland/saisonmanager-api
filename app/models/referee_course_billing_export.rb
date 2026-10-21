# Ein erzeugter Rechnungsexport (RefereeCourseBilling). Die CSV-Datei haengt
# als Anhang daran, so laesst sich spaeter nachvollziehen, was abgerechnet wurde.
class RefereeCourseBillingExport < ApplicationRecord
  belongs_to :state_association, optional: true
  belongs_to :created_by_user, class_name: 'User', optional: true
  has_many :registrations, class_name: 'RefereeCourseRegistration', foreign_key: :billing_export_id,
                           inverse_of: false, dependent: :nullify
  has_one_attached :file

  def summary_hash
    {
      id: id,
      state_association: state_association && { id: state_association.id, name: state_association.name },
      from_date: from_date,
      to_date: to_date,
      row_count: row_count,
      total_cents: total_cents,
      created_at: created_at,
      created_by: created_by_user && (created_by_user.fullname.strip.presence || created_by_user.user_name)
    }
  end
end
