class RefereesController < ApplicationController
  skip_before_action :authenticate_user, only: %i[reset_password_token]

  def show
    file = File.read(Rails.root.join('referees.json'))
    referees = JSON.parse(file)

    referee = referees.select { |r| r['number'] == params[:id].to_i }.first

    render json: referee
  end
end
