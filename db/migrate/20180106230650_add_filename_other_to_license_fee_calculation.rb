class AddFilenameOtherToLicenseFeeCalculation < ActiveRecord::Migration[5.1]
  def change
    add_column :license_fee_calculations, :filename_other_json, :string
  end
end
