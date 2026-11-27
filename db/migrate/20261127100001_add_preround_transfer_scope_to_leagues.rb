# Was eine Folgeliga aus ihren Vorrunden übernimmt: nur Punkte (`points`,
# leer gilt ebenso), Punkte und Tore (`goals`) oder die komplette Bilanz
# (`full`). Siehe LeaguePrerounds::PREROUND_SCOPES.
class AddPreroundTransferScopeToLeagues < ActiveRecord::Migration[7.2]
  def change
    add_column :leagues, :preround_transfer_scope, :string
  end
end
