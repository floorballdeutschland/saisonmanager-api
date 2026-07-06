class LicenseFeesController < ApplicationController
  before_action :authorize_fee_access!, only: [:index, :show]
  before_action :set_license_fee_calculation, only: [:show, :update, :destroy]

  # GET /license_fees
  def index
    render json: LicenseFeeCalculation.all.order(:id)
  end

  # GET /license_fees/1
  def show
    respond_to do |format|
      format.json { send_data @license_fee_calculation.load_json, filename: @license_fee_calculation.filename_json }
      format.csv { send_data @license_fee_calculation.load_csv, filename: @license_fee_calculation.filename_csv  }
      format.xlsx { send_data @license_fee_calculation.load_xlsx, filename: @license_fee_calculation.filename_xls  }
    end
  end

  private

  # Lizenzgebühren-Berechnungen sind auf wenige Abrechnungs-Accounts beschränkt.
  # Dieselbe Whitelist galt bisher nur für #index – #show war nur durch das
  # allgemeine authenticate_user geschützt und für jeden Login abrufbar.
  def authorize_fee_access!
    username = current_user.user_name.downcase
    return if username == 'rbuettner' || username.starts_with?('jho_') || username == 'mguenther'

    render json: { success: false, error: 'not allowed' }, status: 401
  end

  def set_license_fee_calculation
    @license_fee_calculation = LicenseFeeCalculation.find(params[:id])
  end
end
