class LicenseFeesController < ApplicationController
  before_action :set_license_fee_calculation, only: [:show, :update, :destroy]

  # GET /license_fees
  def index
    puts @user.to_json

    username = @user.user_name.downcase

    if (username == 'rbuettner') || username.starts_with?('jho_') || (username == 'mguenther')
      @license_fee_calculation = LicenseFeeCalculation.all.order(:id)

      render json: @license_fee_calculation
    else
      render json: { success: false, error: 'not allowed' }, status: 401
    end
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
  def set_license_fee_calculation
    @license_fee_calculation = LicenseFeeCalculation.find(params[:id])
  end
end
