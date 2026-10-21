# Zuordnung einer Kursleitung (Benutzerkonto) zu einem Kurs.
class RefereeCourseLead < ApplicationRecord
  belongs_to :referee_course
  belongs_to :user

  validates :user_id, uniqueness: { scope: :referee_course_id }
end
