module Vm
  class RefereesController < ApplicationController
    before_action :authorize_vm!

    # GET /api/v2/vm/referees
    def index
      club_ids = current_user.permission_hash[:vm]
      referees = Referee.where(club_id: club_ids)
                        .includes(club: :state_association,
                                  referee_qualifications: :referee_qualification_type)
                        .order(:nachname, :vorname)

      render json: referees.map { |r| referee_vm_json(r) }
    end

    private

    def authorize_vm!
      return if current_user.permission_hash[:vm].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def referee_vm_json(referee)
      {
        id: referee.id,
        lizenznummer: referee.lizenznummer,
        lizenznummer_display: referee.lizenznummer_display,
        vorname: referee.vorname,
        nachname: referee.nachname,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit&.strftime('%d.%m.%Y'),
        active: !referee.guest? && referee.gueltigkeit.present? && referee.gueltigkeit >= Date.today,
        club_name: referee.club&.name,
        landesverband: referee.landesverband,
        qualifications: referee.referee_qualifications.map do |q|
          {
            qualification_type_name: q.referee_qualification_type&.name,
            valid_until: q.valid_until&.strftime('%d.%m.%Y')
          }
        end
      }
    end
  end
end
